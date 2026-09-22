defmodule PhoenixKitCatalogue.Web.Components.PlacePicker do
  @moduledoc """
  A searchable, collapsible tree for picking a place — a folder, a
  catalogue or a category — instead of a flat list (the owner, via Max,
  2026-09-21: "no flat lists anywhere, only proper pickers"). It looks and
  behaves like the item form's Location picker.

  **Controlled.** The parent owns what is picked: it passes `value` and
  handles `{PlacePicker, id, value}`, sent whenever the admin picks (a
  single id, or the new list with `multiple`). The component owns only the
  search text and which rows are open. The parent also builds the `tree`
  (`Web.PlaceTree`), so the scope and what to leave out — a category's own
  subtree, the folder being moved — are its call, and it must check a
  received id against live data before acting on it: the tree may be
  minutes old.

  ## Attributes

    * `id` (required)
    * `tree` (required) — `PlaceTree` nodes
    * `value` — the picked id (`nil` for none), or a list with `multiple`
    * `pickable` — the row types that can be picked (default catalogues
      and categories); other rows only open and close
    * `multiple` — check any number of rows; a folder row then carries a
      box that checks or clears every pickable row under it
    * `current` — the id to badge "Current" (where the record is now)
    * `field` — `true` shows the picked place's path and a Change button,
      the tree only while changing (for forms); `false` (default) shows the
      tree at once (for dialogs). Single pickers only: a multiple one has
      no single path to show
    * `path_skip` — row types left out of the shown path (default folders)
    * `placeholder` — the path text while nothing is picked
    * `name` — renders hidden inputs so a surrounding form posts the value;
      `post: :uuid` (default) posts the bare uuid, `""` for `"root"`, and
      `post: :id` the typed id

  **Inside a form.** The search box has no `name`, and its hook keeps its
  `input`/`change` events and Enter from reaching the surrounding form —
  typing here must not run the form's `phx-change` or submit it. Every
  other control is a `type="button"`.
  """
  use Phoenix.LiveComponent

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKitCatalogue.Web.PlaceTree

  @default_pickable [:catalogue, :category]

  @impl true
  def mount(socket) do
    {:ok, assign(socket, query: "", open: MapSet.new(), search_open: MapSet.new(), panel?: false)}
  end

  @impl true
  def update(assigns, socket) do
    first? = not Map.has_key?(socket.assigns, :tree)

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:value, fn -> nil end)
      |> assign_new(:pickable, fn -> @default_pickable end)
      |> assign_new(:multiple, fn -> false end)
      |> assign_new(:current, fn -> nil end)
      |> assign_new(:field, fn -> false end)
      |> assign_new(:path_skip, fn -> [:folder] end)
      |> assign_new(:placeholder, fn -> "—" end)
      |> assign_new(:name, fn -> nil end)
      |> assign_new(:post, fn -> :uuid end)

    socket = if first?, do: assign(socket, :open, opened_at(socket.assigns)), else: socket

    {:ok, refilter(socket)}
  end

  # The rows above what is picked (or where the record is now) start open,
  # so the admin sees it in place; so does the current row itself, whose
  # children are the likeliest destination, and a root row, which only
  # holds the rest of the tree.
  defp opened_at(assigns) do
    ids = List.wrap(assigns.value) ++ List.wrap(assigns.current)
    roots = for %{type: :root, id: id} <- assigns.tree, do: id

    MapSet.new(
      roots ++
        List.wrap(assigns.current) ++
        Enum.flat_map(ids, &PlaceTree.ancestor_ids(assigns.tree, &1))
    )
  end

  defp refilter(socket) do
    {shown, open} = PlaceTree.filter(socket.assigns.tree, socket.assigns.query)
    assign(socket, shown: shown, search_open: MapSet.new(open))
  end

  @impl true
  def handle_event("search", %{"value" => value}, socket) when is_binary(value) do
    {:noreply, socket |> assign(:query, value) |> refilter()}
  end

  def handle_event("toggle", %{"id" => id}, socket) when is_binary(id) do
    key = if searching?(socket.assigns), do: :search_open, else: :open
    set = Map.fetch!(socket.assigns, key)

    set = if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)

    {:noreply, assign(socket, key, set)}
  end

  # Only a row the tree offers, of a pickable type, is taken.
  def handle_event("pick", %{"id" => id}, socket) when is_binary(id) do
    %{tree: tree, pickable: pickable} = socket.assigns

    if PlaceTree.member?(tree, id, pickable) do
      value =
        if socket.assigns.multiple, do: toggle(List.wrap(socket.assigns.value), [id]), else: id

      send(self(), {__MODULE__, socket.assigns.id, value})
      {:noreply, assign(socket, :panel?, false)}
    else
      {:noreply, socket}
    end
  end

  # A folder's box: every pickable row under it, checked when any is not,
  # else cleared. The whole branch counts — rows a search hides too.
  def handle_event("pick_all", %{"id" => id}, %{assigns: %{multiple: true}} = socket)
      when is_binary(id) do
    %{tree: tree, pickable: pickable} = socket.assigns

    case PlaceTree.find(tree, id) do
      %{children: children} ->
        under = PlaceTree.ids_of(children, pickable)
        value = List.wrap(socket.assigns.value)

        value =
          if Enum.all?(under, &(&1 in value)),
            do: value -- under,
            else: Enum.uniq(value ++ under)

        send(self(), {__MODULE__, socket.assigns.id, value})
        {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("open_panel", _params, socket), do: {:noreply, assign(socket, :panel?, true)}
  def handle_event("close_panel", _params, socket), do: {:noreply, assign(socket, :panel?, false)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp toggle(value, [id]), do: if(id in value, do: List.delete(value, id), else: value ++ [id])

  defp searching?(assigns), do: String.trim(assigns.query) != ""

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        shown_open: if(searching?(assigns), do: assigns.search_open, else: assigns.open),
        tree_visible?: not assigns.field or assigns.panel?,
        path: path(assigns)
      )

    ~H"""
    <div id={@id} class="flex flex-col gap-2 min-w-0" data-place-picker>
      <input
        :for={value <- posted(@value, @post)}
        :if={@name}
        type="hidden"
        name={@name}
        value={value}
      />

      <div :if={@field} class="flex flex-wrap items-center gap-2">
        <.path_line id={"#{@id}-path"} names={@path} placeholder={@placeholder} />
        <button
          :if={not @panel?}
          type="button"
          id={"#{@id}-change"}
          phx-click="open_panel"
          phx-target={@myself}
          class="btn btn-outline btn-sm ml-auto"
        >
          <.icon name="hero-folder-open" class="w-4 h-4" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Change")}
        </button>
        <button
          :if={@panel?}
          type="button"
          phx-click="close_panel"
          phx-target={@myself}
          class="btn btn-ghost btn-sm ml-auto"
        >
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}
        </button>
      </div>

      <div
        :if={@tree_visible?}
        class={["flex flex-col gap-2", @field && "rounded-box border border-base-300 p-2"]}
      >
        <label class="input input-sm w-full">
          <.icon name="hero-magnifying-glass" class="w-4 h-4 opacity-50" />
          <input
            id={"#{@id}-search"}
            type="text"
            value={@query}
            phx-hook=".PlacePickerSearch"
            phx-target={@myself}
            placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search…")}
            aria-label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search…")}
            autocomplete="off"
            class="grow"
          />
        </label>

        <div class="max-h-72 overflow-y-auto">
          <p :if={@shown == []} class="px-2 py-3 text-sm text-base-content/50">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No matches.")}
          </p>
          <ul :if={@shown != []} id={"#{@id}-tree"} role="tree" class="text-sm">
            <.place_row
              :for={node <- @shown}
              node={node}
              open={@shown_open}
              value={@value}
              current={@current}
              pickable={@pickable}
              multiple={@multiple}
              tree={@tree}
              myself={@myself}
            />
          </ul>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".PlacePickerSearch">
        // The query goes to the component from here, not through a form's
        // phx-change: the picker often sits inside a host form, whose own
        // phx-change and submit must not see what is typed here.
        export default {
          mounted() {
            this._onInput = (e) => {
              e.stopPropagation()
              if (!e.isComposing) this.queue()
            }
            this._onChange = (e) => e.stopPropagation()
            this._onKey = (e) => {
              if (e.key === "Enter") {
                e.preventDefault()
                e.stopPropagation()
                this.push()
              }
            }
            this._onComposed = () => this.queue()
            this.el.addEventListener("input", this._onInput)
            this.el.addEventListener("change", this._onChange)
            this.el.addEventListener("keydown", this._onKey)
            this.el.addEventListener("compositionend", this._onComposed)
          },
          queue() {
            clearTimeout(this._timer)
            this._timer = setTimeout(() => this.push(), 200)
          },
          push() {
            clearTimeout(this._timer)
            this.pushEventTo(this.el, "search", {value: this.el.value})
          },
          destroyed() {
            clearTimeout(this._timer)
          }
        }
      </script>
    </div>
    """
  end

  defp path(%{value: value} = assigns) when is_binary(value),
    do: PlaceTree.path_in(assigns.tree, value, assigns.path_skip)

  defp path(_assigns), do: []

  # A single picker always posts its field (blank while nothing is picked);
  # a multiple one posts one per picked row.
  defp posted(value, post) when is_list(value), do: Enum.map(value, &post_value(&1, post))
  defp posted(nil, _post), do: [""]
  defp posted(value, post), do: [post_value(value, post)]

  defp post_value(id, :id), do: id
  defp post_value(id, :uuid), do: PlaceTree.uuid(id) || ""

  attr(:id, :string, required: true)
  attr(:names, :list, required: true)
  attr(:placeholder, :string, required: true)

  defp path_line(assigns) do
    ~H"""
    <nav id={@id} class="min-w-0">
      <span :if={@names == []} class="text-sm text-base-content/50">{@placeholder}</span>
      <ol :if={@names != []} class="flex flex-wrap items-center gap-1 text-sm">
        <li :for={{name, index} <- Enum.with_index(@names)} class="flex items-center gap-1">
          <.icon :if={index > 0} name="hero-chevron-right-mini" class="w-4 h-4 text-base-content/30" />
          <span class={if index == length(@names) - 1, do: "font-medium", else: "text-base-content/70"}>
            {name}
          </span>
        </li>
      </ol>
    </nav>
    """
  end

  attr(:node, :map, required: true)
  attr(:open, :any, required: true)
  attr(:value, :any, required: true)
  attr(:current, :string, default: nil)
  attr(:pickable, :list, required: true)
  attr(:multiple, :boolean, required: true)
  attr(:tree, :list, required: true)
  attr(:myself, :any, required: true)

  defp place_row(assigns) do
    node = assigns.node
    picked = List.wrap(assigns.value)

    assigns =
      assign(assigns,
        expanded?: MapSet.member?(assigns.open, node.id),
        branch?: node.children != [],
        pickable?: node.type in assigns.pickable,
        selected?: node.id in picked,
        branch_check: branch_check(assigns, picked)
      )

    ~H"""
    <li
      role="treeitem"
      aria-expanded={@branch? && to_string(@expanded?)}
      aria-selected={to_string(@selected?)}
    >
      <div class={[
        "flex items-center gap-1 rounded-field pr-2 hover:bg-base-200",
        @selected? and not @multiple && "bg-primary/10"
      ]}>
        <button
          :if={@branch?}
          type="button"
          phx-click="toggle"
          phx-value-id={@node.id}
          phx-target={@myself}
          class="btn btn-ghost btn-xs btn-square shrink-0"
          aria-label={
            if @expanded?,
              do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Collapse"),
              else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Expand")
          }
        >
          <.icon
            name={if @expanded?, do: "hero-chevron-down-mini", else: "hero-chevron-right-mini"}
            class="w-4 h-4"
          />
        </button>
        <span :if={not @branch?} class="w-6 shrink-0"></span>
        <button
          :if={@multiple and not @pickable? and @branch_check != nil}
          type="button"
          phx-click="pick_all"
          phx-value-id={@node.id}
          phx-target={@myself}
          data-pick-all={@node.id}
          class="shrink-0"
          aria-label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select all")}
        >
          <.check_box state={@branch_check} />
        </button>
        <button
          type="button"
          phx-click={if @pickable?, do: "pick", else: "toggle"}
          phx-value-id={@node.id}
          phx-target={@myself}
          data-place={@node.id}
          class={[
            "flex flex-1 items-center gap-2 py-1.5 text-left min-w-0",
            not @pickable? && "text-base-content/70"
          ]}
        >
          <.check_box :if={@multiple and @pickable?} state={if @selected?, do: :all, else: :none} />
          <.icon name={type_icon(@node.type)} class="w-4 h-4 shrink-0 text-base-content/50" />
          <span class="truncate">{@node.name}</span>
          <span :if={@node[:hint]} class="text-xs text-base-content/50 shrink-0">{@node.hint}</span>
          <span :if={@node.archived?} class="badge badge-xs badge-ghost">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Archived")}
          </span>
          <span :if={@node.id == @current} class="badge badge-xs badge-outline ml-auto shrink-0">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Current")}
          </span>
        </button>
      </div>
      <ul :if={@branch? and @expanded?} role="group" class="ml-3 pl-2 border-l border-base-content/10">
        <.place_row
          :for={child <- @node.children}
          node={child}
          open={@open}
          value={@value}
          current={@current}
          pickable={@pickable}
          multiple={@multiple}
          tree={@tree}
          myself={@myself}
        />
      </ul>
    </li>
    """
  end

  # A folder's box in multiple mode: :all / :some / :none of the pickable
  # rows under it (in the whole tree, not only what a search shows), or
  # nil when there are none.
  defp branch_check(%{multiple: true, node: node} = assigns, picked) do
    if node.type in assigns.pickable do
      nil
    else
      full = PlaceTree.find(assigns.tree, node.id) || node
      check_state(PlaceTree.ids_of(full.children, assigns.pickable), picked)
    end
  end

  defp branch_check(_assigns, _picked), do: nil

  defp check_state([], _picked), do: nil

  defp check_state(under, picked) do
    case Enum.count(under, &(&1 in picked)) do
      0 -> :none
      count when count == length(under) -> :all
      _ -> :some
    end
  end

  attr(:state, :atom, required: true)

  defp check_box(assigns) do
    ~H"""
    <span
      data-check={@state}
      aria-hidden="true"
      class={[
        "inline-flex w-4 h-4 shrink-0 items-center justify-center rounded-sm border",
        if(@state == :none,
          do: "border-base-content/30",
          else: "border-primary bg-primary text-primary-content"
        )
      ]}
    >
      <.icon :if={@state == :all} name="hero-check-mini" class="w-3.5 h-3.5" />
      <.icon :if={@state == :some} name="hero-minus-mini" class="w-3.5 h-3.5" />
    </span>
    """
  end

  defp type_icon(:root), do: "hero-home"
  defp type_icon(:folder), do: "hero-folder"
  defp type_icon(:catalogue), do: "hero-book-open"
  defp type_icon(:category), do: "hero-rectangle-stack"
end
