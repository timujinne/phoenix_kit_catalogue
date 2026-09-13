defmodule PhoenixKitCatalogue.Catalogue.PdfEngines do
  @moduledoc """
  Engine chain for PDF text extraction: pdfium (in-app, precompiled NIF)
  first, poppler (`pdfinfo`/`pdftotext` system binaries) as the fallback
  when installed.

  The chain exists so a host needs NO system packages for PDF search to
  work: `ex_pdfium` ships Chrome's PDF engine as a precompiled binary
  fetched during `mix deps.get`. Hosts that already have poppler keep it
  as a safety net for files pdfium cannot open. Benchmarked 2026-08-16
  on the tim-dev corpus: pdfium word recall vs `pdftotext -layout` was
  98.4–100% per document (`dev_docs` has the numbers).

  `open_best/1` tries each engine in order and commits to the first one
  that can open the document and report a page count — per-page failures
  after that point are the worker's business (it keeps partial results).
  When every engine refuses, the per-engine reasons are returned
  together so the stored error message names them all.
  """

  @typedoc "An opened document, bound to the engine that opened it."
  @type engine :: %{name: String.t(), page_count: non_neg_integer(), state: term()}

  @doc """
  Opens `path` with the first engine that accepts it.

  Returns `{:ok, engine}` or `{:error, attempts}` where `attempts` is a
  `[{engine_name, reason}]` list covering every engine tried (including
  unavailable ones, so "poppler: not installed" shows up in the stored
  failure message rather than silently narrowing the chain).
  """
  @spec open_best(String.t()) :: {:ok, engine()} | {:error, [{String.t(), term()}]}
  def open_best(path) do
    Enum.reduce_while([&open_pdfium/1, &open_poppler/1], {:error, []}, fn open, {:error, acc} ->
      case open.(path) do
        {:ok, engine} -> {:halt, {:ok, engine}}
        {:error, name, reason} -> {:cont, {:error, acc ++ [{name, reason}]}}
      end
    end)
  end

  @doc """
  Extracts one page's raw text (1-based `page_number`) with the engine
  that opened the document.
  """
  @spec extract_page(engine(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def extract_page(%{name: "pdfium", state: doc}, page_number) do
    case ExPdfium.extract_text(doc, page_number - 1) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, {:pdfium_page_failed, page_number, reason}}
    end
  rescue
    e -> {:error, {:pdfium_page_failed, page_number, Exception.message(e)}}
  end

  def extract_page(%{name: "poppler", state: path}, page_number) do
    args = [
      "-layout",
      "-enc",
      "UTF-8",
      "-f",
      Integer.to_string(page_number),
      "-l",
      Integer.to_string(page_number),
      path,
      "-"
    ]

    # `stderr_to_stdout: false` on the success path — stdout IS the page
    # text, so warnings must not leak into it. `pdftotext` writes its
    # failure reasons to stderr only, so on the (rare) failure path we
    # rerun the page with stderr merged purely to harvest the message.
    case System.cmd("pdftotext", args, stderr_to_stdout: false) do
      {raw, 0} ->
        {:ok, raw}

      {_raw, code} ->
        {:error, {:pdftotext_failed, page_number, code, pdftotext_error_detail(args)}}
    end
  rescue
    e in ErlangError ->
      {:error,
       {:pdftotext_failed, page_number, :enoent, "pdftotext not on PATH: #{Exception.message(e)}"}}
  end

  @doc """
  Releases engine resources: the pdfium document handle is closed
  eagerly instead of waiting for BEAM GC to collect the NIF resource.
  No-op for poppler.
  """
  @spec close(engine()) :: :ok
  def close(%{name: "pdfium", state: doc}) do
    _ = ExPdfium.close(doc)
    :ok
  rescue
    _ -> :ok
  end

  def close(_engine), do: :ok

  defp pdftotext_error_detail(args) do
    case System.cmd("pdftotext", args, stderr_to_stdout: true) do
      {raw, _code} -> String.slice(raw || "", 0, 200)
    end
  rescue
    _ -> ""
  end

  # ── pdfium ──────────────────────────────────────────────────────────

  # The NIF is a hard dep, but `Code.ensure_loaded?` + rescue keep an
  # exotic platform where the precompiled artifact failed to load from
  # crashing the worker — it degrades to poppler with a clear reason.
  defp open_pdfium(path) do
    if Code.ensure_loaded?(ExPdfium) do
      case ExPdfium.open(path) do
        {:ok, doc} -> finish_pdfium_open(doc)
        {:error, reason} -> {:error, "pdfium", reason}
      end
    else
      {:error, "pdfium", :not_loaded}
    end
  rescue
    e -> {:error, "pdfium", Exception.message(e)}
  end

  # `page_count == 0` is an open failure (try poppler), not a successful
  # empty document — committing here would mark the extraction extracted
  # with no pages and refuse retry. Close the handle on every reject so
  # a page_count error does not leak the NIF resource until GC.
  defp finish_pdfium_open(doc) do
    case ExPdfium.page_count(doc) do
      {:ok, n} when is_integer(n) and n > 0 ->
        {:ok, %{name: "pdfium", page_count: n, state: doc}}

      {:ok, n} ->
        _ = ExPdfium.close(doc)
        {:error, "pdfium", {:empty_document, n}}

      {:error, reason} ->
        _ = ExPdfium.close(doc)
        {:error, "pdfium", reason}
    end
  rescue
    e ->
      _ = ExPdfium.close(doc)
      {:error, "pdfium", Exception.message(e)}
  end

  # ── poppler ─────────────────────────────────────────────────────────

  defp open_poppler(path) do
    if System.find_executable("pdftotext") && System.find_executable("pdfinfo") do
      case pdfinfo_page_count(path) do
        {:ok, n} when is_integer(n) and n > 0 ->
          {:ok, %{name: "poppler", page_count: n, state: path}}

        {:ok, n} ->
          {:error, "poppler", {:empty_document, n}}

        {:error, reason} ->
          {:error, "poppler", reason}
      end
    else
      {:error, "poppler", :not_installed}
    end
  end

  defp pdfinfo_page_count(path) do
    case System.cmd("pdfinfo", [path], stderr_to_stdout: true) do
      {output, 0} ->
        parse_page_count(output)

      {raw, _code} ->
        {:error, {:pdfinfo_failed, String.slice(raw || "", 0, 300)}}
    end
  rescue
    e in ErlangError ->
      {:error, {:pdfinfo_failed, "pdfinfo not on PATH: #{Exception.message(e)}"}}
  end

  @doc false
  # Public for testability — internal pure function over `pdfinfo`'s
  # text output. Returns `{:ok, n}` or `{:error, {:pdfinfo_failed, msg}}`.
  @spec parse_page_count(String.t()) ::
          {:ok, non_neg_integer()} | {:error, {:pdfinfo_failed, String.t()}}
  def parse_page_count(output) when is_binary(output) do
    Regex.scan(~r/^Pages:\s+(\d+)/m, output)
    |> List.first()
    |> case do
      [_, count_str] ->
        case Integer.parse(count_str) do
          {n, _} when n >= 0 -> {:ok, n}
          _ -> {:error, {:pdfinfo_failed, "couldn't parse page count: #{output}"}}
        end

      _ ->
        {:error, {:pdfinfo_failed, "no Pages: line in pdfinfo output"}}
    end
  end
end
