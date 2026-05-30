defmodule PhoenixKitCatalogue.Catalogue.PdfLibraryTest do
  @moduledoc """
  Integration tests for the PDF library context.

  Pure-function pieces (item_titles, sha256_file) are deferred to a
  later split since they don't introduce new test infra. This file
  focuses on DB-touching functions: list/get/count, trash/restore/
  permanent-delete, worker callbacks, search, and `prune_orphan_page_contents`.

  `create_pdf_from_upload` interacts with core's `Storage.store_file`
  which writes to disk + manages buckets — covering it requires
  Storage stubbing and lives in a separate file once that
  infrastructure lands.
  """
  use PhoenixKitCatalogue.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PdfLibrary
  alias PhoenixKitCatalogue.Schemas.{Pdf, PdfExtraction, PdfPage, PdfPageContent}

  defp now_truncated, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp insert_file!(opts \\ []) do
    # Insert a minimal `phoenix_kit_files` row directly via SQL so we
    # can pin a Pdf row to it without going through Storage.store_file
    # (which writes to disk + bucket-manages). Mirrors what core's
    # Storage would persist for a small PDF.
    file_uuid = Keyword.get(opts, :uuid, UUIDv7.generate())
    user_uuid = Keyword.get(opts, :user_uuid, ensure_user_uuid())

    checksum =
      Keyword.get(
        opts,
        :file_checksum,
        :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
      )

    SQL.query!(
      Repo,
      """
      INSERT INTO phoenix_kit_files
        (uuid, original_file_name, file_name, file_path, mime_type, file_type,
         ext, file_checksum, user_file_checksum, size, status, user_uuid,
         inserted_at, updated_at)
      VALUES ($1, 'sample.pdf', 'sample.pdf', '/tmp/sample.pdf',
              'application/pdf', 'document', 'pdf', $2, $3, 1024, 'active',
              $4, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(file_uuid),
        checksum,
        :crypto.hash(:sha256, "#{user_uuid}#{checksum}") |> Base.encode16(case: :lower),
        Ecto.UUID.dump!(user_uuid)
      ]
    )

    file_uuid
  end

  defp ensure_user_uuid do
    # Insert a minimal user via raw SQL so we don't trip
    # `register_user`'s rate-limiter (Hammer ETS isn't started in this
    # test env, see error trace at `RateLimiter.check_rate_limit/3`).
    # Reuses a single fixed UUID across the test file so duplicate
    # inserts no-op via ON CONFLICT.
    fixed_uuid = "019dffff-ffff-7fff-bfff-ffffffffffff"

    SQL.query!(
      Repo,
      """
      INSERT INTO phoenix_kit_users
        (uuid, email, hashed_password, account_type, is_active, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'person', true, NOW(), NOW())
      ON CONFLICT (uuid) DO NOTHING
      """,
      [
        Ecto.UUID.dump!(fixed_uuid),
        "pdf-library-test@example.com",
        # Bcrypt hash placeholder — never validated since tests never log in.
        "$2b$12$0000000000000000000000000000000000000000000000000000."
      ]
    )

    fixed_uuid
  end

  defp insert_pdf!(file_uuid, attrs \\ %{}) do
    {:ok, pdf} =
      %Pdf{}
      |> Pdf.changeset(
        Map.merge(
          %{
            file_uuid: file_uuid,
            original_filename: "test-#{System.unique_integer([:positive])}.pdf",
            byte_size: 1024
          },
          attrs
        )
      )
      |> Repo.insert()

    pdf
  end

  defp insert_extraction!(file_uuid, attrs \\ %{}) do
    {:ok, ext} =
      %PdfExtraction{}
      |> PdfExtraction.changeset(Map.merge(%{file_uuid: file_uuid}, attrs))
      |> Repo.insert()

    ext
  end

  # ── list / count / get ─────────────────────────────────────────────

  describe "list_pdfs/1" do
    test "active filter excludes trashed rows by default" do
      file = insert_file!()
      _active = insert_pdf!(file)
      _trashed = insert_pdf!(file, %{status: "trashed", trashed_at: now_truncated()})

      assert [%Pdf{status: "active"}] = Catalogue.list_pdfs()
    end

    test "trashed filter shows only trashed rows" do
      file = insert_file!()
      _active = insert_pdf!(file)
      _trashed = insert_pdf!(file, %{status: "trashed", trashed_at: now_truncated()})

      assert [%Pdf{status: "trashed"}] = Catalogue.list_pdfs(status: "trashed")
    end

    test "nil status returns both active and trashed" do
      file = insert_file!()
      _active = insert_pdf!(file)
      _trashed = insert_pdf!(file, %{status: "trashed", trashed_at: now_truncated()})

      assert length(Catalogue.list_pdfs(status: nil)) == 2
    end

    test "preloads :extraction" do
      file = insert_file!()
      pdf = insert_pdf!(file)
      _ext = insert_extraction!(file, %{extraction_status: "extracted", page_count: 5})

      [loaded] = Catalogue.list_pdfs()
      assert loaded.uuid == pdf.uuid
      assert %PdfExtraction{extraction_status: "extracted", page_count: 5} = loaded.extraction
    end
  end

  describe "count_pdfs/1" do
    test "counts active by default" do
      file = insert_file!()
      _ = insert_pdf!(file)
      _ = insert_pdf!(file, %{status: "trashed", trashed_at: now_truncated()})

      assert Catalogue.count_pdfs() == 1
    end

    test "counts all when status: nil" do
      file = insert_file!()
      _ = insert_pdf!(file)
      _ = insert_pdf!(file, %{status: "trashed", trashed_at: now_truncated()})

      assert Catalogue.count_pdfs(status: nil) == 2
    end
  end

  describe "get_pdf/1" do
    test "returns the row by uuid" do
      file = insert_file!()
      pdf = insert_pdf!(file)

      loaded = Catalogue.get_pdf(pdf.uuid)
      assert %Pdf{} = loaded
      assert loaded.uuid == pdf.uuid
    end

    test "returns nil for unknown uuid" do
      assert Catalogue.get_pdf(UUIDv7.generate()) == nil
    end
  end

  # ── trash / restore / permanently_delete ───────────────────────────

  describe "trash_pdf/2" do
    test "flips status to trashed + stamps trashed_at" do
      file = insert_file!()
      pdf = insert_pdf!(file)

      {:ok, trashed} = Catalogue.trash_pdf(pdf, actor_uuid: ensure_user_uuid())

      assert trashed.status == "trashed"
      assert %DateTime{} = trashed.trashed_at
    end
  end

  describe "restore_pdf/2" do
    test "flips status to active + clears trashed_at" do
      file = insert_file!()
      pdf = insert_pdf!(file, %{status: "trashed", trashed_at: now_truncated()})

      {:ok, restored} = Catalogue.restore_pdf(pdf, actor_uuid: ensure_user_uuid())

      assert restored.status == "active"
      assert restored.trashed_at == nil
    end
  end

  describe "permanently_delete_pdf/2" do
    test "deletes the row" do
      file = insert_file!()
      pdf = insert_pdf!(file)

      {:ok, _} = Catalogue.permanently_delete_pdf(pdf, actor_uuid: ensure_user_uuid())

      assert Catalogue.get_pdf(pdf.uuid) == nil
    end

    test "leaves underlying file alone if other Pdf rows reference it" do
      file = insert_file!()
      pdf_a = insert_pdf!(file)
      _pdf_b = insert_pdf!(file)

      {:ok, _} = Catalogue.permanently_delete_pdf(pdf_a, actor_uuid: ensure_user_uuid())

      # File row is still present; cascading delete didn't fire.
      assert Repo.get(PhoenixKit.Modules.Storage.File, file) != nil
    end
  end

  # ── worker callbacks ───────────────────────────────────────────────

  describe "PdfLibrary.mark_extracting/1 and friends" do
    test "mark_extracting flips status from pending to extracting" do
      file = insert_file!()
      _ = insert_pdf!(file)
      _ = insert_extraction!(file)

      {:ok, %PdfExtraction{extraction_status: "extracting"}} =
        PdfLibrary.mark_extracting(file)
    end

    test "mark_extracted records page_count + extracted_at" do
      file = insert_file!()
      _ = insert_pdf!(file)
      _ = insert_extraction!(file, %{extraction_status: "extracting"})

      {:ok, ext} = PdfLibrary.mark_extracted(file, 100)
      assert ext.extraction_status == "extracted"
      assert ext.page_count == 100
      assert %DateTime{} = ext.extracted_at
    end

    test "mark_failed truncates the message to 500 chars" do
      file = insert_file!()
      _ = insert_pdf!(file)
      _ = insert_extraction!(file, %{extraction_status: "extracting"})

      long = String.duplicate("X", 1000)
      {:ok, ext} = PdfLibrary.mark_failed(file, long)

      assert byte_size(ext.error_message) == 500
      assert ext.extraction_status == "failed"
    end

    test "returns :not_found when extraction row doesn't exist" do
      assert {:error, :not_found} = PdfLibrary.mark_extracting(UUIDv7.generate())
    end
  end

  describe "PdfLibrary.insert_page/3" do
    test "inserts a page row + content row on first call" do
      file = insert_file!()
      _ = insert_pdf!(file)

      {:ok, %PdfPage{}} = PdfLibrary.insert_page(file, 1, "hello world")

      assert Repo.aggregate(PdfPage, :count, :file_uuid) == 1
      assert Repo.aggregate(PdfPageContent, :count, :content_hash) == 1
    end

    test "deduplicates the content row across two pages with identical text" do
      file = insert_file!()
      _ = insert_pdf!(file)

      {:ok, _} = PdfLibrary.insert_page(file, 1, "shared text")
      {:ok, _} = PdfLibrary.insert_page(file, 2, "shared text")

      assert Repo.aggregate(PdfPage, :count, :file_uuid) == 2
      assert Repo.aggregate(PdfPageContent, :count, :content_hash) == 1
    end

    test "is idempotent on re-insert (on_conflict: :nothing on PdfPage PK)" do
      file = insert_file!()
      _ = insert_pdf!(file)

      {:ok, _} = PdfLibrary.insert_page(file, 1, "x")
      # Re-running is a no-op on the PK conflict
      _ = PdfLibrary.insert_page(file, 1, "x")

      assert Repo.aggregate(PdfPage, :count, :file_uuid) == 1
    end
  end

  # ── prune_orphan_page_contents ─────────────────────────────────────

  describe "PdfLibrary.prune_orphan_page_contents/0" do
    test "removes content rows with no referencing pdf_pages" do
      now = now_truncated()

      Repo.insert_all(PdfPageContent, [
        %{content_hash: String.duplicate("a", 64), text: "orphan", inserted_at: now}
      ])

      assert Catalogue.prune_orphan_pdf_page_contents() == 1
      assert Repo.aggregate(PdfPageContent, :count, :content_hash) == 0
    end

    test "keeps content rows that any pdf_pages row references" do
      file = insert_file!()
      _ = insert_pdf!(file)
      {:ok, _} = PdfLibrary.insert_page(file, 1, "kept")

      assert Catalogue.prune_orphan_pdf_page_contents() == 0
      assert Repo.aggregate(PdfPageContent, :count, :content_hash) == 1
    end
  end

  # ── search ─────────────────────────────────────────────────────────

  describe "search_pdfs_for_item/2" do
    setup do
      file = insert_file!()
      pdf = insert_pdf!(file, %{original_filename: "kitchen-catalogue.pdf"})
      _ = insert_extraction!(file, %{extraction_status: "extracted", page_count: 3})

      {:ok, _} = PdfLibrary.insert_page(file, 1, "Wooden cabinet hinge with damper")
      {:ok, _} = PdfLibrary.insert_page(file, 2, "Stainless steel sink 60cm")
      {:ok, _} = PdfLibrary.insert_page(file, 3, "Drawer slide 450mm full extension")

      item =
        Repo.insert!(%PhoenixKitCatalogue.Schemas.Item{
          name: "hinge",
          catalogue_uuid: nil,
          status: "active",
          unit: "piece"
        })

      # NB: don't expose `file:` — `:file` is a reserved ExUnit context
      # key (test-metadata) and setting it raises. The tests only need
      # the pdf + item anyway.
      {:ok, pdf: pdf, item: item}
    end

    test "literal search finds matching pages grouped under the PDF", %{item: item, pdf: pdf} do
      [group] = Catalogue.search_pdfs_for_item(item)

      assert group.pdf.uuid == pdf.uuid
      assert group.total_matches >= 1
      assert Enum.any?(group.hits, fn h -> h.snippet =~ "hinge" end)
    end

    test "returns [] for an item with no name", %{item: _} do
      orphan = %PhoenixKitCatalogue.Schemas.Item{name: nil, status: "active", unit: "piece"}
      assert Catalogue.search_pdfs_for_item(orphan) == []
    end
  end

  describe "enqueue_extraction/1 — graceful fallback when the :catalogue_pdf queue is unavailable" do
    # The catalogue test env never starts Oban, so `Oban.config()` is
    # unreachable and `catalogue_pdf_queue_available?/0` reports the
    # queue as not running — exactly the misconfiguration where PDFs get
    # uploaded but the queue isn't wired. The guard must refuse to
    # enqueue and flip the extraction to a terminal, visible `failed`
    # state instead of inserting a dead Oban job that never moves.
    test "flips a pending extraction to failed with an actionable message (no dead job)" do
      file_uuid = insert_file!()
      _pdf = insert_pdf!(file_uuid)
      _ext = insert_extraction!(file_uuid, %{extraction_status: "pending"})

      log =
        capture_log(fn ->
          assert {:error, :extraction_queue_unavailable} =
                   PdfLibrary.enqueue_extraction(file_uuid)
        end)

      # The refusal is logged loudly so operators notice the misconfig.
      assert log =~ "refusing to enqueue PDF extraction"

      reloaded = Repo.get(PdfExtraction, file_uuid)
      assert reloaded.extraction_status == "failed"
      assert reloaded.error_message =~ "catalogue_pdf"
      assert reloaded.error_message =~ "Oban"
    end

    test "logs a pdf.extraction_failed activity row so the failure is auditable" do
      file_uuid = insert_file!()
      pdf = insert_pdf!(file_uuid)
      _ext = insert_extraction!(file_uuid, %{extraction_status: "pending"})

      capture_log(fn ->
        assert {:error, :extraction_queue_unavailable} =
                 PdfLibrary.enqueue_extraction(file_uuid)
      end)

      assert_activity_logged("pdf.extraction_failed",
        resource_uuid: pdf.uuid,
        metadata_has: %{"file_uuid" => file_uuid}
      )
    end
  end
end
