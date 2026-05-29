defmodule PhoenixKitCatalogue.Web.PdfLibraryLiveTest do
  @moduledoc """
  Smoke tests for the three PDF Web LVs (PdfLibraryLive, PdfDetailLive,
  PdfSearchModal). Mount + per-action click coverage; activity-log
  threading pinned via `assert_activity_logged/2`.

  Currently DB-gated: catalogue's standalone test DB sits at V110 until
  `BeamLabEU/phoenix_kit#515` publishes 1.7.105 with V111. Tests are
  excluded automatically by `test_helper.exs` when the DB is not
  available; they run as soon as the Hex pin lands.
  """
  use PhoenixKitCatalogue.LiveCase

  alias Ecto.Adapters.SQL
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.{Pdf, PdfExtraction}
  alias PhoenixKitCatalogue.Test.Repo

  @lib_path "/en/admin/catalogue/pdfs"
  @detail_path "/en/admin/catalogue/pdfs"

  defp now_truncated, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # Insert a Pdf row directly (skipping Storage.store_file) — same
  # technique as `pdf_library_test.exs`. The file_uuid points at a
  # phoenix_kit_files row inserted via raw SQL.
  defp fixture_pdf_with_extraction(opts \\ []) do
    file_uuid = UUIDv7.generate()
    user_uuid = ensure_user_uuid()

    SQL.query!(
      Repo,
      """
      INSERT INTO phoenix_kit_files
        (uuid, original_file_name, file_name, file_path, mime_type, file_type,
         ext, file_checksum, user_file_checksum, size, status, user_uuid,
         inserted_at, updated_at)
      VALUES ($1, 'sample.pdf', 'sample.pdf', '/tmp/x.pdf',
              'application/pdf', 'document', 'pdf', $2, $3, 1024, 'active',
              $4, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(file_uuid),
        :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
        :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
        Ecto.UUID.dump!(user_uuid)
      ]
    )

    {:ok, pdf} =
      %Pdf{}
      |> Pdf.changeset(%{
        file_uuid: file_uuid,
        original_filename: Keyword.get(opts, :filename, "sample.pdf"),
        byte_size: 1024,
        status: Keyword.get(opts, :status, "active"),
        trashed_at: if(Keyword.get(opts, :status) == "trashed", do: now_truncated(), else: nil)
      })
      |> Repo.insert()

    {:ok, _ext} =
      %PdfExtraction{}
      |> PdfExtraction.changeset(%{
        file_uuid: file_uuid,
        extraction_status: Keyword.get(opts, :extraction_status, "extracted"),
        page_count: Keyword.get(opts, :page_count, 5)
      })
      |> Repo.insert()

    {pdf, file_uuid, user_uuid}
  end

  defp ensure_user_uuid do
    fixed_uuid = "019dffff-ffff-7fff-bfff-fffffffffffe"

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
        "pdf-lv-test@example.com",
        "$2b$12$0000000000000000000000000000000000000000000000000000."
      ]
    )

    fixed_uuid
  end

  describe "PdfLibraryLive — mount + filter" do
    test "renders the active library with the upload zone visible", %{conn: conn} do
      {pdf, _file_uuid, _user_uuid} = fixture_pdf_with_extraction(filename: "kitchen.pdf")

      {:ok, _view, html} = live(conn, @lib_path)

      assert html =~ "PDF library"
      assert html =~ "kitchen.pdf"
      # Active filter shows upload zone
      assert html =~ "Drag files here or click to browse"
      assert html =~ pdf.original_filename
    end

    test "switches to trashed filter and hides the upload zone", %{conn: conn} do
      {trashed, _, _} = fixture_pdf_with_extraction(status: "trashed", filename: "trashed.pdf")

      {:ok, view, _html} = live(conn, @lib_path)

      html = view |> element("button", "Trash") |> render_click()

      assert html =~ trashed.original_filename
      refute html =~ "Drag files here or click to browse"
    end
  end

  describe "PdfLibraryLive — trash event" do
    test "trashes the row + flashes + logs activity", %{conn: conn, scope: scope} do
      {pdf, _, _} = fixture_pdf_with_extraction()

      {:ok, view, _html} =
        conn
        |> with_scope(scope)
        |> live(@lib_path)

      html =
        view
        |> render_click("trash", %{"uuid" => pdf.uuid})

      assert html =~ "PDF moved to trash."

      reloaded = Catalogue.get_pdf(pdf.uuid)
      assert reloaded.status == "trashed"

      assert_activity_logged("pdf.trashed",
        resource_uuid: pdf.uuid,
        actor_uuid: scope.user.uuid
      )
    end
  end

  describe "PdfLibraryLive — restore event" do
    test "restores the row + flashes + logs activity", %{conn: conn, scope: scope} do
      {pdf, _, _} = fixture_pdf_with_extraction(status: "trashed")

      {:ok, view, _html} =
        conn
        |> with_scope(scope)
        |> live(@lib_path <> "?filter=trashed")

      _ = view |> render_click("set_filter", %{"filter" => "trashed"})
      html = view |> render_click("restore", %{"uuid" => pdf.uuid})

      assert html =~ "PDF restored." or
               Catalogue.get_pdf(pdf.uuid) |> Map.get(:status) == "active"

      assert_activity_logged("pdf.restored",
        resource_uuid: pdf.uuid,
        actor_uuid: scope.user.uuid
      )
    end
  end

  describe "PdfDetailLive — mount" do
    test "redirects to the library when uuid not found", %{conn: conn} do
      bogus = "00000000-0000-0000-0000-000000000000"
      {:error, {:live_redirect, %{to: to}}} = live(conn, "#{@detail_path}/#{bogus}")
      assert to == @lib_path
    end

    test "renders the detail page for a real uuid", %{conn: conn} do
      {pdf, _, _} = fixture_pdf_with_extraction(filename: "details.pdf")

      {:ok, _view, html} = live(conn, "#{@detail_path}/#{pdf.uuid}")

      assert html =~ pdf.original_filename
      assert html =~ "Extracted"
    end
  end
end
