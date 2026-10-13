defmodule PhoenixKitCatalogue.Workers.PdfExtractor do
  @moduledoc """
  Oban worker that extracts text page-by-page from a PDF through the
  `PdfEngines` chain: pdfium (in-app precompiled NIF — no system
  packages needed) first, poppler (`pdfinfo`/`pdftotext`) as the
  fallback when installed.

  Keyed by `file_uuid` (core's `phoenix_kit_files.uuid`), not the
  per-upload `phoenix_kit_cat_pdfs.uuid` — so two uploads of identical
  content share one extraction job.

  ## Lifecycle

  1. Look up the extraction row by `file_uuid`. If terminal
     (`extracted` / `scanned_no_text` / `failed`), no-op (retry of an
     already-done job, or duplicate enqueue from a content-dedup
     upload).
  2. Resolve the binary via `Storage.retrieve_file/1` — returns a
     temp path. Works whether the file lives on local disk, S3, or
     anything core supports.
  3. Mark `"extracting"`.
  4. `PdfEngines.open_best/1` picks the engine and reports the page
     count. If every engine refuses, that's fatal (the stored message
     lists each engine's reason).
  5. For each page, extract with the chosen engine, normalize, hash,
     upsert into the per-page content cache, insert a `pdf_pages` row.
  6. Transition to `extracted` (or `scanned_no_text` if all pages
     came back empty). Retryable failures leave the row `extracting`
     and return `{:error, _}` so Oban retries; `failed` is written
     only on the last attempt.

  ## Concurrency

  Configured via the host app's Oban queue config. Recommend
  `queue: :catalogue_pdf, limit: 2` so a 1000-page PDF doesn't pin
  CPU or block other queues.

  ## Deduplication

  Re-enqueueing the same content (duplicate-content upload, the self-heal
  `requeue_stuck_extractions/1`, or the per-PDF Retry button) is deduped
  *application-side* in `PdfLibrary.insert_extraction_job/1` — it skips
  the insert when a non-terminal `PdfExtractor` job already exists for the
  `file_uuid`. We deliberately do **not** use Oban's built-in `unique:`
  option: satisfying its compile-time check requires listing every
  incomplete state including `:suspended`, but that enum value is absent
  from the `oban_job_state` enum on hosts that upgraded the Oban *library*
  without running its latest *migration* — the uniqueness query then
  raises `22P02` and kills every enqueue. The app-side guard queries only
  the four states (`available` / `scheduled` / `executing` / `retryable`)
  present in every Oban version. Races are harmless: this worker
  short-circuits on a terminal status and page inserts are upserts.
  """

  use Oban.Worker,
    queue: :catalogue_pdf,
    max_attempts: 3

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitCatalogue.Catalogue.PdfEngines
  alias PhoenixKitCatalogue.Catalogue.PdfLibrary
  alias PhoenixKitCatalogue.Schemas.{PdfExtraction, PdfPage}

  # Success terminals only. `"failed"` must stay retryable — marking the
  # row failed and then treating that status as `:ok` on the next attempt
  # made `max_attempts: 3` a no-op (attempt 1 writes failed, attempt 2
  # short-circuits as success).
  @success_terminals ~w(extracted scanned_no_text)

  @doc false
  @spec success_terminal?(String.t() | nil) :: boolean()
  def success_terminal?(status), do: status in @success_terminals

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"file_uuid" => file_uuid}} = job) do
    repo = PhoenixKit.RepoHelper.repo()

    case repo.get(PdfExtraction, file_uuid) do
      nil ->
        {:cancel, :extraction_not_found}

      %{extraction_status: status} when status in @success_terminals ->
        :ok

      %PdfExtraction{} = extraction ->
        run(extraction, job)
    end
  end

  def perform(_job), do: {:cancel, :missing_file_uuid}

  defp run(%PdfExtraction{file_uuid: file_uuid}, job) do
    case Storage.retrieve_file(file_uuid) do
      {:ok, temp_path, _file} ->
        try do
          do_extract(file_uuid, temp_path, job)
        after
          _ = File.rm(temp_path)
        end

      {:error, reason} ->
        fail(file_uuid, "could not retrieve file: #{inspect(reason)}", job)
    end
  end

  defp do_extract(file_uuid, file_path, job) do
    case PdfLibrary.mark_extracting(file_uuid) do
      # A concurrent worker already reached a SUCCESS terminal for this
      # file — nothing to do (and we must NOT pull it back to extracting).
      {:ok, :superseded} ->
        :ok

      {:ok, _extraction} ->
        run_extraction(file_uuid, file_path, job)

      {:error, reason} ->
        fail(file_uuid, reason, job)
    end
  end

  defp run_extraction(file_uuid, file_path, job) do
    case PdfEngines.open_best(file_path) do
      {:ok, engine} ->
        Logger.info(
          "PdfExtractor: extracting #{inspect(file_uuid)} with #{engine.name} " <>
            "(#{engine.page_count} pages)"
        )

        try do
          {ok_count, failed} = extract_pages(file_uuid, engine)
          finalize_with_failures(file_uuid, engine, ok_count, Enum.reverse(failed), job)
        after
          PdfEngines.close(engine)
        end

      {:error, attempts} ->
        fail(file_uuid, {:no_engine, attempts}, job)
    end
  end

  # Every page failed (a wholly unreadable file): fail the job so Oban
  # retries — don't mark an empty document as successfully extracted.
  defp finalize_with_failures(file_uuid, _engine, 0, [_ | _] = failed, job) do
    fail(file_uuid, {:all_pages_failed, summarize_failures(failed)}, job)
  end

  # At least one page extracted: keep the usable partial result. A single
  # corrupt page (or a transient per-page hiccup) no longer discards the
  # whole document and burns all retries — we log the unreadable pages and
  # finalize on what we got.
  defp finalize_with_failures(file_uuid, engine, _ok_count, failed, _job) do
    if failed != [] do
      Logger.warning(
        "PdfExtractor: #{length(failed)} page(s) failed for #{inspect(file_uuid)}; " <>
          "keeping partial extraction (#{summarize_failures(failed)})"
      )
    end

    finalize(file_uuid, engine)
  end

  defp summarize_failures(failed) do
    failed
    |> Enum.map_join("; ", fn {page, reason} -> "p#{page}: #{inspect_reason(reason)}" end)
    |> String.slice(0, 500)
  end

  # Persist `failed` only on the last Oban attempt so earlier tries leave
  # the row `extracting` and the next attempt can actually run.
  defp fail(file_uuid, reason, job) do
    message = inspect_reason(reason)

    if job.attempt >= job.max_attempts do
      _ = PdfLibrary.mark_failed(file_uuid, message)
    end

    {:error, message}
  end

  defp finalize(file_uuid, engine) do
    extra = %{"engine" => engine.name}

    result =
      if all_pages_empty?(file_uuid) do
        PdfLibrary.mark_scanned_no_text(file_uuid, engine.page_count, extra)
      else
        PdfLibrary.mark_extracted(file_uuid, engine.page_count, extra)
      end

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, inspect_reason(reason)}
    end
  end

  defp all_pages_empty?(file_uuid) do
    repo = PhoenixKit.RepoHelper.repo()

    any_page? =
      from(p in PdfPage, where: p.file_uuid == ^file_uuid, limit: 1)
      |> repo.exists?()

    any_text? =
      from(p in PdfPage,
        join: c in assoc(p, :content),
        where: p.file_uuid == ^file_uuid,
        where: fragment("length(btrim(?)) > 0", c.text),
        limit: 1
      )
      |> repo.exists?()

    any_page? and not any_text?
  end

  # Returns `{succeeded_count, failed}` where `failed` is a list of
  # `{page_number, reason}` in reverse page order. Continues past a failed
  # page instead of halting, so one bad page doesn't discard the rest.
  defp extract_pages(_file_uuid, %{page_count: n}) when n <= 0, do: {0, [{0, :empty_document}]}

  defp extract_pages(file_uuid, engine) do
    Enum.reduce(1..engine.page_count, {0, []}, fn page_number, {ok_count, failed} ->
      case extract_page(file_uuid, engine, page_number) do
        :ok -> {ok_count + 1, failed}
        {:error, reason} -> {ok_count, [{page_number, reason} | failed]}
      end
    end)
  end

  defp extract_page(file_uuid, engine, page_number) do
    case PdfEngines.extract_page(engine, page_number) do
      {:ok, raw} ->
        text = normalize(raw)

        case PdfLibrary.insert_page(file_uuid, page_number, text) do
          {:ok, _} -> :ok
          {:error, cs} -> {:error, {:insert_page_failed, page_number, cs}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Normalize page text:
  # - Drop invalid UTF-8 bytes and NUL codepoints (NUL is valid UTF-8
  #   but Postgres `text` rejects it — one NUL from an engine would
  #   otherwise crash the page insert and burn the job's retries)
  # - Strip soft-hyphens
  # - Undo line-break hyphenation: "Pre-\nmium" → "Premium"
  # - Replace common ligatures (ﬁ, ﬂ, ﬀ, ﬃ, ﬄ)
  # - Collapse all whitespace runs to a single space
  # - Trim
  @doc false
  # Public for testability — pure-function text normalizer applied to
  # every page's engine output before storage.
  @spec normalize(binary()) :: String.t()
  def normalize(text) when is_binary(text) do
    text
    |> scrub_utf8()
    |> String.replace(<<0>>, "")
    |> String.replace("­", "")
    |> ligatures()
    |> then(&Regex.replace(~r/-\r?\n(\w)/u, &1, "\\1"))
    |> then(&Regex.replace(~r/\s+/u, &1, " "))
    |> String.trim()
  end

  def normalize(_), do: ""

  # Rebuilds the binary from its valid UTF-8 codepoints, skipping any
  # invalid bytes (possible from `pdftotext` on damaged font data;
  # Rust-backed engines always emit valid UTF-8, so this usually no-ops
  # on the fast full-binary validity check). A recursive walk, not a
  # bitstring comprehension — a `<<cp::utf8 <- text>>` generator HALTS
  # at the first non-matching byte, which would silently drop the whole
  # rest of the page.
  defp scrub_utf8(text) do
    if String.valid?(text), do: text, else: do_scrub(text, <<>>)
  end

  defp do_scrub(<<cp::utf8, rest::binary>>, acc), do: do_scrub(rest, <<acc::binary, cp::utf8>>)
  defp do_scrub(<<_bad, rest::binary>>, acc), do: do_scrub(rest, acc)
  defp do_scrub(<<>>, acc), do: acc

  defp ligatures(text) do
    text
    |> String.replace("ﬁ", "fi")
    |> String.replace("ﬂ", "fl")
    |> String.replace("ﬀ", "ff")
    |> String.replace("ﬃ", "ffi")
    |> String.replace("ﬄ", "ffl")
  end

  @doc false
  # Public for testability — collapses internal worker error tuples
  # into the human-readable string stored in `extractions.error_message`
  # and surfaced by the LV's "Extraction failed" alert.
  @spec inspect_reason(term()) :: String.t()
  def inspect_reason({:pdfinfo_failed, msg}), do: "pdfinfo: #{msg}"

  def inspect_reason({:no_engine, attempts}) do
    detail = Enum.map_join(attempts, "; ", fn {name, reason} -> "#{name}: #{inspect(reason)}" end)
    "no PDF engine could open the file (#{String.slice(detail, 0, 400)})"
  end

  def inspect_reason({:pdfium_page_failed, page, reason}),
    do: "pdfium failed on page #{page}: #{inspect(reason)}"

  def inspect_reason({:pdftotext_failed, page, code, msg}),
    do: "pdftotext failed on page #{page} (exit #{inspect(code)}): #{msg}"

  def inspect_reason({:insert_page_failed, page, _cs}),
    do: "could not insert page #{page} (DB error)"

  def inspect_reason({:all_pages_failed, summary}),
    do: "all pages failed (#{summary})"

  def inspect_reason(other), do: inspect(other)
end
