defmodule PhoenixKitCatalogue.Catalogue.PdfLibrary do
  @moduledoc """
  PDF library — upload, extract, search.

  Layered on top of core's `phoenix_kit_files` system. The catalogue
  owns only:

    * `phoenix_kit_cat_pdfs` — per-upload row (the user-facing
      "this name in the library"). Soft-delete via
      `status` (`active` / `trashed`).
    * `phoenix_kit_cat_pdf_extractions` — per unique file content
      (one row per `file_uuid`). Holds the worker state machine.
    * `phoenix_kit_cat_pdf_pages` — per-page join.
    * `phoenix_kit_cat_pdf_page_contents` — content-addressed
      page text dedup cache.

  Core handles binary storage, content checksum dedup, multi-bucket
  redundancy, on-disk lifecycle (`Storage.trash_file/1`,
  `PruneTrashJob`).

  Public surface re-exported from `PhoenixKitCatalogue.Catalogue`.
  Activity logging follows the catalogue convention — success-only on
  the context layer; the LV layer's `Web.Helpers.log_operation_error/3`
  writes the `db_pending: true` audit row on failure.

  ## Authorization

  The mutating context functions accept `:actor_uuid` for activity
  attribution but **do not enforce role checks** — authorization is
  the LV mount layer's job (admin `live_session` + `on_mount` hook).
  Same convention as the rest of the catalogue context. New non-LV
  callers (background jobs, RPC, extension modules) MUST verify the
  caller is allowed before invoking these functions.

  `create_pdf_from_upload/3` does require a non-nil `:actor_uuid` —
  not as authorization, but because core's `phoenix_kit_files.user_uuid`
  is NOT NULL and we'd otherwise crash mid-flow after writing bytes
  to disk. Returns `{:error, :missing_actor}` cleanly when missing.
  """

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Utils.Multilang

  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, PubSub}

  alias PhoenixKitCatalogue.Schemas.{
    Item,
    Pdf,
    PdfExtraction,
    PdfPage,
    PdfPageContent
  }

  alias PhoenixKitCatalogue.Workers.PdfExtractor

  # Stored on the extraction row (and shown by PdfDetailLive + the
  # activity feed) when we deliberately refuse to enqueue because the
  # job could never run. Actionable on purpose.
  @queue_unavailable_message "PDF text extraction did not start: the :catalogue_pdf Oban queue is not running in this app. Add `catalogue_pdf` to your Oban `queues:` config (or run `mix phoenix_kit.update`), then re-upload."

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ── List / read ─────────────────────────────────────────────────────

  @doc """
  Lists PDFs in the library, newest first.

  ## Options

    * `:status` — filter to a status string (`"active"` / `"trashed"`).
      Pass `nil` to include all. Defaults to `"active"`.
    * `:limit` (default 100), `:offset` (default 0)
  """
  @spec list_pdfs(keyword()) :: [Pdf.t()]
  def list_pdfs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    status = Keyword.get(opts, :status, "active")

    Pdf
    |> by_status(status)
    |> order_by([p], desc: p.inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> repo().all()
    |> repo().preload(:extraction)
  end

  @doc "Returns the total PDF count, matching the optional status filter."
  @spec count_pdfs(keyword()) :: non_neg_integer()
  def count_pdfs(opts \\ []) do
    status = Keyword.get(opts, :status, "active")

    Pdf
    |> by_status(status)
    |> select([p], count(p.uuid))
    |> repo().one()
  end

  defp by_status(query, nil), do: query
  defp by_status(query, status), do: where(query, [p], p.status == ^status)

  @doc "Fetches a PDF by UUID. Returns `nil` if not found."
  @spec get_pdf(Ecto.UUID.t()) :: Pdf.t() | nil
  def get_pdf(uuid), do: repo().get(Pdf, uuid)

  @doc "Fetches a PDF by UUID. Raises `Ecto.NoResultsError` if not found."
  @spec get_pdf!(Ecto.UUID.t()) :: Pdf.t()
  def get_pdf!(uuid), do: repo().get!(Pdf, uuid)

  @doc """
  Returns the extraction state for a PDF (or its `file_uuid`), or
  `nil` if the file has no extraction row yet.
  """
  @spec get_extraction(Pdf.t() | Ecto.UUID.t()) :: PdfExtraction.t() | nil
  def get_extraction(%Pdf{file_uuid: file_uuid}), do: get_extraction(file_uuid)

  def get_extraction(file_uuid) when is_binary(file_uuid),
    do: repo().get(PdfExtraction, file_uuid)

  # ── Upload ──────────────────────────────────────────────────────────

  @doc """
  Stores an uploaded PDF.

  `tmp_path` is the local file from `consume_uploaded_entry`'s callback.
  `original_filename` is the user's chosen name. `byte_size` is from
  `entry.client_size`.

  Flow:

    1. `Storage.store_file/2` (core) — handles SHA-256 dedup, on-disk
       placement, multi-bucket redundancy. Same content uploaded
       twice (any name) returns the same `file_uuid`.
    2. Upsert the per-file extraction row. If newly created, enqueue
       the worker — otherwise the previous extraction is reused.
    3. Always insert a fresh `phoenix_kit_cat_pdfs` row so each
       upload gets its own per-name entry in the library.
    4. Activity action: `pdf.uploaded`. Metadata flags
       `content_dedup: true` when the file row was a hit.

  Returns `{:ok, pdf}` on success.

  The persisted `byte_size` is read from the file on disk via
  `File.stat!/1` — never from a browser-supplied value — so the
  recorded size always matches the actual stored bytes.
  """
  @spec create_pdf_from_upload(String.t(), String.t(), keyword()) ::
          {:ok, Pdf.t()} | {:error, term()}
  def create_pdf_from_upload(tmp_path, original_filename, opts \\ []) do
    actor_uuid = opts[:actor_uuid]

    # Core's `phoenix_kit_files.user_uuid` is NOT NULL; without an
    # actor, `Storage.store_file/2` would crash with a changeset
    # validation error after copying the file to disk. Reject early
    # so the LV gets a clean `{:error, :missing_actor}` to surface.
    if is_binary(actor_uuid) and actor_uuid != "" do
      do_create_pdf_from_upload(tmp_path, original_filename, opts, actor_uuid)
    else
      {:error, :missing_actor}
    end
  end

  defp do_create_pdf_from_upload(tmp_path, original_filename, opts, actor_uuid) do
    case File.stat(tmp_path) do
      {:ok, %File.Stat{size: byte_size}} ->
        with {:ok, file, dedup_kind} <-
               store_via_core(tmp_path, original_filename, byte_size, actor_uuid),
             {:ok, _extraction} <- ensure_extraction(file.uuid),
             {:ok, pdf} <- insert_pdf_row(file, original_filename, byte_size, dedup_kind, opts) do
          PubSub.broadcast(:pdf, pdf.uuid)
          {:ok, pdf}
        end

      {:error, posix} ->
        {:error, {:tmp_file_missing, posix}}
    end
  end

  # Cross-user content dedup: hash the tmp file ourselves, look it up
  # by `file_checksum`, reuse if a non-trashed row already exists.
  # Otherwise hand off to `Storage.store_file/2` with the actor as
  # `user_uuid` (core requires it NOT NULL).
  #
  # Race note: concurrent uploads of identical NEW content can both
  # miss this pre-check and both fall through to `Storage.store_file`.
  # Core's atomic `unique_index(user_file_checksum)` resolves the
  # same-user case (one wins, other returns `{:error, changeset}` →
  # `{:storage_failed, _}`); the cross-user case (different actors,
  # same content) intentionally produces two file rows because core's
  # dedup is per-user. The catalogue's per-page-content cache
  # (`PdfPageContent.content_hash` PK) still dedupes the actual page
  # text storage in both cases.
  defp store_via_core(tmp_path, filename, byte_size, actor_uuid) do
    file_checksum = sha256_file(tmp_path)

    case existing_active_file(file_checksum) do
      %{} = file ->
        {:ok, file, :existing}

      nil ->
        case Storage.store_file(tmp_path,
               filename: filename,
               content_type: "application/pdf",
               size_bytes: byte_size,
               user_uuid: actor_uuid
             ) do
          {:ok, %{} = file} -> {:ok, file, :new}
          {:error, reason} -> {:error, {:storage_failed, reason}}
        end
    end
  end

  defp existing_active_file(file_checksum) do
    case Storage.get_file_by_checksum(file_checksum) do
      %PhoenixKit.Modules.Storage.File{status: status} = file when status != "trashed" -> file
      _ -> nil
    end
  end

  defp sha256_file(path) do
    # Stream the file in 64 KB chunks. Elixir 1.16+ moved modes from
    # arg 2 to arg 3; the old `(path, [], 65_536)` shape is a contract
    # mismatch that dialyzer flags.
    path
    |> File.stream!(65_536, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # Idempotent: concurrent uploads of identical NEW content can both
  # branch the `nil` case; using `on_conflict: :nothing` makes the
  # second insert a no-op rather than raising a PK violation that would
  # abort the outer upload pipeline. We still need a follow-up `get/2`
  # to fetch the inserted row's actual fields when the conflict path
  # was taken (Ecto's `on_conflict: :nothing` returns the changeset's
  # uncommitted struct, not the existing row's data).
  defp ensure_extraction(file_uuid) do
    changeset =
      PdfExtraction.changeset(%PdfExtraction{}, %{
        file_uuid: file_uuid,
        extraction_status: "pending"
      })

    case repo().insert(changeset,
           on_conflict: :nothing,
           conflict_target: :file_uuid
         ) do
      {:ok, _stub} -> resolve_extraction_after_insert(file_uuid)
      {:error, _} = err -> err
    end
  end

  # Conflict path: `on_conflict: :nothing` returns the un-persisted stub,
  # so re-fetch to report `extraction_status` reliably and only enqueue
  # when this caller was the inserter (heuristic: inserted within the
  # last second). Worst case is a duplicate enqueue — the worker
  # short-circuits on a terminal status.
  defp resolve_extraction_after_insert(file_uuid) do
    case repo().get(PdfExtraction, file_uuid) do
      %PdfExtraction{extraction_status: "pending", inserted_at: inserted_at} = extraction ->
        age_secs = DateTime.diff(DateTime.utc_now(), inserted_at, :second)
        if age_secs <= 1, do: enqueue_extraction(file_uuid)
        {:ok, extraction}

      %PdfExtraction{} = extraction ->
        {:ok, extraction}

      nil ->
        {:error, :ensure_extraction_lost_row}
    end
  end

  defp insert_pdf_row(file, original_filename, byte_size, dedup_kind, opts) do
    ActivityLog.with_log(
      fn ->
        %Pdf{}
        |> Pdf.changeset(%{
          file_uuid: file.uuid,
          original_filename: original_filename,
          byte_size: byte_size
        })
        |> repo().insert()
      end,
      fn pdf ->
        %{
          action: "pdf.uploaded",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "pdf",
          resource_uuid: pdf.uuid,
          metadata: %{
            "original_filename" => pdf.original_filename,
            "byte_size" => byte_size,
            "file_uuid" => file.uuid,
            "content_dedup" => dedup_kind == :existing
          }
        }
      end
    )
  end

  # ── Trash / restore / permanent delete ──────────────────────────────

  @doc """
  Soft-deletes a PDF: flips status to `"trashed"` and records
  `trashed_at`. Underlying file + extraction + page rows untouched
  (other live PDF entries may still reference them).
  """
  @spec trash_pdf(Pdf.t(), keyword()) :: {:ok, Pdf.t()} | {:error, Ecto.Changeset.t()}
  def trash_pdf(%Pdf{} = pdf, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> pdf |> Pdf.trash_changeset() |> repo().update() end,
        fn p ->
          %{
            action: "pdf.trashed",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "pdf",
            resource_uuid: p.uuid,
            metadata: %{"original_filename" => p.original_filename}
          }
        end
      )

    with {:ok, pdf} <- result do
      PubSub.broadcast(:pdf, pdf.uuid)
      {:ok, pdf}
    end
  end

  @doc "Restores a trashed PDF back to active."
  @spec restore_pdf(Pdf.t(), keyword()) :: {:ok, Pdf.t()} | {:error, Ecto.Changeset.t()}
  def restore_pdf(%Pdf{} = pdf, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> pdf |> Pdf.restore_changeset() |> repo().update() end,
        fn p ->
          %{
            action: "pdf.restored",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "pdf",
            resource_uuid: p.uuid,
            metadata: %{"original_filename" => p.original_filename}
          }
        end
      )

    with {:ok, pdf} <- result do
      PubSub.broadcast(:pdf, pdf.uuid)
      {:ok, pdf}
    end
  end

  @doc """
  Permanently removes a `phoenix_kit_cat_pdfs` row.

  When this is the last (active OR trashed) row referencing the
  underlying `file_uuid`, hands the file off to `Storage.trash_file/1`
  so core's daily `PruneTrashJob` deletes the binary, cascading to
  the extraction and page rows.
  """
  @spec permanently_delete_pdf(Pdf.t(), keyword()) ::
          {:ok, Pdf.t()} | {:error, Ecto.Changeset.t()}
  def permanently_delete_pdf(%Pdf{} = pdf, opts \\ []) do
    file_uuid = pdf.file_uuid

    # Wrap the delete + refcount-then-handoff sequence in a serializable
    # transaction so a concurrent `create_pdf_from_upload` for the same
    # `file_uuid` can't slip a new row in between the refcount check
    # (returns 0) and `Storage.trash_file/1` — which would otherwise
    # leave the new upload's reference orphaned by core's prune. Postgres
    # SERIALIZABLE detects the read-write conflict and aborts one of
    # the racing transactions; the loser surfaces as `40001` and the
    # caller can retry.
    txn =
      repo().transaction(
        fn ->
          case repo().delete(pdf) do
            {:ok, deleted} ->
              maybe_handoff_underlying_file(file_uuid)
              deleted

            {:error, changeset} ->
              repo().rollback(changeset)
          end
        end,
        isolation: :serializable
      )

    case txn do
      {:ok, deleted} ->
        # Action name is `pdf.permanently_deleted` (not `pdf.deleted`)
        # so it lines up with `Web.Helpers.derive_activity_action/2`'s
        # `permanently_delete_` prefix → past tense `permanently_deleted`
        # mapping. Lets the LV's `:error` branch use `log_operation_error`
        # without a custom action override.
        ActivityLog.log(%{
          action: "pdf.permanently_deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "pdf",
          resource_uuid: deleted.uuid,
          metadata: %{
            "original_filename" => deleted.original_filename,
            "file_uuid" => file_uuid
          }
        })

        PubSub.broadcast(:pdf, deleted.uuid)
        {:ok, deleted}

      {:error, %Postgrex.Error{postgres: %{code: :serialization_failure}}} ->
        {:error, :serialization_conflict}

      {:error, _} = err ->
        err
    end
  end

  defp maybe_handoff_underlying_file(file_uuid) do
    refcount =
      repo().one(from(p in Pdf, where: p.file_uuid == ^file_uuid, select: count(p.uuid)))

    if refcount == 0 do
      case Storage.get_file(file_uuid) do
        nil -> :ok
        file -> Storage.trash_file(file)
      end
    end
  end

  # ── Worker callbacks (file_uuid-keyed) ──────────────────────────────

  @doc false
  @spec mark_extracting(Ecto.UUID.t()) :: {:ok, PdfExtraction.t()} | {:error, term()}
  def mark_extracting(file_uuid) do
    update_extraction(file_uuid, %{extraction_status: "extracting"})
  end

  @doc false
  @spec insert_page(Ecto.UUID.t(), pos_integer(), String.t()) ::
          {:ok, PdfPage.t()} | {:error, Ecto.Changeset.t()}
  def insert_page(file_uuid, page_number, text) when is_integer(page_number) do
    text = text || ""
    content_hash = sha256_hex(text)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    repo().insert_all(
      PdfPageContent,
      [%{content_hash: content_hash, text: text, inserted_at: now}],
      on_conflict: :nothing,
      conflict_target: [:content_hash]
    )

    %PdfPage{}
    |> PdfPage.changeset(%{
      file_uuid: file_uuid,
      page_number: page_number,
      content_hash: content_hash,
      inserted_at: now
    })
    |> repo().insert(
      on_conflict: :nothing,
      conflict_target: [:file_uuid, :page_number]
    )
  end

  @doc false
  @spec mark_extracted(Ecto.UUID.t(), pos_integer()) ::
          {:ok, PdfExtraction.t()} | {:error, term()}
  def mark_extracted(file_uuid, page_count) when is_integer(page_count) do
    update_extraction(file_uuid, %{
      extraction_status: "extracted",
      page_count: page_count,
      extracted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      error_message: nil
    })
    |> tap_log_extraction("pdf.extracted", file_uuid, %{"page_count" => page_count})
  end

  @doc false
  @spec mark_scanned_no_text(Ecto.UUID.t(), pos_integer()) ::
          {:ok, PdfExtraction.t()} | {:error, term()}
  def mark_scanned_no_text(file_uuid, page_count) when is_integer(page_count) do
    update_extraction(file_uuid, %{
      extraction_status: "scanned_no_text",
      page_count: page_count,
      extracted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      error_message: nil
    })
    |> tap_log_extraction("pdf.scanned_no_text", file_uuid, %{"page_count" => page_count})
  end

  @doc false
  @spec mark_failed(Ecto.UUID.t(), String.t()) ::
          {:ok, PdfExtraction.t()} | {:error, term()}
  def mark_failed(file_uuid, error_message) do
    truncated = error_message |> to_string() |> String.slice(0, 500)

    update_extraction(file_uuid, %{
      extraction_status: "failed",
      error_message: truncated
    })
    |> tap_log_extraction("pdf.extraction_failed", file_uuid, %{"error_message" => truncated})
  end

  defp update_extraction(file_uuid, attrs) do
    case repo().get(PdfExtraction, file_uuid) do
      nil ->
        {:error, :not_found}

      extraction ->
        result =
          extraction
          |> PdfExtraction.status_changeset(attrs)
          |> repo().update()

        with {:ok, _} <- result do
          broadcast_for_file(file_uuid)
          result
        end
    end
  end

  defp broadcast_for_file(file_uuid) do
    repo().all(from(p in Pdf, where: p.file_uuid == ^file_uuid, select: p.uuid))
    |> Enum.each(&PubSub.broadcast(:pdf, &1))
  end

  defp tap_log_extraction({:ok, extraction} = res, action, file_uuid, extra_metadata) do
    log_extraction_per_pdf(action, file_uuid, extra_metadata, %{})
    _ = extraction
    res
  end

  # `:error` branch: the DB write for the worker callback failed
  # (e.g. extraction row vanished, sandbox stale). Per the workspace
  # playbook, log a `db_pending: true` audit row so the user-initiated
  # action is still in the audit trail even when persistence failed.
  defp tap_log_extraction({:error, reason} = res, action, file_uuid, extra_metadata) do
    log_extraction_per_pdf(action, file_uuid, extra_metadata, %{
      "db_pending" => true,
      "error_kind" => failure_error_kind(reason),
      "reason" => failure_reason(reason)
    })

    res
  end

  defp tap_log_extraction(other, _, _, _), do: other

  # One audit row per active/trashed PDF entry pointing at this file —
  # so the audit feed shows the extraction outcome alongside each
  # user-facing upload row.
  defp log_extraction_per_pdf(action, file_uuid, extra_metadata, failure_metadata) do
    pdfs = repo().all(from(p in Pdf, where: p.file_uuid == ^file_uuid))

    Enum.each(pdfs, fn pdf ->
      ActivityLog.log(%{
        action: action,
        mode: "auto",
        resource_type: "pdf",
        resource_uuid: pdf.uuid,
        metadata:
          %{"original_filename" => pdf.original_filename, "file_uuid" => file_uuid}
          |> Map.merge(extra_metadata)
          |> Map.merge(failure_metadata)
      })
    end)
  end

  defp failure_error_kind(:not_found), do: "not_found"
  defp failure_error_kind(%Ecto.Changeset{}), do: "changeset"
  defp failure_error_kind(reason) when is_atom(reason), do: "atom"
  defp failure_error_kind(_), do: "other"

  defp failure_reason(:not_found), do: "extraction_row_vanished"

  defp failure_reason(%Ecto.Changeset{errors: errors}),
    do: errors |> Enum.map(fn {k, _} -> Atom.to_string(k) end) |> Enum.uniq() |> Enum.join(",")

  defp failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(_), do: "unspecified"

  # ── Search ──────────────────────────────────────────────────────────

  @typedoc "One PDF search hit returned to the UI."
  @type hit :: %{
          pdf: Pdf.t(),
          page_number: pos_integer(),
          snippet: String.t(),
          score: float()
        }

  @typedoc "Per-PDF group returned by `search_pdfs_for_item/2`."
  @type group :: %{
          pdf: Pdf.t(),
          total_matches: non_neg_integer(),
          hits: [hit()]
        }

  @doc """
  Searches the PDF library for any active PDF whose pages match one of
  the item's translated names.

  Returns groups keyed by PDF, each with the **total match count for
  the corpus** plus the first `:per_pdf` hits (default 5). Use
  `more_pdf_matches_for_item/3` to load additional hits within one PDF
  on demand (the "Show more matches" expand action).

  Strategy:

    1. Build the title list from the item's primary name + every
       enabled language's translated name. Drop blanks and duplicates.
    2. Literal `ILIKE ANY` against the deduped page-content table —
       fast and precise. Joined to active `phoenix_kit_cat_pdfs` rows
       via `file_uuid`. Rows are window-ranked per PDF and
       window-counted per PDF in a single SQL pass; the outer query
       caps at `rn <= per_pdf` so the result is bounded by
       `per_pdf × distinct PDFs that match`.
    3. If literal returns nothing, fall back to a `pg_trgm` similarity
       search using the longest title (default threshold 0.4) — same
       grouping shape, best similarity first within each PDF.

  Trashed PDFs are excluded. Groups are ordered newest-PDF-first.

  ## Options

    * `:per_pdf` (default 5) — preview hits returned per PDF.
    * `:similarity_threshold` (default 0.4) — trigram fallback threshold.
  """
  @spec search_pdfs_for_item(Item.t(), keyword()) :: [group()]
  def search_pdfs_for_item(%Item{} = item, opts \\ []) do
    per_pdf = Keyword.get(opts, :per_pdf, 5)
    threshold = Keyword.get(opts, :similarity_threshold, 0.4)
    titles = item_titles(item)

    if titles == [] do
      []
    else
      case literal_search_grouped(titles, per_pdf) do
        [] -> trigram_search_grouped(longest(titles), threshold, per_pdf)
        groups -> groups
      end
    end
  end

  @doc """
  Loads additional hits for one PDF beyond what the initial grouped
  search returned. Used by the modal's per-PDF "Show more matches"
  expand action.

  Returns a flat list of `hit()` ordered by `page_number ASC` (literal
  search) or `similarity DESC` (when a `:trigram_query` opt is given).

  ## Options

    * `:offset` (default 0)
    * `:limit` (default 50)
    * `:trigram_query` — when set, score by `pg_trgm` similarity
      against this string (matches the trigram fallback's ordering).
  """
  @spec more_pdf_matches_for_item(Item.t(), Ecto.UUID.t(), keyword()) :: [hit()]
  def more_pdf_matches_for_item(%Item{} = item, pdf_uuid, opts \\ []) do
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 50)
    trigram_query = Keyword.get(opts, :trigram_query)
    titles = item_titles(item)

    cond do
      titles == [] ->
        []

      trigram_query ->
        trigram_more(pdf_uuid, trigram_query, titles, offset, limit)

      true ->
        literal_more(pdf_uuid, titles, offset, limit)
    end
  end

  @doc false
  @spec item_titles(Item.t()) :: [String.t()]
  def item_titles(%Item{} = item) do
    primary = [item.name]

    translated =
      if Code.ensure_loaded?(Multilang) do
        try do
          Multilang.enabled_languages()
          |> Enum.map(fn lang ->
            (item.data || %{})
            |> Multilang.get_language_data(lang)
            |> Map.get("name")
          end)
        rescue
          # Multilang ships with the host app; the realistic failure
          # surface here is a stale settings cache (KeyError),
          # missing-locale list (ArgumentError), or a future API
          # change (UndefinedFunctionError). Anything else (DB error,
          # programmer bug) re-raises so it surfaces in telemetry
          # instead of silently degrading the search to "no
          # translations found".
          e in [KeyError, ArgumentError, UndefinedFunctionError] ->
            Logger.warning(
              "PdfLibrary.item_titles Multilang lookup failed: #{Exception.message(e)}"
            )

            []
        end
      else
        []
      end

    (primary ++ translated)
    |> Enum.map(&normalize_title/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp normalize_title(nil), do: nil
  defp normalize_title(s) when is_binary(s), do: s |> String.trim() |> collapse_ws()
  defp normalize_title(_), do: nil

  defp collapse_ws(s) do
    Regex.replace(~r/\s+/u, s, " ")
  end

  defp longest([]), do: nil
  defp longest(titles), do: Enum.max_by(titles, &String.length/1)

  defp literal_search_grouped(titles, per_pdf) do
    patterns = Enum.map(titles, &("%" <> escape_like(&1) <> "%"))

    # Window-rank within each PDF + window-count to know the total
    # match count up front (so the modal can show "Show N more matches"
    # without a second query). Outer caps at `rn <= per_pdf`.
    ranked =
      from(page in PdfPage,
        join: content in PdfPageContent,
        on: content.content_hash == page.content_hash,
        join: pdf in Pdf,
        on: pdf.file_uuid == page.file_uuid,
        where: pdf.status == "active",
        where: fragment("? ILIKE ANY(?)", content.text, ^patterns),
        select: %{
          pdf_uuid: pdf.uuid,
          page_number: page.page_number,
          text: content.text,
          pdf_inserted_at: pdf.inserted_at,
          total: fragment("COUNT(*) OVER (PARTITION BY ?)", pdf.uuid),
          rn:
            fragment(
              "ROW_NUMBER() OVER (PARTITION BY ? ORDER BY ?)",
              pdf.uuid,
              page.page_number
            )
        }
      )

    rows =
      from(r in subquery(ranked),
        where: r.rn <= ^per_pdf,
        order_by: [desc: r.pdf_inserted_at, asc: r.pdf_uuid, asc: r.page_number]
      )
      |> repo().all()

    rows
    |> assemble_groups(titles, fn row -> row.text end, fn _ -> 1.0 end)
  end

  defp trigram_search_grouped(nil, _threshold, _per_pdf), do: []

  defp trigram_search_grouped(query, threshold, per_pdf) do
    ranked =
      from(page in PdfPage,
        join: content in PdfPageContent,
        on: content.content_hash == page.content_hash,
        join: pdf in Pdf,
        on: pdf.file_uuid == page.file_uuid,
        where: pdf.status == "active",
        where: fragment("similarity(?, ?) > ?", content.text, ^query, ^threshold),
        select: %{
          pdf_uuid: pdf.uuid,
          page_number: page.page_number,
          text: content.text,
          pdf_inserted_at: pdf.inserted_at,
          score: fragment("similarity(?, ?)", content.text, ^query),
          total: fragment("COUNT(*) OVER (PARTITION BY ?)", pdf.uuid),
          rn:
            fragment(
              "ROW_NUMBER() OVER (PARTITION BY ? ORDER BY similarity(?, ?) DESC)",
              pdf.uuid,
              content.text,
              ^query
            )
        }
      )

    rows =
      from(r in subquery(ranked),
        where: r.rn <= ^per_pdf,
        order_by: [desc: r.pdf_inserted_at, asc: r.pdf_uuid, asc: r.rn]
      )
      |> repo().all()

    rows
    |> assemble_groups([query], fn row -> row.text end, fn row -> row.score || 0.0 end)
  end

  # Group consecutive rows by pdf_uuid into the public group shape.
  # Rows are pre-sorted by (pdf_inserted_at DESC, pdf.uuid ASC) so
  # `chunk_by` produces one group per PDF in the correct visual order.
  defp assemble_groups(rows, titles_for_snippet, snippet_text_fn, score_fn) do
    pdfs = bulk_load_pdfs(Enum.map(rows, & &1.pdf_uuid))

    rows
    |> Enum.chunk_by(& &1.pdf_uuid)
    |> Enum.map(fn group_rows ->
      first = List.first(group_rows)
      pdf = Map.fetch!(pdfs, first.pdf_uuid)

      hits =
        Enum.map(group_rows, fn row ->
          %{
            pdf: pdf,
            page_number: row.page_number,
            snippet: snippet_for(snippet_text_fn.(row), titles_for_snippet),
            score: score_fn.(row)
          }
        end)

      %{pdf: pdf, total_matches: first.total, hits: hits}
    end)
  end

  # ── More-within-one-PDF queries (for "Show N more matches" expand) ──

  defp literal_more(pdf_uuid, titles, offset, limit) do
    patterns = Enum.map(titles, &("%" <> escape_like(&1) <> "%"))

    rows =
      from(page in PdfPage,
        join: content in PdfPageContent,
        on: content.content_hash == page.content_hash,
        join: pdf in Pdf,
        on: pdf.file_uuid == page.file_uuid,
        where: pdf.status == "active",
        where: pdf.uuid == ^pdf_uuid,
        where: fragment("? ILIKE ANY(?)", content.text, ^patterns),
        order_by: [asc: page.page_number],
        offset: ^offset,
        limit: ^limit,
        select: %{
          pdf_uuid: pdf.uuid,
          page_number: page.page_number,
          text: content.text
        }
      )
      |> repo().all()

    case rows do
      [] ->
        []

      [first | _] ->
        pdf = repo().get!(Pdf, first.pdf_uuid)

        Enum.map(rows, fn row ->
          %{
            pdf: pdf,
            page_number: row.page_number,
            snippet: snippet_for(row.text, titles),
            score: 1.0
          }
        end)
    end
  end

  defp trigram_more(pdf_uuid, query, _titles, offset, limit) do
    rows =
      from(page in PdfPage,
        join: content in PdfPageContent,
        on: content.content_hash == page.content_hash,
        join: pdf in Pdf,
        on: pdf.file_uuid == page.file_uuid,
        where: pdf.status == "active",
        where: pdf.uuid == ^pdf_uuid,
        where: fragment("similarity(?, ?) > 0", content.text, ^query),
        order_by: [
          desc: fragment("similarity(?, ?)", content.text, ^query),
          asc: page.page_number
        ],
        offset: ^offset,
        limit: ^limit,
        select: %{
          pdf_uuid: pdf.uuid,
          page_number: page.page_number,
          text: content.text,
          score: fragment("similarity(?, ?)", content.text, ^query)
        }
      )
      |> repo().all()

    case rows do
      [] ->
        []

      [first | _] ->
        pdf = repo().get!(Pdf, first.pdf_uuid)

        Enum.map(rows, fn row ->
          %{
            pdf: pdf,
            page_number: row.page_number,
            snippet: snippet_for(row.text, [query]),
            score: row.score || 0.0
          }
        end)
    end
  end

  defp bulk_load_pdfs([]), do: %{}

  defp bulk_load_pdfs(uuids) do
    unique = Enum.uniq(uuids)

    from(p in Pdf, where: p.uuid in ^unique)
    |> repo().all()
    |> Map.new(fn pdf -> {pdf.uuid, pdf} end)
  end

  defp escape_like(s) when is_binary(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp snippet_for(text, titles) when is_binary(text) and is_list(titles) do
    text = collapse_ws(text)

    case find_title_match(String.downcase(text), titles) do
      nil ->
        String.slice(text, 0, 200)

      {start, _len} ->
        from = max(start - 60, 0)
        len = min(200, String.length(text) - from)
        String.slice(text, from, len)
    end
  end

  defp snippet_for(_, _), do: ""

  defp find_title_match(downcase_text, titles) do
    Enum.find_value(titles, fn title ->
      case :binary.match(downcase_text, String.downcase(title)) do
        :nomatch -> nil
        idx -> idx
      end
    end)
  end

  # ── Internal helpers ────────────────────────────────────────────────

  defp sha256_hex(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  @doc """
  Removes `phoenix_kit_cat_pdf_page_contents` rows that no
  `phoenix_kit_cat_pdf_pages` row references anymore. Safe to call
  any time.

  Returns the number of rows removed. Suitable for wiring to a daily
  Oban cron once the corpus is large enough to care.
  """
  @spec prune_orphan_page_contents() :: non_neg_integer()
  def prune_orphan_page_contents do
    referenced = from(p in PdfPage, select: p.content_hash, distinct: true)

    {count, _} =
      repo().delete_all(
        from(c in PdfPageContent, where: c.content_hash not in subquery(referenced))
      )

    count
  end

  # Enqueue the per-file extraction job — but only when it can actually
  # run. A misconfigured host (no `:catalogue_pdf` queue, or Oban not
  # started at all) would otherwise pile up `available` jobs that never
  # move while every extraction sits `pending` forever — invisible to
  # the operator. Instead we refuse to enqueue and flip the extraction
  # to a terminal `failed` status with an actionable message, so the
  # problem surfaces (library list + activity feed + logs) and no dead
  # jobs accumulate. The upload itself still succeeds and the PDF is
  # viewable; only text search is unavailable until the queue is fixed
  # and the file re-uploaded.
  #
  # Public (`@doc false`) for testability — see the enqueue-guard tests
  # in `PdfLibraryTest`. Called only from the upload pipeline.
  @doc false
  @spec enqueue_extraction(Ecto.UUID.t()) ::
          :ok | {:ok, Oban.Job.t()} | {:error, atom()}
  def enqueue_extraction(file_uuid) do
    cond do
      not Code.ensure_loaded?(PdfExtractor) ->
        # Worker not compiled in — abnormal build; leave the row pending.
        :ok

      catalogue_pdf_queue_available?() ->
        insert_extraction_job(file_uuid)

      true ->
        Logger.error(
          "PhoenixKitCatalogue: refusing to enqueue PDF extraction for " <>
            "#{inspect(file_uuid)} — :catalogue_pdf Oban queue is not running. " <>
            "Marking extraction failed so no dead jobs accumulate."
        )

        _ = mark_failed(file_uuid, @queue_unavailable_message)
        {:error, :extraction_queue_unavailable}
    end
  end

  defp insert_extraction_job(file_uuid) do
    case %{"file_uuid" => file_uuid} |> PdfExtractor.new() |> Oban.insert() do
      {:ok, _job} = ok ->
        ok

      {:error, reason} ->
        Logger.warning("PdfExtractor enqueue rejected: #{inspect(reason)}")
        _ = mark_failed(file_uuid, "Could not queue PDF text extraction: #{inspect(reason)}.")
        {:error, :enqueue_rejected}
    end
  rescue
    # Realistic Oban.insert failure modes: DB connectivity, schema drift
    # on `oban_jobs` (Ecto.QueryError / Postgrex.Error), or ArgumentError
    # when Oban hasn't been started. Anything else re-raises so it
    # surfaces in telemetry. We mark the extraction failed (rather than
    # leaving it pending) because nothing re-enqueues it — a silent
    # `pending` row is worse than a visible failure the operator can fix.
    e in [DBConnection.ConnectionError, Postgrex.Error, Ecto.QueryError, ArgumentError] ->
      Logger.warning("PdfExtractor enqueue failed: #{Exception.message(e)}")
      _ = mark_failed(file_uuid, "Could not queue PDF text extraction: #{Exception.message(e)}.")
      {:error, :enqueue_failed}
  end

  # True when an Oban instance is running and `:catalogue_pdf` jobs can
  # actually be processed. Reads the default `Oban` instance (matching
  # `Oban.insert/1`'s target); any failure to read the config (Oban not
  # started) counts as "not available".
  defp catalogue_pdf_queue_available? do
    case fetch_oban_config() do
      {:ok, config} -> queue_runnable?(config)
      :error -> false
    end
  end

  defp fetch_oban_config do
    {:ok, Oban.config()}
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  @doc false
  # Public (`@doc false`) for testability — pure decision over an Oban
  # config (or any map exposing `:testing` / `:queues`): a `:catalogue_pdf`
  # job can run when Oban is in a testing mode (`Oban.insert/1` is honored
  # without a live queue, e.g. a host's integration tests) OR the
  # `:catalogue_pdf` queue is configured to process jobs.
  @spec queue_runnable?(Oban.Config.t() | map()) :: boolean()
  def queue_runnable?(config) do
    Map.get(config, :testing, :disabled) != :disabled or
      Keyword.has_key?(Map.get(config, :queues, []), :catalogue_pdf)
  end
end
