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

  import Ecto.Query
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

  # Upper bound on how many stuck rows one `requeue_stuck_extractions/1`
  # call will touch, so a tenant with thousands of pending rows can't
  # enqueue (or fail-mark) thousands of jobs from a single admin click.
  # Re-running picks up the next batch.
  @requeue_cap 1000

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

  # ── Re-extraction / self-heal ───────────────────────────────────────

  @doc """
  Retries text extraction for a single PDF.

  Resets the extraction row to `pending` (clearing any prior
  `error_message`) and re-enqueues the worker. Use for a `failed` row
  (transient failure: queue was down, `pdftotext` hiccup) or one that
  looks stuck in `pending` / `extracting`.

  This is a **retry**, not a full re-extract: it does not delete existing
  `pdf_pages` rows or clear `page_count` / `extracted_at`. The worker's
  page inserts are upserts and `mark_extracted/2` overwrites `page_count`
  on success, so a re-run self-heals. The admin UI only offers Retry on
  `failed` rows (which carry no successful page data), so the distinction
  rarely matters in practice.

  The worker no-ops on a terminal status, so resetting to `pending`
  first is what lets a `failed` row run again.

  Returns:

    * `{:ok, extraction}` — reset + enqueued.
    * `{:error, :no_extraction}` — the file has no extraction row.
    * `{:error, :already_extracted}` — the row is already in a SUCCESS
      terminal (`extracted` / `scanned_no_text`). Refused so a stray
      caller can't reset a good extraction back to `pending` and drop the
      PDF out of search mid-run. Pass `force: true` to override (e.g. a
      deliberate re-extract after a normalizer change). The admin UI only
      offers Retry on `failed` rows, so this only bites a programmatic
      caller.
    * `{:error, reason}` — the enqueue guard refused (e.g.
      `:extraction_queue_unavailable` when the `:catalogue_pdf` queue
      still isn't running). The row is left `failed` with the
      actionable message in that case, exactly as on upload.

  Accepts a `%Pdf{}` (the LV path) or a bare `file_uuid`.

  ## Options

    * `:force` (default `false`) — re-run even a success-terminal row.
  """
  @spec retry_extraction(Pdf.t() | Ecto.UUID.t(), keyword()) ::
          {:ok, PdfExtraction.t()} | {:error, term()}
  def retry_extraction(pdf_or_file_uuid, opts \\ [])

  def retry_extraction(%Pdf{file_uuid: file_uuid}, opts),
    do: retry_extraction(file_uuid, opts)

  def retry_extraction(file_uuid, opts) when is_binary(file_uuid) do
    force = Keyword.get(opts, :force, false)

    case repo().get(PdfExtraction, file_uuid) do
      nil ->
        {:error, :no_extraction}

      %PdfExtraction{extraction_status: status}
      when status in ["extracted", "scanned_no_text"] and not force ->
        {:error, :already_extracted}

      _extraction ->
        reset_and_reenqueue(file_uuid, opts)
    end
  end

  defp reset_and_reenqueue(file_uuid, opts) do
    with {:ok, reset} <-
           update_extraction(file_uuid, %{extraction_status: "pending", error_message: nil}) do
      finish_retry(enqueue_extraction(file_uuid), reset, file_uuid, opts)
    end
  end

  # enqueue_extraction already flipped the row back to `failed` with an
  # actionable message on its guarded paths — surface the reason so the
  # LV can flash it.
  defp finish_retry({:error, _reason} = err, _reset, _file_uuid, _opts), do: err

  defp finish_retry(_ok, reset, file_uuid, opts) do
    log_retry(file_uuid, opts)
    {:ok, reset}
  end

  @doc """
  Re-enqueues extraction for every PDF stuck in a non-terminal state.

  The heal path for PDFs uploaded while the `:catalogue_pdf` queue was
  unavailable (their jobs never ran) or orphaned `extracting` rows whose
  worker died mid-run. The per-upload `enqueue_extraction/1` guard only
  fires at upload time, so without this nothing ever re-drives those rows.

  `pending` rows are always re-enqueued — no live job can exist for them.
  `extracting` rows are re-enqueued only when older than
  `:stale_after_seconds` (default `900`) so an actively-running
  extraction isn't double-processed.

  Returns `{:ok, %{requeued: n, skipped: s, failed: m}}`:

    * `requeued` — rows whose extraction job was actually (re-)enqueued.
    * `skipped` — rows a live job already covers, so there was nothing to
      do (the app-level dedup). Reported separately so `requeued` can't
      claim credit for rows we didn't touch.
    * `failed` — rows whose enqueue was refused (e.g. the `:catalogue_pdf`
      queue is still not running, so they were marked `failed` with the
      actionable message instead).

  The split keeps "re-queued N" honest when every enqueue actually failed
  or was a no-op. Safe to call repeatedly (the worker is idempotent).

  The whole selection is de-duped against live jobs in a single query and
  enqueued with one `Oban.insert_all/1`, so a full `#{@requeue_cap}`-row
  click is a handful of statements rather than ~2k per-row round-trips.

  Capped at `#{@requeue_cap}` rows per call; re-run to process more.

  ## Options

    * `:stale_after_seconds` (default `900`) — minimum age of an
      `extracting` row before it's considered orphaned.
    * `:limit` (default `#{@requeue_cap}`) — max rows touched per call.
  """
  @spec requeue_stuck_extractions(keyword()) ::
          {:ok,
           %{
             requeued: non_neg_integer(),
             skipped: non_neg_integer(),
             failed: non_neg_integer()
           }}
  def requeue_stuck_extractions(opts \\ []) do
    stale_after = Keyword.get(opts, :stale_after_seconds, 900)
    limit = Keyword.get(opts, :limit, @requeue_cap)

    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-stale_after, :second)
      |> DateTime.truncate(:second)

    file_uuids =
      repo().all(
        from(e in PdfExtraction,
          where:
            e.extraction_status == "pending" or
              (e.extraction_status == "extracting" and e.updated_at < ^cutoff),
          select: e.file_uuid,
          limit: ^limit
        )
      )

    if length(file_uuids) >= limit do
      Logger.warning(
        "PhoenixKitCatalogue: requeue_stuck_extractions hit the #{limit}-row cap; re-run to process the rest."
      )
    end

    {:ok, bulk_requeue(file_uuids)}
  end

  # One audit row per active/trashed PDF entry pointing at this file.
  defp log_retry(file_uuid, opts) do
    from(p in Pdf, where: p.file_uuid == ^file_uuid)
    |> repo().all()
    |> Enum.each(fn pdf ->
      ActivityLog.log(%{
        action: "pdf.extraction_retried",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "pdf",
        resource_uuid: pdf.uuid,
        metadata: %{"original_filename" => pdf.original_filename, "file_uuid" => file_uuid}
      })
    end)
  end

  # ── Worker callbacks (file_uuid-keyed) ──────────────────────────────

  @doc false
  @spec mark_extracting(Ecto.UUID.t()) ::
          {:ok, PdfExtraction.t() | :superseded} | {:error, term()}
  def mark_extracting(file_uuid) do
    # Guarded: only advance from a non-terminal state. If a concurrent
    # worker already reached a terminal state, this returns
    # `{:ok, :superseded}` and the worker stops instead of pulling a
    # finished extraction back to `extracting`.
    guarded_update_extraction(file_uuid, ["pending", "extracting"], %{
      extraction_status: "extracting"
    })
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
          {:ok, PdfExtraction.t() | :superseded} | {:error, term()}
  def mark_failed(file_uuid, error_message) do
    truncated = error_message |> to_string() |> String.slice(0, 500)

    # Guarded against ["pending", "extracting"] ONLY: a concurrent worker
    # that already reached a SUCCESS terminal (`extracted` /
    # `scanned_no_text`) must never be clobbered back to `failed` — that
    # would silently drop a good extraction and break search. When the
    # guard blocks the write the success stands and we log nothing.
    case guarded_update_extraction(file_uuid, ["pending", "extracting"], %{
           extraction_status: "failed",
           error_message: truncated
         }) do
      {:ok, %PdfExtraction{}} = ok ->
        log_extraction_per_pdf(
          "pdf.extraction_failed",
          file_uuid,
          %{"error_message" => truncated},
          %{}
        )

        ok

      {:ok, :superseded} = ok ->
        ok

      {:error, reason} = err ->
        log_extraction_per_pdf(
          "pdf.extraction_failed",
          file_uuid,
          %{"error_message" => truncated},
          %{
            "db_pending" => true,
            "error_kind" => failure_error_kind(reason),
            "reason" => failure_reason(reason)
          }
        )

        err
    end
  end

  # Unconditional status write (used by the retry reset + the success
  # markers, where last-writer-wins is the intended semantics — a success
  # SHOULD overwrite a prior `failed`).
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

  # Atomic, guarded status write: applies `attrs` only when the row's
  # current `extraction_status` is one of `from_statuses`. A single
  # `UPDATE ... WHERE status IN (...)` can't race a status a concurrent
  # worker already advanced past — this is what makes two jobs on the same
  # file_uuid safe.
  #
  #   {:ok, %PdfExtraction{}} — the write landed (reloaded + broadcast)
  #   {:ok, :superseded}      — guard blocked it; a concurrent worker
  #                             already moved the row out of `from_statuses`
  #   {:error, :not_found}    — no extraction row for this file_uuid
  defp guarded_update_extraction(file_uuid, from_statuses, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    set = attrs |> Map.put(:updated_at, now) |> Map.to_list()

    {count, _} =
      repo().update_all(
        from(e in PdfExtraction,
          where: e.file_uuid == ^file_uuid and e.extraction_status in ^from_statuses
        ),
        set: set
      )

    cond do
      count > 0 ->
        broadcast_for_file(file_uuid)
        {:ok, repo().get(PdfExtraction, file_uuid)}

      repo().exists?(from(e in PdfExtraction, where: e.file_uuid == ^file_uuid)) ->
        {:ok, :superseded}

      true ->
        {:error, :not_found}
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
    # A non-terminal job already covering this file means we skip the
    # insert (the pile-up the Retry/requeue paths would otherwise cause)
    # and treat it as success — the existing job will run.
    if extraction_job_pending?(file_uuid) do
      :ok
    else
      do_insert_extraction_job(file_uuid)
    end
  end

  defp do_insert_extraction_job(file_uuid) do
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

  # Derived from the aliased module (not a hardcoded literal) so a rename
  # is caught at compile time instead of silently breaking the dedup query.
  # `inspect/1` of a module atom yields the same prefix-less form Oban
  # stores in `oban_jobs.worker` ("PhoenixKitCatalogue.Workers.PdfExtractor").
  @extractor_worker inspect(PdfExtractor)

  # True when a non-terminal `PdfExtractor` job already covers this file.
  #
  # Queries ONLY the four states present in every Oban version
  # (`available` / `scheduled` / `executing` / `retryable`) — never
  # `:suspended` / `:cancelled`, which may be absent from the host's
  # `oban_job_state` enum when the Oban lib was upgraded ahead of its
  # migration (querying a missing enum value raises `22P02`). Any query
  # failure (no `oban_jobs` table, DB error) returns `false` so the
  # enqueue still proceeds — a possible duplicate that the idempotent
  # worker collapses beats a dropped extraction.
  #
  # PERF NOTE: the `args ->> 'file_uuid'` filter has no index, so on a host
  # with a busy `oban_jobs` table this (and `live_extraction_job_file_uuids/1`)
  # seq-scans. `oban_jobs` is owned by core/the host, and this repo ships no
  # migrations of its own (see AGENTS.md), so the index belongs in a core
  # `phoenix_kit` migration when the job table grows large:
  #
  #   CREATE INDEX CONCURRENTLY oban_jobs_catalogue_pdf_file_uuid_idx
  #     ON oban_jobs ((args ->> 'file_uuid'))
  #     WHERE worker = 'PhoenixKitCatalogue.Workers.PdfExtractor'
  #       AND state IN ('available','scheduled','executing','retryable');
  defp extraction_job_pending?(file_uuid) do
    repo().exists?(
      from(j in Oban.Job,
        where: j.worker == @extractor_worker,
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        where: fragment("? ->> 'file_uuid' = ?", j.args, ^file_uuid)
      )
    )
  rescue
    e in [DBConnection.ConnectionError, Postgrex.Error, Ecto.QueryError, ArgumentError] ->
      Logger.warning(
        "PdfExtractor dedup check failed (proceeding to enqueue): #{Exception.message(e)}"
      )

      false
  end

  # ── Batched self-heal enqueue (requeue_stuck_extractions/1) ─────────
  #
  # Unlike the per-upload `enqueue_extraction/1` (one row, one Oban
  # round-trip), this de-dupes the whole selection against live jobs in a
  # SINGLE query and inserts the survivors with one `Oban.insert_all/1` —
  # so a 1000-row admin click is a handful of statements, not ~2000. The
  # returned counts stay honest: `requeued` rows we actually enqueued,
  # `skipped` rows a live job already covers, `failed` rows whose enqueue
  # was refused (queue not running → marked `failed` with the message).
  defp bulk_requeue([]), do: %{requeued: 0, skipped: 0, failed: 0}

  defp bulk_requeue(file_uuids) do
    cond do
      not Code.ensure_loaded?(PdfExtractor) ->
        # Worker not compiled in — abnormal build; leave the rows pending.
        %{requeued: 0, skipped: length(file_uuids), failed: 0}

      not catalogue_pdf_queue_available?() ->
        # Same terminal-fail semantics as the per-row guard, so "Retry
        # stuck" surfaces the misconfiguration instead of lying.
        Enum.each(file_uuids, &mark_failed(&1, @queue_unavailable_message))
        %{requeued: 0, skipped: 0, failed: length(file_uuids)}

      true ->
        live = live_extraction_job_file_uuids(file_uuids)
        {fresh, skipped} = Enum.split_with(file_uuids, &(not Map.has_key?(live, &1)))
        Map.put(do_bulk_enqueue(fresh), :skipped, length(skipped))
    end
  end

  defp do_bulk_enqueue([]), do: %{requeued: 0, failed: 0}

  defp do_bulk_enqueue(file_uuids) do
    jobs =
      file_uuids
      |> Enum.map(&PdfExtractor.new(%{"file_uuid" => &1}))
      |> Oban.insert_all()

    %{requeued: length(jobs), failed: 0}
  rescue
    e in [DBConnection.ConnectionError, Postgrex.Error, Ecto.QueryError, ArgumentError] ->
      Logger.warning("PdfExtractor bulk enqueue failed: #{Exception.message(e)}")

      Enum.each(
        file_uuids,
        &mark_failed(&1, "Could not queue PDF text extraction: #{Exception.message(e)}.")
      )

      %{requeued: 0, failed: length(file_uuids)}
  end

  # Single-query batch counterpart to `extraction_job_pending?/1`: which of
  # these file_uuids already have a non-terminal `PdfExtractor` job. Same
  # four-states-only rationale and same fail-open behavior — any query
  # failure returns an empty set so we proceed to enqueue (a duplicate the
  # idempotent worker collapses beats a dropped extraction). Returns a
  # membership map (`%{file_uuid => true}`) rather than a `MapSet` — the set
  # would trip a dialyzer opaqueness false-positive at the `Map.has_key?`
  # caller, and a plain map is just as good for the O(1) lookup here.
  @spec live_extraction_job_file_uuids([Ecto.UUID.t()]) :: %{optional(String.t()) => true}
  defp live_extraction_job_file_uuids(file_uuids) do
    repo().all(
      from(j in Oban.Job,
        where: j.worker == @extractor_worker,
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        where: fragment("? ->> 'file_uuid' = ANY(?)", j.args, ^file_uuids),
        select: fragment("? ->> 'file_uuid'", j.args)
      )
    )
    |> Map.from_keys(true)
  rescue
    e in [DBConnection.ConnectionError, Postgrex.Error, Ecto.QueryError, ArgumentError] ->
      Logger.warning(
        "PdfExtractor bulk dedup check failed (proceeding to enqueue all): #{Exception.message(e)}"
      )

      %{}
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
