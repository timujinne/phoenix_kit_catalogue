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

  # ── Events ──────────────────────────────────────────────────────

  def events, do: Routes.path("#{@base}/events")

  # ── Manufacturers ────────────────────────────────────────────────

  def manufacturers, do: Routes.path("#{@base}/manufacturers")
  def manufacturer_new, do: Routes.path("#{@base}/manufacturers/new")
  def manufacturer_edit(uuid), do: Routes.path("#{@base}/manufacturers/#{uuid}/edit")

  # ── Suppliers ────────────────────────────────────────────────────

  def suppliers, do: Routes.path("#{@base}/suppliers")
  def supplier_new, do: Routes.path("#{@base}/suppliers/new")
  def supplier_edit(uuid), do: Routes.path("#{@base}/suppliers/#{uuid}/edit")

  # ── Categories ───────────────────────────────────────────────────

  def category_new(catalogue_uuid), do: Routes.path("#{@base}/#{catalogue_uuid}/categories/new")
  def category_edit(uuid), do: Routes.path("#{@base}/categories/#{uuid}/edit")

  # ── Items ────────────────────────────────────────────────────────

  def item_new(catalogue_uuid), do: Routes.path("#{@base}/#{catalogue_uuid}/items/new")
  def item_edit(uuid), do: Routes.path("#{@base}/items/#{uuid}/edit")

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
