defmodule PhoenixKitCatalogue.Web.Components.PdfSearchModal do
  @moduledoc """
  LiveComponent that searches the PDF library for any page whose
  text matches one of the given item's translated names.

  Mount with `<.live_component module={PdfSearchModal} id=\"pdf-search-modal\"
  item={@item} show={@show_pdf_search} />`. The parent LV owns
  `:show_pdf_search` and toggles it on a button click; the modal
  closes by sending `{:pdf_search_modal_closed}` back to the parent
  via `send/2`.

  Each hit row links to `PdfDetailLive` with `?page=N` so PDF.js
  scrolls the embedded viewer to that page.

  ## Layout

  Results are grouped by PDF — every matching PDF gets a header row
  (filename + total match count, opens the detail page in a new tab)
  followed by a preview of the first @per_pdf hits. Per-PDF "Show N
  more matches" expands the group with another batch via
  `Catalogue.more_pdf_matches_for_item/3`.
  """

  use Phoenix.LiveComponent

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PdfLibrary
  alias PhoenixKitCatalogue.Paths

  @per_pdf 5
  @more_batch_size 50

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       groups: [],
       titles: [],
       trigram_query: nil,
       loading: false,
       expanding: MapSet.new(),
       error: nil,
       last_item_uuid: nil,
       per_pdf: @per_pdf
     )}
  end

  @impl true
  def update(%{item: item, show: show} = assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if show and socket.assigns.last_item_uuid != item.uuid do
        run_search(socket, item)
      else
        socket
      end

    {:ok, socket}
  end

  defp run_search(socket, item) do
    titles = PdfLibrary.item_titles(item)
    groups = Catalogue.search_pdfs_for_item(item, per_pdf: @per_pdf)

    # If the literal search returned [], the trigram fallback fired
    # internally — surface its query so per-PDF expand keeps the
    # same scoring shape. Detected by checking whether any hit's
    # score < 1.0 (literal hits are exactly 1.0).
    trigram_query =
      case groups do
        [%{hits: [%{score: score} | _]} | _] when score < 1.0 -> longest_title(titles)
        _ -> nil
      end

    assign(socket,
      groups: groups,
      titles: titles,
      trigram_query: trigram_query,
      loading: false,
      expanding: MapSet.new(),
      error: nil,
      last_item_uuid: item.uuid
    )
  rescue
    # Narrowed: only catch DB-side and known query errors. Anything
    # else (programmer error, missing module, etc.) re-raises so it
    # surfaces in telemetry instead of silently rendering as a UI
    # message that hides the bug.
    e in [
      DBConnection.ConnectionError,
      Postgrex.Error,
      Ecto.QueryError,
      Ecto.Query.CastError
    ] ->
      Logger.warning("PdfSearchModal.run_search/2 DB error: #{Exception.message(e)}")

      assign(socket,
        groups: [],
        titles: [],
        trigram_query: nil,
        loading: false,
        expanding: MapSet.new(),
        error:
          Gettext.gettext(
            PhoenixKitCatalogue.Gettext,
            "Search is temporarily unavailable. Please try again in a moment."
          ),
        last_item_uuid: item.uuid
      )
  end

  defp longest_title([]), do: nil
  defp longest_title(titles), do: Enum.max_by(titles, &String.length/1)

  @impl true
  def handle_event("close", _params, socket) do
    send(self(), {:pdf_search_modal_closed})
    {:noreply, socket}
  end

  def handle_event("show_more", %{"pdf_uuid" => pdf_uuid}, socket) do
    if MapSet.member?(socket.assigns.expanding, pdf_uuid) do
      {:noreply, socket}
    else
      socket = assign(socket, :expanding, MapSet.put(socket.assigns.expanding, pdf_uuid))

      try do
        group = Enum.find(socket.assigns.groups, &(&1.pdf.uuid == pdf_uuid))

        opts =
          [offset: length(group.hits), limit: @more_batch_size] ++
            trigram_opt(socket.assigns.trigram_query)

        more = Catalogue.more_pdf_matches_for_item(socket.assigns.item, pdf_uuid, opts)

        new_groups =
          Enum.map(socket.assigns.groups, fn g ->
            if g.pdf.uuid == pdf_uuid do
              %{g | hits: g.hits ++ more}
            else
              g
            end
          end)

        {:noreply,
         socket
         |> assign(:groups, new_groups)
         |> assign(:expanding, MapSet.delete(socket.assigns.expanding, pdf_uuid))}
      rescue
        e in [
          DBConnection.ConnectionError,
          Postgrex.Error,
          Ecto.QueryError,
          Ecto.Query.CastError
        ] ->
          Logger.warning("PdfSearchModal.show_more DB error: #{Exception.message(e)}")

          {:noreply,
           socket
           |> assign(:expanding, MapSet.delete(socket.assigns.expanding, pdf_uuid))
           |> assign(
             :error,
             Gettext.gettext(
               PhoenixKitCatalogue.Gettext,
               "Could not load more matches. Please try again."
             )
           )}
      end
    end
  end

  defp trigram_opt(nil), do: []
  defp trigram_opt(query), do: [trigram_query: query]

  # HTML-escape snippet, wrap any case-insensitive match of any title
  # in a <mark> tag. Returns a `Phoenix.HTML.safe` so the template's
  # interpolation renders the markup instead of escaping it.
  defp highlight_snippet(snippet, titles) when is_binary(snippet) and is_list(titles) do
    cleaned =
      titles
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.map(&Regex.escape/1)

    case cleaned do
      [] ->
        Phoenix.HTML.html_escape(snippet)

      escaped ->
        regex = Regex.compile!("(" <> Enum.join(escaped, "|") <> ")", "iu")

        snippet
        |> String.split(regex, include_captures: true)
        |> Enum.map_join(&render_highlight_segment(&1, regex))
        |> Phoenix.HTML.raw()
    end
  end

  defp highlight_snippet(_, _), do: Phoenix.HTML.raw("")

  defp render_highlight_segment(segment, regex) do
    escaped =
      segment
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()

    if Regex.match?(regex, segment) do
      ~s|<mark class="bg-warning/40 rounded px-0.5">| <> escaped <> "</mark>"
    else
      escaped
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <%= if @show do %>
        <div
          class="modal modal-open"
          role="dialog"
          aria-modal="true"
        >
          <div class="modal-box max-w-3xl">
            <div class="flex items-start justify-between gap-3">
              <div>
                <h3 class="font-semibold text-lg">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "PDF search")}
                </h3>
                <p class="text-xs text-base-content/60 mt-1">
                  {Gettext.gettext(
                    PhoenixKitCatalogue.Gettext,
                    "Searched for: %{name}",
                    name: @item.name
                  )}
                </p>
              </div>
              <button
                type="button"
                phx-click="close"
                phx-target={@myself}
                class="btn btn-sm btn-ghost btn-circle"
                aria-label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Close")}
              >
                ✕
              </button>
            </div>

            <div class="mt-4">
              <%= cond do %>
                <% @loading -> %>
                  <div class="flex items-center gap-2 text-sm text-base-content/60">
                    <span class="loading loading-spinner loading-sm"></span>
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Searching…")}
                  </div>
                <% @error -> %>
                  <div class="alert alert-error">
                    <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
                    <span>{@error}</span>
                  </div>
                <% @groups == [] -> %>
                  <div class="text-center py-8 text-base-content/60">
                    <.icon name="hero-magnifying-glass" class="w-10 h-10 mx-auto mb-2 opacity-50" />
                    <p class="text-sm">
                      {Gettext.gettext(
                        PhoenixKitCatalogue.Gettext,
                        "No PDF mentions this item by name."
                      )}
                    </p>
                  </div>
                <% true -> %>
                  <ul class="flex flex-col gap-4 max-h-[60vh] overflow-y-auto pr-1">
                    <%= for group <- @groups do %>
                      <li>
                        <a
                          href={Paths.pdf_detail(group.pdf.uuid)}
                          target="_blank"
                          rel="noopener"
                          class="flex items-center gap-1.5 font-medium text-sm link link-hover mb-2"
                        >
                          <.icon name="hero-document-text" class="w-4 h-4 text-base-content/60" />
                          {group.pdf.original_filename}
                          <.icon
                            name="hero-arrow-top-right-on-square"
                            class="w-3 h-3 text-base-content/40"
                          />
                          <span class="text-xs text-base-content/50 font-normal">
                            ({group.total_matches})
                          </span>
                        </a>
                        <ul class="flex flex-col gap-1 pl-5 border-l-2 border-base-200">
                          <%= for hit <- group.hits do %>
                            <li class="border border-base-200 rounded-lg px-3 py-2 hover:bg-base-200 transition-colors">
                              <a
                                href={Paths.pdf_detail(hit.pdf.uuid, hit.page_number)}
                                target="_blank"
                                rel="noopener"
                                class="flex flex-col gap-0.5"
                              >
                                <div class="text-xs text-base-content/60">
                                  {Gettext.gettext(
                                    PhoenixKitCatalogue.Gettext,
                                    "page %{n}",
                                    n: hit.page_number
                                  )}
                                </div>
                                <div class="text-xs text-base-content/70 italic line-clamp-2">
                                  …{highlight_snippet(hit.snippet, @titles)}…
                                </div>
                              </a>
                            </li>
                          <% end %>

                          <%= if length(group.hits) < group.total_matches do %>
                            <li class="pt-1">
                              <button
                                type="button"
                                phx-click="show_more"
                                phx-value-pdf_uuid={group.pdf.uuid}
                                phx-target={@myself}
                                disabled={MapSet.member?(@expanding, group.pdf.uuid)}
                                class="btn btn-ghost btn-xs"
                              >
                                <%= if MapSet.member?(@expanding, group.pdf.uuid) do %>
                                  <span class="loading loading-spinner loading-xs"></span>
                                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Loading…")}
                                <% else %>
                                  <.icon name="hero-chevron-down" class="w-3 h-3" />
                                  {Gettext.gettext(
                                    PhoenixKitCatalogue.Gettext,
                                    "Show %{n} more",
                                    n: group.total_matches - length(group.hits)
                                  )}
                                <% end %>
                              </button>
                            </li>
                          <% end %>
                        </ul>
                      </li>
                    <% end %>
                  </ul>
              <% end %>
            </div>

            <div class="modal-action">
              <button type="button" phx-click="close" phx-target={@myself} class="btn btn-sm">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Close")}
              </button>
            </div>
          </div>
          <button
            type="button"
            phx-click="close"
            phx-target={@myself}
            class="modal-backdrop"
            aria-label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Close modal")}
          >
          </button>
        </div>
      <% end %>
    </div>
    """
  end
end
