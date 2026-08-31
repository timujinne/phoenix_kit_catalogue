defmodule PhoenixKitCatalogue.Paths do
  @moduledoc """
  Centralized path helpers for the Catalogue module.

  All paths go through `PhoenixKit.Utils.Routes.path/1` for prefix/locale handling.
  """

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Utils.Routes

  @base "/admin/catalogue"

  # ── Catalogues ───────────────────────────────────────────────────

  def index, do: Routes.path(@base)
  def catalogue_new, do: Routes.path("#{@base}/new")
  def catalogue_detail(uuid), do: Routes.path("#{@base}/#{uuid}")
  def catalogue_edit(uuid), do: Routes.path("#{@base}/#{uuid}/edit")

  # Drill-down levels on the catalogue detail page. The current category is
  # carried in a `?category=` query param (in-page push_patch), so these
  # are deep-linkable and back-button friendly. Root level is plain
  # `catalogue_detail/1`; `category_browse/2` drills into a category;
  # `uncategorized_browse/1` opens the uncategorized bucket.
  def category_browse(catalogue_uuid, category_uuid),
    do: Routes.path("#{@base}/#{catalogue_uuid}?category=#{category_uuid}")

  def uncategorized_browse(catalogue_uuid),
    do: Routes.path("#{@base}/#{catalogue_uuid}?category=uncategorized")

  # ── Import ───────────────────────────────────────────────────────

  def import, do: Routes.path("#{@base}/import")

  # ── Export ───────────────────────────────────────────────────────

  def export, do: Routes.path("#{@base}/export")

  @doc """
  Returns the download URL for a catalogue export.

  `params` is a map with required keys `:destination`, `:format`, and
  `:catalogue_uuids` (a list of UUID strings). All scalar values are strings
  or atoms. The `catalogue_uuids` list is encoded as repeated
  `catalogue_uuids[]` query parameters.
  """
  @spec export_download(map()) :: String.t()
  def export_download(
        %{destination: destination, format: format, catalogue_uuids: uuids} = params
      ) do
    base_pairs = [
      {"destination", to_string(destination)},
      {"format", to_string(format)}
    ]

    prefix_pairs =
      if Map.get(params, :prefix_catalogue) in [true, "true", "on", "1"],
        do: [{"prefix_catalogue", "true"}],
        else: []

    uuid_pairs = Enum.map(uuids, fn uuid -> {"catalogue_uuids[]", uuid} end)

    query = URI.encode_query(base_pairs ++ prefix_pairs ++ uuid_pairs)
    Routes.path("#{@base}/export/download?#{query}")
  end

  # ── Events ──────────────────────────────────────────────────────

  def events, do: Routes.path("#{@base}/events")

  # ── Manufacturers ────────────────────────────────────────────────

  # ── Suppliers ────────────────────────────────────────────────────

  # ── Attribute groups ─────────────────────────────────────────────

  def attribute_groups, do: Routes.path("#{@base}/attributes")
  def attribute_group_new, do: Routes.path("#{@base}/attributes/new")
  def attribute_group_edit(uuid), do: Routes.path("#{@base}/attributes/#{uuid}/edit")

  # ── Attribute sets (2026-08-18 rework) ───────────────────────────

  # ── Categories ───────────────────────────────────────────────────

  def category_new(catalogue_uuid), do: Routes.path("#{@base}/#{catalogue_uuid}/categories/new")
  def category_edit(uuid), do: Routes.path("#{@base}/categories/#{uuid}/edit")

  # ── Items ────────────────────────────────────────────────────────

  def item_new(catalogue_uuid), do: Routes.path("#{@base}/#{catalogue_uuid}/items/new")
  def item_edit(uuid), do: Routes.path("#{@base}/items/#{uuid}/edit")

  @doc """
  Raw (unprefixed) item edit path for phoenix_kit_comments back-links. The
  comments module applies the URL prefix/locale itself when rendering the
  resource chip, so this must NOT be prefixed (else the link double-prefixes).
  `tab:` lands on one of the form's tabs (`"sourcing"` for suppliers).
  """
  @spec item_edit_raw(String.t(), keyword()) :: String.t()
  def item_edit_raw(uuid, opts \\ []) when is_binary(uuid) do
    case Keyword.get(opts, :tab) do
      nil -> "#{@base}/items/#{uuid}/edit"
      tab -> "#{@base}/items/#{uuid}/edit?tab=#{tab}"
    end
  end

  # ── PDF library ──────────────────────────────────────────────────

  @spec pdfs() :: String.t()
  def pdfs, do: Routes.path("#{@base}/pdfs")

  @spec pdf_detail(Ecto.UUID.t()) :: String.t()
  def pdf_detail(uuid), do: Routes.path("#{@base}/pdfs/#{uuid}")

  @spec pdf_detail(Ecto.UUID.t(), pos_integer()) :: String.t()
  def pdf_detail(uuid, page) when is_integer(page) and page >= 1,
    do: Routes.path("#{@base}/pdfs/#{uuid}?page=#{page}")

  @doc """
  Signed URL under which the raw PDF binary is served. Resolves via
  core's `Storage.URLSigner` — the host app already routes
  `/file/:file_uuid/:variant/:token` through core's `FileController`.
  """
  @spec pdf_file(map()) :: String.t()
  def pdf_file(%{file_uuid: file_uuid}) when is_binary(file_uuid) do
    URLSigner.signed_url(file_uuid, "original")
  end

  @doc """
  Returns the PDF.js viewer URL with the file pre-bound and the
  optional page fragment set. The viewer assets are vendored under
  `priv/static/pdfjs/` and served at `/_pdfjs/` by the host
  endpoint's `Plug.Static` mount.

  The signed file URL is encoded via `URI.encode_www_form/1` so
  reserved characters in the underlying URL (`?`, `&`, `=`, `#`,
  spaces) become percent-escaped query-param-safe bytes — `URI.encode/1`
  alone does NOT escape those, which would corrupt the viewer's own
  `#page=N` fragment if the file URL ever carries them.
  """
  @spec pdf_viewer(map(), pos_integer()) :: String.t()
  def pdf_viewer(pdf, page) when is_integer(page) and page >= 1 do
    "/_pdfjs/web/viewer.html?file=" <>
      URI.encode_www_form(pdf_file(pdf)) <>
      "#page=" <> Integer.to_string(page)
  end

  @spec pdf_viewer(map()) :: String.t()
  def pdf_viewer(pdf) do
    "/_pdfjs/web/viewer.html?file=" <> URI.encode_www_form(pdf_file(pdf))
  end
end
