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

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.FileUpload, only: [file_upload: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.ActivityLog
  alias PhoenixKitCatalogue.Catalogue.PubSub, as: CataloguePubSub
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Web.Helpers

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

    {:ok,
     socket
     |> assign(
       page_title: Gettext.gettext(PhoenixKitCatalogue.Gettext, "PDFs"),
       filter: "active",
       pdfs: Catalogue.list_pdfs(status: "active"),
       upload_error: nil
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
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :pdf, ref)}
  end

  @impl true
  def handle_event("set_filter", %{"filter" => filter}, socket)
      when filter in ["active", "trashed"] do
    {:noreply,
     socket
     |> assign(:filter, filter)
     |> assign(:pdfs, Catalogue.list_pdfs(status: filter))}
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
             |> assign(:pdfs, Catalogue.list_pdfs(status: socket.assigns.filter))}

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
  def handle_info({:catalogue_data_changed, :pdf, _uuid, _parent}, socket) do
    {:noreply, assign(socket, :pdfs, Catalogue.list_pdfs(status: socket.assigns.filter))}
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
         |> assign(:pdfs, Catalogue.list_pdfs(status: socket.assigns.filter))}

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
    <div class="flex flex-col w-full px-4 py-6 gap-6">
      <div class="flex items-center justify-between">
        <h2 class="text-xl font-semibold">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "PDF library")}
        </h2>
        <div class="flex items-center gap-3">
          <div class="join">
            <button
              type="button"
              phx-click="set_filter"
              phx-value-filter="active"
              class={"join-item btn btn-sm #{if @filter == "active", do: "btn-primary", else: "btn-ghost"}"}
            >
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Active")}
            </button>
            <button
              type="button"
              phx-click="set_filter"
              phx-value-filter="trashed"
              class={"join-item btn btn-sm #{if @filter == "trashed", do: "btn-primary", else: "btn-ghost"}"}
            >
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Trash")}
            </button>
          </div>
          <div class="text-sm text-base-content/60">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{count} PDFs", count: length(@pdfs))}
          </div>
        </div>
      </div>

      <%!-- Upload zone (hidden in trash view) --%>
      <%= if @filter == "active" do %>
        <div class="bg-base-100 rounded-lg p-4">
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

          <div class="text-xs text-base-content/60 mt-2 italic">
            {Gettext.gettext(
              PhoenixKitCatalogue.Gettext,
              "The progress bar shows the browser → server upload only. Don't refresh until it completes — interrupted uploads are not resumed."
            )}
          </div>

          <%= for entry <- @uploads.pdf.entries do %>
            <%= for err <- upload_errors(@uploads.pdf, entry) do %>
              <div class="text-error text-xs mt-1">{format_upload_error(err)}</div>
            <% end %>
          <% end %>

          <%= if @upload_error do %>
            <div class="text-error text-xs mt-2">{@upload_error}</div>
          <% end %>
        </div>
      <% end %>

      <%!-- List --%>
      <div class="bg-base-100 rounded-lg shadow-sm border border-base-200 overflow-hidden">
        <%= if @pdfs == [] do %>
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
        <% else %>
          <table class="table table-sm">
            <thead class="text-xs uppercase text-base-content/60">
              <tr>
                <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Filename")}</th>
                <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}</th>
                <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Pages")}</th>
                <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Size")}</th>
                <th>
                  <%= if @filter == "trashed" do %>
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Trashed")}
                  <% else %>
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Uploaded")}
                  <% end %>
                </th>
                <th class="text-right">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Actions")}
                </th>
              </tr>
            </thead>
            <tbody>
              <%= for pdf <- @pdfs do %>
                <tr id={"pdf-row-#{pdf.uuid}"}>
                  <td class="font-medium">
                    <.link navigate={Paths.pdf_detail(pdf.uuid)} class="link link-hover">
                      {pdf.original_filename}
                    </.link>
                  </td>
                  <td>
                    {extraction_badge(pdf)}
                  </td>
                  <td>
                    {Helpers.pdf_extraction_pages(pdf) || "—"}
                  </td>
                  <td class="text-base-content/60">{Helpers.format_byte_size(pdf.byte_size)}</td>
                  <td class="text-base-content/60 text-xs">
                    {Helpers.format_time_ago(timestamp_for_filter(pdf, @filter))}
                  </td>
                  <td class="text-right">
                    <%= if @filter == "trashed" do %>
                      <button
                        type="button"
                        phx-click="restore"
                        phx-value-uuid={pdf.uuid}
                        phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restoring…")}
                        class="btn btn-ghost btn-xs"
                      >
                        <.icon name="hero-arrow-uturn-left" class="w-3.5 h-3.5" />
                      </button>
                      <button
                        type="button"
                        phx-click="permanently_delete"
                        phx-value-uuid={pdf.uuid}
                        phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleting…")}
                        data-confirm={
                          Gettext.gettext(
                            PhoenixKitCatalogue.Gettext,
                            "Permanently delete this PDF? If no other library entry references the same file content, the underlying file will be queued for hard deletion."
                          )
                        }
                        class="btn btn-ghost btn-xs text-error"
                      >
                        <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                      </button>
                    <% else %>
                      <button
                        type="button"
                        phx-click="trash"
                        phx-value-uuid={pdf.uuid}
                        phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Trashing…")}
                        data-confirm={
                          Gettext.gettext(
                            PhoenixKitCatalogue.Gettext,
                            "Move this PDF to trash?"
                          )
                        }
                        class="btn btn-ghost btn-xs text-error"
                      >
                        <.icon name="hero-trash" class="w-3.5 h-3.5" />
                      </button>
                    <% end %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────
  # Most PDF display helpers live in `Web.Helpers` and are shared with
  # `Web.PdfDetailLive`. The renderers that wrap raw markup stay here
  # because they're LV-specific layout choices.

  defp extraction_badge(pdf) do
    status = Helpers.pdf_extraction_status(pdf)
    label = Helpers.pdf_status_label(status)
    klass = Helpers.pdf_status_badge_class(status)

    case status do
      "failed" ->
        msg = Helpers.pdf_error_message(pdf) || ""

        Phoenix.HTML.raw(
          ~s|<span class="badge badge-sm #{klass}" title="#{Helpers.escape_html(msg)}">| <>
            Helpers.escape_html(label) <> "</span>"
        )

      _ ->
        Phoenix.HTML.raw(
          ~s|<span class="badge badge-sm #{klass}">| <>
            Helpers.escape_html(label) <> "</span>"
        )
    end
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
