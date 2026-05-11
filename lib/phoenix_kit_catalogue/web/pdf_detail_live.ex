defmodule PhoenixKitCatalogue.Web.PdfDetailLive do
  @moduledoc """
  Single-PDF detail page. Shows metadata + extraction status, embeds
  the vendored PDF.js viewer in an iframe pre-bound to the file and
  the optional `?page=N` URL param.

  When a search hit from the per-item PDF search button navigates
  here with `?page=N`, the iframe URL embeds `#page=N` and PDF.js
  scrolls the viewer to that page on load.
  """

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub, as: CataloguePubSub
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Web.Helpers

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    # Subscribe BEFORE the initial load. A worker `:catalogue_data_changed`
    # broadcast arriving between `load_pdf` and `subscribe` would
    # otherwise be lost — the LV would render the stale "Extraction in
    # progress" alert until the next manual refresh. Cost of this
    # ordering: at most one duplicate refresh in the rare race window
    # (handle_info re-fetches the same row and assigns are unchanged).
    if connected?(socket), do: CataloguePubSub.subscribe()

    case load_pdf(uuid) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, Gettext.gettext(PhoenixKitCatalogue.Gettext, "PDF not found."))
         |> push_navigate(to: Paths.pdfs())}

      pdf ->
        {:ok,
         assign(socket,
           pdf: pdf,
           page_title: pdf.original_filename,
           page: nil
         )}
    end
  end

  defp load_pdf(uuid) do
    case Catalogue.get_pdf(uuid) do
      nil -> nil
      pdf -> PhoenixKit.RepoHelper.repo().preload(pdf, :extraction)
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page_param(Map.get(params, "page"))
    {:noreply, assign(socket, :page, page)}
  end

  @impl true
  def handle_event("trash", _params, socket) do
    detail_pdf_action(socket, &Catalogue.trash_pdf/2,
      operation: "trash_pdf",
      success: Gettext.gettext(PhoenixKitCatalogue.Gettext, "PDF moved to trash."),
      failure: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Could not move the PDF to trash."),
      after_ok: :push_navigate
    )
  end

  @impl true
  def handle_event("restore", _params, socket) do
    detail_pdf_action(socket, &Catalogue.restore_pdf/2,
      operation: "restore_pdf",
      success: Gettext.gettext(PhoenixKitCatalogue.Gettext, "PDF restored."),
      failure: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Could not restore the PDF."),
      after_ok: :reload
    )
  end

  @impl true
  def handle_event("permanently_delete", _params, socket) do
    detail_pdf_action(socket, &Catalogue.permanently_delete_pdf/2,
      operation: "permanently_delete_pdf",
      success: Gettext.gettext(PhoenixKitCatalogue.Gettext, "PDF permanently deleted."),
      failure:
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "Could not permanently delete the PDF."),
      after_ok: :push_navigate
    )
  end

  defp detail_pdf_action(socket, action_fn, opts) do
    pdf = socket.assigns.pdf

    case action_fn.(pdf, Helpers.actor_opts(socket)) do
      {:ok, _} ->
        ok_socket = put_flash(socket, :info, Keyword.fetch!(opts, :success))

        case Keyword.fetch!(opts, :after_ok) do
          :push_navigate -> {:noreply, push_navigate(ok_socket, to: Paths.pdfs())}
          :reload -> {:noreply, assign(ok_socket, :pdf, load_pdf(pdf.uuid))}
        end

      {:error, reason} ->
        Helpers.log_operation_error(socket, Keyword.fetch!(opts, :operation), %{
          entity_type: "pdf",
          entity_uuid: pdf.uuid,
          reason: reason
        })

        {:noreply, put_flash(socket, :error, Keyword.fetch!(opts, :failure))}
    end
  end

  @impl true
  def handle_info({:catalogue_data_changed, :pdf, uuid, _parent}, socket) do
    if uuid == socket.assigns.pdf.uuid do
      case load_pdf(uuid) do
        nil -> {:noreply, push_navigate(socket, to: Paths.pdfs())}
        refreshed -> {:noreply, assign(socket, :pdf, refreshed)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:catalogue_data_changed, _kind, _uuid, _parent}, socket),
    do: {:noreply, socket}

  def handle_info(msg, socket) do
    Logger.debug("PdfDetailLive ignored unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp parse_page_param(nil), do: nil

  defp parse_page_param(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 1 -> n
      _ -> nil
    end
  end

  defp parse_page_param(_), do: nil

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-6xl px-4 py-6 gap-4">
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <.link
              navigate={Paths.pdfs()}
              class="btn btn-ghost btn-xs"
              title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Back to library")}
            >
              <.icon name="hero-arrow-left" class="w-4 h-4" />
            </.link>
            <h2 class="text-lg font-semibold truncate" title={@pdf.original_filename}>
              {@pdf.original_filename}
            </h2>
            <%= if @pdf.status == "trashed" do %>
              <span class="badge badge-sm badge-warning">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Trashed")}
              </span>
            <% end %>
          </div>

          <div class="flex items-center gap-3 mt-2 text-xs text-base-content/60">
            <span class={"badge badge-sm #{Helpers.pdf_status_badge_class(Helpers.pdf_extraction_status(@pdf))}"}>
              {Helpers.pdf_status_label(Helpers.pdf_extraction_status(@pdf))}
            </span>
            <%= if Helpers.pdf_extraction_pages(@pdf) do %>
              <span>
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{count} pages",
                  count: Helpers.pdf_extraction_pages(@pdf)
                )}
              </span>
            <% end %>
            <%= if @pdf.byte_size do %>
              <span>{Helpers.format_byte_size(@pdf.byte_size)}</span>
            <% end %>
            <%= if Helpers.pdf_extracted_at(@pdf) do %>
              <span>
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Extracted")}: {Calendar.strftime(
                  Helpers.pdf_extracted_at(@pdf),
                  Gettext.gettext(PhoenixKitCatalogue.Gettext, "%b %d, %Y %H:%M")
                )}
              </span>
            <% end %>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <%= if @pdf.status == "trashed" do %>
            <button
              type="button"
              phx-click="restore"
              phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restoring…")}
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
            </button>
            <button
              type="button"
              phx-click="permanently_delete"
              phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleting…")}
              data-confirm={
                Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Permanently delete this PDF? If no other library entry references the same file content, the underlying file will be queued for hard deletion."
                )
              }
              class="btn btn-ghost btn-sm text-error"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete forever")}
            </button>
          <% else %>
            <button
              type="button"
              phx-click="trash"
              phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Trashing…")}
              data-confirm={
                Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move this PDF to trash?")
              }
              class="btn btn-ghost btn-sm text-error"
            >
              <.icon name="hero-trash" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Trash")}
            </button>
          <% end %>
        </div>
      </div>

      <%= if Helpers.pdf_extraction_status(@pdf) == "failed" and Helpers.pdf_error_message(@pdf) do %>
        <div class="alert alert-error">
          <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
          <div>
            <div class="font-semibold">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Extraction failed")}
            </div>
            <div class="text-xs opacity-80">{Helpers.pdf_error_message(@pdf)}</div>
          </div>
        </div>
      <% end %>

      <%= if Helpers.pdf_extraction_status(@pdf) == "scanned_no_text" do %>
        <div class="alert alert-warning">
          <.icon name="hero-photo" class="w-4 h-4" />
          <div>
            <div class="font-semibold">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No extractable text")}
            </div>
            <div class="text-xs opacity-80">
              {Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "This PDF appears to be scanned. OCR support is planned for a future iteration."
              )}
            </div>
          </div>
        </div>
      <% end %>

      <%= if Helpers.pdf_extraction_status(@pdf) in ["pending", "extracting"] do %>
        <div class="alert alert-info">
          <span class="loading loading-spinner loading-sm"></span>
          <div>
            {Gettext.gettext(
              PhoenixKitCatalogue.Gettext,
              "Text extraction in progress. This page will refresh automatically when it completes."
            )}
          </div>
        </div>
      <% end %>

      <%!-- PDF.js embedded viewer --%>
      <div class="rounded-lg border border-base-300 overflow-hidden bg-base-200" style="height: 80vh">
        <iframe
          src={viewer_url(@pdf, @page)}
          class="w-full h-full border-0"
          title={@pdf.original_filename}
        >
        </iframe>
      </div>
    </div>
    """
  end

  defp viewer_url(pdf, nil), do: Paths.pdf_viewer(pdf)
  defp viewer_url(pdf, page) when is_integer(page), do: Paths.pdf_viewer(pdf, page)
end
