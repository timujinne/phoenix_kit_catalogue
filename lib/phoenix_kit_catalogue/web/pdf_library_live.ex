defmodule PhoenixKitCatalogue.Web.PdfLibraryLive do
  @moduledoc """
  Admin index for the PDF library subtab.

  Shows the upload dropzone, list of uploaded PDFs filtered by
  lifecycle (active vs trashed), per-row extraction status badge,
  and trash/restore/permanent-delete actions. Subscribes to the
  catalogue PubSub topic so worker status changes refresh the list
  without a manual reload.
  """

  use Phoenix.LiveView

  use PhoenixKitWeb.Live.UrlState,
    params: [
      filter: [default: "active", url_key: "filter", in: ~w(active trashed)],
      search: [default: "", url_key: "q"]
    ]

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.FileUpload, only: [file_upload: 1]
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu
  import PhoenixKitCatalogue.Web.Components, only: [view_toggle_instant: 1, view_storage_key: 0]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.ActivityLog
  alias PhoenixKitCatalogue.Catalogue.PubSub, as: CataloguePubSub
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Web.Helpers
  alias PhoenixKitCatalogue.Web.TableQuery
  alias PhoenixKitCatalogue.Web.ViewConfig

  # PhoenixKit auto-applies its admin chrome layout to external module admin
  # views via socket.private[:live_layout]. Opt out here so this view can
  # self-wrap with LayoutWrapper.app_layout and push its title/subtitle into
  # the global admin header (same pattern as /admin/media and orders/index).
  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

  @max_file_size 200 * 1024 * 1024
  # Chunk size for the WS upload — large enough to keep round-trips
  # cheap on big PDFs (default LV is 64 KB ≈ 1600 chunks for a 100 MB
  # upload). 5 MB is well within Phoenix 1.8's `:infinity` default
  # `max_frame_size`.
  @upload_chunk_size 5_000_000
  @max_concurrent_uploads 5

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: CataloguePubSub.subscribe()

    # No DB query in mount (it runs twice — dead HTTP render + live socket).
    # The list loads in `handle_params/3`, which also lets the `?filter=`
    # query param deep-link straight into the trashed view.
    {:ok,
     socket
     |> assign(
       page_title: Gettext.gettext(PhoenixKitCatalogue.Gettext, "PDFs"),
       # Module-wide view preference, shared with every catalogue page.
       view_mode: ViewConfig.load_view(socket.assigns[:phoenix_kit_current_user]),
       pdfs: [],
       upload_error: nil,
       show_content_search: false
     )
     |> allow_upload(:pdf,
       accept: ~w(.pdf application/pdf),
       max_entries: @max_concurrent_uploads,
       max_file_size: @max_file_size,
       chunk_size: @upload_chunk_size,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_url_state(state, socket) do
    # Only the status filter decides which rows come back — the search is
    # applied client-side by filter_by_search/2 at render. Reloading on a
    # search change would re-run list_pdfs/1 once per debounce pause for a
    # byte-identical result, so the query is confined to a real filter change.
    # `prior_filter` is nil only before the first call; the filter itself is
    # whitelisted to "active" or "trashed" and never nil.
    if state.filter == socket.assigns[:prior_filter] do
      socket
    else
      socket
      |> assign(:prior_filter, state.filter)
      |> assign_pdfs()
    end
  end

  # The list query lives here (not mount) so it runs once on the live
  # connection rather than twice. On the disconnected dead render
  # (`connected?` false) we skip it — the connected render fills the list in.
  defp assign_pdfs(socket) do
    if connected?(socket) do
      assign(socket, pdfs: Catalogue.list_pdfs(status: socket.assigns.filter), pdfs_loaded: true)
    else
      # Not loaded yet, not empty — the dead render must show a skeleton,
      # not "No PDFs uploaded yet."
      assign(socket, pdfs: [], pdfs_loaded: false)
    end
  end

  @impl true
  def handle_event("set_view", %{"mode" => v}, socket) when v in ["table", "card", "comfy"] do
    {:noreply, socket |> ViewConfig.save_view_on(v) |> assign(:view_mode, v)}
  end

  def handle_event("set_view", _params, socket), do: {:noreply, socket}

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :pdf, ref)}
  end

  @impl true
  def handle_event("set_filter", %{"filter" => filter}, socket)
      when filter in ["active", "trashed"] do
    {:noreply, push_url_state(socket, filter: filter, search: "")}
  end

  @impl true
  def handle_event("search", %{"query" => q}, socket) do
    {:noreply, push_url_state(socket, [search: q], replace: true)}
  end

  def handle_event("open_content_search", _params, socket) do
    {:noreply, assign(socket, :show_content_search, true)}
  end

  @impl true
  def handle_event("trash", %{"uuid" => uuid}, socket) do
    handle_pdf_action(socket, uuid, &Catalogue.trash_pdf/2,
      operation: "trash_pdf",
      success: Gettext.gettext(PhoenixKitCatalogue.Gettext, "PDF moved to trash."),
      failure: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Could not move the PDF to trash.")
    )
  end

  @impl true
  def handle_event("restore", %{"uuid" => uuid}, socket) do
    handle_pdf_action(socket, uuid, &Catalogue.restore_pdf/2,
      operation: "restore_pdf",
      success: Gettext.gettext(PhoenixKitCatalogue.Gettext, "PDF restored."),
      failure: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Could not restore the PDF.")
    )
  end

  @impl true
  def handle_event("permanently_delete", %{"uuid" => uuid}, socket) do
    handle_pdf_action(socket, uuid, &Catalogue.permanently_delete_pdf/2,
      operation: "permanently_delete_pdf",
      success: Gettext.gettext(PhoenixKitCatalogue.Gettext, "PDF permanently deleted."),
      failure:
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "Could not permanently delete the PDF.")
    )
  end

  @impl true
  def handle_event("retry_extraction", %{"uuid" => uuid}, socket) do
    handle_pdf_action(socket, uuid, &Catalogue.retry_extraction/2,
      operation: "retry_extraction",
      success: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Re-queued text extraction."),
      failure:
        Gettext.gettext(
          PhoenixKitCatalogue.Gettext,
          "Could not start extraction. The :catalogue_pdf Oban queue may not be running."
        )
    )
  end

  @impl true
  def handle_event("requeue_stuck", _params, socket) do
    {:ok, counts} = Catalogue.requeue_stuck_extractions()

    socket =
      socket
      |> flash_requeue_result(counts)
      |> assign_pdfs()

    {:noreply, socket}
  end

  # Honest flash: a warning (not "success") when some/all enqueues were
  # refused — which is exactly the queue-missing case this button targets —
  # and a distinct note when rows were skipped because a job already covers
  # them, so "Re-queued N" never claims credit for work it didn't do.
  defp flash_requeue_result(socket, %{requeued: 0, skipped: 0, failed: 0}) do
    put_flash(
      socket,
      :info,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "No stuck extractions to re-queue.")
    )
  end

  defp flash_requeue_result(socket, %{failed: failed} = counts) when failed > 0 do
    put_flash(
      socket,
      :warning,
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Re-queued %{ok}; %{failed} could not be queued — the :catalogue_pdf queue may not be running.",
        ok: counts.requeued,
        failed: failed
      )
    )
  end

  defp flash_requeue_result(socket, %{requeued: requeued, skipped: 0}) do
    put_flash(
      socket,
      :info,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Re-queued %{count} stuck extraction(s).",
        count: requeued
      )
    )
  end

  defp flash_requeue_result(socket, %{requeued: requeued, skipped: skipped}) do
    put_flash(
      socket,
      :info,
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Re-queued %{count} stuck extraction(s); %{skipped} already running.",
        count: requeued,
        skipped: skipped
      )
    )
  end

  defp handle_pdf_action(socket, uuid, action_fn, messages) do
    case Catalogue.get_pdf(uuid) do
      nil ->
        {:noreply, socket}

      pdf ->
        case action_fn.(pdf, Helpers.actor_opts(socket)) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, Keyword.fetch!(messages, :success))
             |> assign_pdfs()}

          {:error, reason} ->
            Helpers.log_operation_error(socket, Keyword.fetch!(messages, :operation), %{
              entity_type: "pdf",
              entity_uuid: pdf.uuid,
              reason: reason
            })

            {:noreply, put_flash(socket, :error, Keyword.fetch!(messages, :failure))}
        end
    end
  end

  @impl true
  def handle_info({:pdf_search_modal_closed}, socket) do
    {:noreply, assign(socket, :show_content_search, false)}
  end

  def handle_info({:catalogue_data_changed, :pdf, _uuid, _parent}, socket) do
    {:noreply, assign_pdfs(socket)}
  end

  def handle_info({:catalogue_data_changed, _kind, _uuid, _parent}, socket),
    do: {:noreply, socket}

  def handle_info(msg, socket) do
    Logger.debug("PdfLibraryLive ignored unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ── Upload progress handler ─────────────────────────────────────────

  defp handle_progress(:pdf, entry, socket) do
    if entry.done? do
      finalize_upload(socket, entry)
    else
      {:noreply, socket}
    end
  end

  defp finalize_upload(socket, entry) do
    consume_result =
      consume_uploaded_entry(socket, entry, fn %{path: tmp_path} ->
        # `byte_size` is intentionally NOT passed through — the context
        # reads the truth from `File.stat!(tmp_path).size` so the
        # persisted value can't be lied about by the browser.
        {:ok,
         Catalogue.create_pdf_from_upload(
           tmp_path,
           entry.client_name,
           Helpers.actor_opts(socket)
         )}
      end)

    case consume_result do
      {:ok, _pdf} ->
        {:noreply,
         socket
         |> assign(:upload_error, nil)
         |> assign_pdfs()}

      {:error, reason} ->
        # Log path-leak-safe failure summary (drop full `inspect`).
        Logger.warning(fn ->
          "PDF upload failed: " <> failure_log_label(reason)
        end)

        # `db_pending: true` activity row so the user-initiated upload
        # is in the audit trail even when storage / catalogue insert
        # failed. Action mirrors the success-side `pdf.uploaded`.
        ActivityLog.log(%{
          action: "pdf.uploaded",
          mode: "manual",
          actor_uuid: Helpers.actor_uuid(socket),
          resource_type: "pdf",
          metadata: %{
            "db_pending" => true,
            "error_kind" => failure_error_kind(reason),
            "reason" => failure_log_label(reason),
            "original_filename" => entry.client_name,
            # `client_size` is browser-supplied; flagged with `client_`
            # prefix so audit consumers know it's untrusted (the
            # success-side `byte_size` is computed server-side).
            "client_size" => entry.client_size
          }
        })

        {:noreply, assign(socket, :upload_error, format_upload_failure(reason))}
    end
  end

  # User-visible flash text — gettext-wrapped, no `inspect` reveal of
  # internal shapes (paths, exception structs).
  defp format_upload_failure({:storage_failed, _}),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Could not save the uploaded file. Please try again or contact support if it persists."
      )

  defp format_upload_failure(_),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Upload failed for an unexpected reason. Please try again."
      )

  # Logger / activity-metadata-safe summary (no absolute paths).
  defp failure_log_label({:storage_failed, %Ecto.Changeset{errors: errors}}),
    do:
      "storage_failed:changeset(" <>
        (errors |> Enum.map(fn {k, _} -> Atom.to_string(k) end) |> Enum.uniq() |> Enum.join(",")) <>
        ")"

  defp failure_log_label({:storage_failed, atom}) when is_atom(atom),
    do: "storage_failed:#{atom}"

  defp failure_log_label({:storage_failed, _}), do: "storage_failed:other"
  defp failure_log_label(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp failure_log_label(_), do: "other"

  defp failure_error_kind({:storage_failed, %Ecto.Changeset{}}), do: "changeset"
  defp failure_error_kind({:storage_failed, _}), do: "storage"
  defp failure_error_kind(atom) when is_atom(atom), do: "atom"
  defp failure_error_kind(_), do: "other"

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "PDF library")}
      page_subtitle={
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue") <>
          " · " <>
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{count} PDFs", count: length(@pdfs))
      }
      current_path={assigns[:url_path] || Paths.pdfs()}
      current_locale={assigns[:current_locale]}
    >
      <div class="flex flex-col w-full px-4 py-6 gap-6">
        <%!-- Filter toolbar: active/trash toggle + retry-stuck + count --%>
        <div class="flex items-center gap-3 flex-wrap">
          <div class="join">
            <button
              type="button"
              phx-click="set_filter"
              phx-value-filter="active"
              class={[
                "join-item btn btn-sm",
                if(@filter == "active", do: "btn-primary", else: "btn-ghost")
              ]}
            >
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Active")}
            </button>
            <button
              type="button"
              phx-click="set_filter"
              phx-value-filter="trashed"
              class={[
                "join-item btn btn-sm",
                if(@filter == "trashed", do: "btn-primary", else: "btn-ghost")
              ]}
            >
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Trash")}
            </button>
          </div>
          <button
            :if={@filter == "active"}
            type="button"
            phx-click="requeue_stuck"
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Re-queuing…")}
            class="btn btn-ghost btn-sm"
            title={
              Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "Re-queue any PDFs whose text extraction never ran or got stuck (e.g. after the job queue was down)."
              )
            }
          >
            <.icon name="hero-arrow-path" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Retry stuck")}
          </button>
          <div class="text-sm text-base-content/60">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{count} PDFs", count: length(@pdfs))}
          </div>
          <button
            type="button"
            phx-click="open_content_search"
            class="btn btn-sm btn-outline ml-auto"
          >
            <.icon name="hero-document-magnifying-glass" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search PDF contents")}
          </button>
        </div>

        <%!-- Upload zone (hidden in trash view) --%>
        <div :if={@filter == "active"} class="bg-base-100 rounded-lg p-4">
          <.file_upload
            upload={@uploads.pdf}
            label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Upload PDF")}
            icon="hero-document-arrow-up"
            accept_description={
              Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "PDF files only. Identical content is deduplicated; same file uploaded again under a new name shares one underlying file + extraction."
              )
            }
            max_size_description="200MB"
          />


          <%= for entry <- @uploads.pdf.entries do %>
            <%= for err <- upload_errors(@uploads.pdf, entry) do %>
              <div class="text-error text-xs mt-1">{format_upload_error(err)}</div>
            <% end %>
          <% end %>

          <div :if={@upload_error} class="text-error text-xs mt-2">{@upload_error}</div>
        </div>

        <%!-- Filename search shares its row with the table/card view
             toggle (the table's built-in toggle is suppressed below).
             Content search lives in the modal behind the header button. --%>
        <% visible_pdfs = filter_by_search(@pdfs, @search) %>
        <div class="flex flex-wrap items-center gap-3">
          <form
            id="pdf-library-search"
            phx-change="search"
            phx-submit="search"
            class="grow basis-64 sm:max-w-72"
          >
            <label class="input input-sm w-full">
              <.icon name="hero-magnifying-glass" class="h-4 w-4 opacity-50" />
              <input
                type="search"
                name="query"
                value={@search}
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search by filename…")}
                class="grow"
                phx-debounce="300"
              />
            </label>
          </form>
          <.view_toggle_instant :if={visible_pdfs != []} view={@view_mode} id="pdf-view-pref" class="ml-auto" />
        </div>

        <.live_component
          module={PhoenixKitCatalogue.Web.Components.PdfSearchModal}
          id="pdf-content-search"
          mode={:library}
          show={@show_content_search}
        />

        <%!-- PDF list --%>
        <%= cond do %>
          <% !@pdfs_loaded -> %>
            <div class="flex flex-col gap-3" aria-busy="true">
              <div class="skeleton h-16 w-full"></div>
              <div class="skeleton h-16 w-full"></div>
            </div>
          <% @pdfs == [] -> %>
            <div class="text-center py-12 text-base-content/60">
              <.icon name="hero-document-text" class="w-12 h-12 mx-auto mb-2 opacity-50" />
              <p>
                <%= if @filter == "trashed" do %>
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Trash is empty.")}
                <% else %>
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No PDFs uploaded yet.")}
                <% end %>
              </p>
            </div>
          <% visible_pdfs == [] -> %>
            <div class="text-center py-12 text-base-content/60">
              <.icon name="hero-magnifying-glass" class="w-12 h-12 mx-auto mb-2 opacity-50" />
              <p>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "No PDFs matching your search.")}</p>
            </div>
          <% true -> %>
          <.table_default
            id="pdf-library-table"
            size="sm"
            toggleable={true}
            show_toggle={false}
            storage_key={view_storage_key()}
            items={visible_pdfs}
            card_title={fn pdf -> pdf.original_filename end}
            card_fields={fn pdf ->
              [
                %{
                  label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status"),
                  value: Helpers.pdf_status_label(Helpers.pdf_extraction_status(pdf))
                },
                %{
                  label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Pages"),
                  value: Helpers.pdf_extraction_pages(pdf) || "—"
                },
                %{
                  label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Size"),
                  value: Helpers.format_byte_size(pdf.byte_size)
                },
                %{
                  label:
                    if(@filter == "trashed",
                      do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Trashed"),
                      else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Uploaded")
                    ),
                  value: Helpers.format_time_ago(timestamp_for_filter(pdf, @filter))
                }
              ]
            end}
          >
            <.table_default_header>
              <.table_default_row>
                <.table_default_header_cell>
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Filename")}
                </.table_default_header_cell>
                <.table_default_header_cell>
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}
                </.table_default_header_cell>
                <.table_default_header_cell>
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Pages")}
                </.table_default_header_cell>
                <.table_default_header_cell>
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Size")}
                </.table_default_header_cell>
                <.table_default_header_cell>
                  <%= if @filter == "trashed" do %>
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Trashed")}
                  <% else %>
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Uploaded")}
                  <% end %>
                </.table_default_header_cell>
                <.table_default_header_cell class="text-right">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Actions")}
                </.table_default_header_cell>
              </.table_default_row>
            </.table_default_header>
            <.table_default_body>
              <%= for pdf <- visible_pdfs do %>
                <.table_default_row id={"pdf-row-#{pdf.uuid}"}>
                  <.table_default_cell class="font-medium">
                    <.link navigate={Paths.pdf_detail(pdf.uuid)} class="link link-hover">
                      {pdf.original_filename}
                    </.link>
                  </.table_default_cell>
                  <.table_default_cell>
                    <.extraction_badge pdf={pdf} />
                  </.table_default_cell>
                  <.table_default_cell>
                    {Helpers.pdf_extraction_pages(pdf) || "—"}
                  </.table_default_cell>
                  <.table_default_cell class="text-base-content/60">
                    {Helpers.format_byte_size(pdf.byte_size)}
                  </.table_default_cell>
                  <.table_default_cell class="text-base-content/60 text-xs">
                    {Helpers.format_time_ago(timestamp_for_filter(pdf, @filter))}
                  </.table_default_cell>
                  <.table_default_cell class="text-right">
                    <%= if @filter == "trashed" do %>
                      <.table_row_menu mode="auto" id={"pdf-trashed-menu-#{pdf.uuid}"}>
                        <.table_row_menu_button
                          phx-click="restore"
                          phx-value-uuid={pdf.uuid}
                          phx-disable-with={
                            Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restoring…")
                          }
                          icon="hero-arrow-uturn-left"
                          label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
                          variant="success"
                        />
                        <.table_row_menu_divider />
                        <.table_row_menu_button
                          phx-click="permanently_delete"
                          phx-value-uuid={pdf.uuid}
                          phx-disable-with={
                            Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleting…")
                          }
                          data-confirm={
                            Gettext.gettext(
                              PhoenixKitCatalogue.Gettext,
                              "Permanently delete this PDF? If no other library entry references the same file content, the underlying file will be queued for hard deletion."
                            )
                          }
                          icon="hero-trash"
                          label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
                          variant="error"
                        />
                      </.table_row_menu>
                    <% else %>
                      <.table_row_menu mode="auto" id={"pdf-active-menu-#{pdf.uuid}"}>
                        <.table_row_menu_button
                          :if={Helpers.pdf_extraction_status(pdf) == "failed"}
                          phx-click="retry_extraction"
                          phx-value-uuid={pdf.uuid}
                          phx-disable-with={
                            Gettext.gettext(PhoenixKitCatalogue.Gettext, "Retrying…")
                          }
                          icon="hero-arrow-path"
                          label={
                            Gettext.gettext(PhoenixKitCatalogue.Gettext, "Retry extraction")
                          }
                        />
                        <.table_row_menu_divider
                          :if={Helpers.pdf_extraction_status(pdf) == "failed"}
                        />
                        <.table_row_menu_button
                          phx-click="trash"
                          phx-value-uuid={pdf.uuid}
                          phx-disable-with={
                            Gettext.gettext(PhoenixKitCatalogue.Gettext, "Trashing…")
                          }
                          data-confirm={
                            Gettext.gettext(
                              PhoenixKitCatalogue.Gettext,
                              "Move this PDF to trash?"
                            )
                          }
                          icon="hero-trash"
                          label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
                          variant="error"
                        />
                      </.table_row_menu>
                    <% end %>
                  </.table_default_cell>
                </.table_default_row>
              <% end %>
            </.table_default_body>
            <:card_actions :let={pdf}>
              <%= if @filter == "trashed" do %>
                <button
                  phx-click="restore"
                  phx-value-uuid={pdf.uuid}
                  class="btn btn-ghost btn-xs text-success"
                >
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
                </button>
                <button
                  phx-click="permanently_delete"
                  phx-value-uuid={pdf.uuid}
                  data-confirm={
                    Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "Permanently delete this PDF? If no other library entry references the same file content, the underlying file will be queued for hard deletion."
                    )
                  }
                  class="btn btn-ghost btn-xs text-error"
                >
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
                </button>
              <% else %>
                <button
                  :if={Helpers.pdf_extraction_status(pdf) == "failed"}
                  phx-click="retry_extraction"
                  phx-value-uuid={pdf.uuid}
                  class="btn btn-ghost btn-xs"
                >
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Retry")}
                </button>
                <button
                  phx-click="trash"
                  phx-value-uuid={pdf.uuid}
                  data-confirm={
                    Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "Move this PDF to trash?"
                    )
                  }
                  class="btn btn-ghost btn-xs text-error"
                >
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
                </button>
              <% end %>
            </:card_actions>
          </.table_default>
        <% end %>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────
  # Most PDF display helpers live in `Web.Helpers` and are shared with
  # `Web.PdfDetailLive`. The renderers that wrap raw markup stay here
  # because they're LV-specific layout choices.

  defp filter_by_search(pdfs, search),
    do: TableQuery.search(pdfs, search, & &1.original_filename)

  # HEEx component (was hand-built `Phoenix.HTML.raw` string concat) — gets
  # auto-escaping of the label + failure title for free. `@title` is nil for
  # non-failed rows, so HEEx omits the attribute, matching the old markup.
  attr(:pdf, :map, required: true)

  defp extraction_badge(assigns) do
    status = Helpers.pdf_extraction_status(assigns.pdf)

    assigns =
      assign(assigns,
        klass: Helpers.pdf_status_badge_class(status),
        label: Helpers.pdf_status_label(status),
        title: if(status == "failed", do: Helpers.pdf_error_message(assigns.pdf) || "", else: nil)
      )

    ~H"""
    <span class={"badge badge-sm #{@klass}"} title={@title}>{@label}</span>
    """
  end

  # Trashed-list view shows when the row was trashed; everything else
  # shows the upload time.
  defp timestamp_for_filter(pdf, "trashed"), do: pdf.trashed_at || pdf.inserted_at
  defp timestamp_for_filter(pdf, _), do: pdf.inserted_at

  defp format_upload_error(:too_large),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "File is too large.")

  defp format_upload_error(:not_accepted),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Only PDF files are accepted.")

  defp format_upload_error(:too_many_files),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Too many files at once.")

  defp format_upload_error(other), do: inspect(other)
end
