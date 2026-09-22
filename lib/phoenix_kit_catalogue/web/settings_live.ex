defmodule PhoenixKitCatalogue.Web.SettingsLive do
  @moduledoc """
  Settings → Catalogue.

  The module had no settings page at all, so everything it stores was either
  unreachable (the whole AI-translation sweep, four keys whose only writer was
  an operator calling `update_*` from a console) or lived on whichever list
  page happened to write it. The owner noticed the gap from the other end —
  `/admin/settings` simply had no Catalogue entry (boss via Max, 2026-09-21).

  Every key the module owns that a person can meaningfully change is here;
  `PhoenixKitCatalogue.Web.Settings` is where they are read and written.

  Two things deliberately NOT here:

  * **The module kill switch** (`catalogue_enabled`) — Admin → Modules owns
    it, and a copy of it on this page would be a switch that hides the page
    it lives on, since the tab is gated on the module's permission.
  * **The per-scope list sort** (`catalogue_sort_*`) — the sort selector on
    each list writes it, which is the place a person is standing when they
    decide what "sorted" means. A second control here would disagree with it.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitCatalogue.Gettext

  import PhoenixKitWeb.Components.Core.Checkbox, only: [checkbox: 1]
  import PhoenixKitWeb.Components.Core.FormSection, only: [form_section: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Web.Settings

  # Same opt-out as the module's other pages: PhoenixKit auto-applies its admin
  # chrome to external module views, and this one self-wraps so its title and
  # subtitle reach the global admin header.
  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, gettext("Catalogue")) |> load_settings()}
  end

  # Read straight through on every load rather than caching in assigns: these
  # are read once per page view, and a stale toggle here is a lie about what
  # the box is doing.
  defp load_settings(socket) do
    enabled_langs = Multilang.enabled_languages() -- [Multilang.primary_language()]

    assign(socket,
      context_menu_enabled: Settings.context_menu_enabled?(),
      seo_fields_visible: Settings.seo_fields_visible?(),
      sweep_enabled: Settings.sweep_enabled?(),
      sweep_interval: Settings.sweep_interval_minutes(),
      sweep_max_per_run: Settings.sweep_max_per_run(),
      sweep_langs: Settings.sweep_langs(),
      available_langs: enabled_langs
    )
  end

  # ── Events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("toggle_context_menu", params, socket) do
    {:noreply, save(socket, &Settings.update_context_menu_enabled/1, checked?(params))}
  end

  def handle_event("toggle_seo_fields", params, socket) do
    {:noreply, save(socket, &Settings.update_seo_fields_visible/1, checked?(params))}
  end

  def handle_event("toggle_sweep", params, socket) do
    {:noreply, save(socket, &Settings.update_sweep_enabled/1, checked?(params))}
  end

  def handle_event("save_sweep_interval", %{"value" => value}, socket) do
    case positive_integer(value) do
      {:ok, minutes} ->
        {:noreply, save(socket, &Settings.update_sweep_interval_minutes/1, minutes)}

      :error ->
        {:noreply, put_flash(socket, :error, gettext("Enter a whole number of minutes above 0."))}
    end
  end

  def handle_event("save_sweep_max_per_run", %{"value" => value}, socket) do
    case positive_integer(value) do
      {:ok, n} ->
        {:noreply, save(socket, &Settings.update_sweep_max_per_run/1, n)}

      :error ->
        {:noreply, put_flash(socket, :error, gettext("Enter a whole number above 0."))}
    end
  end

  def handle_event("save_sweep_langs", params, socket) do
    picked = picked_langs(params, socket.assigns.available_langs)
    {:noreply, save(socket, &Settings.update_sweep_langs/1, picked)}
  end

  @doc """
  The languages a posted checkbox group names, kept to the ones on offer.

  An unticked group posts nothing at all, so an absent `"langs"` key means
  "none" — not "unchanged". A code that is not an enabled language is
  dropped, so a crafted post cannot store a language the sweep would then
  target. Public for its tests: the LiveView only offers this group when a
  second language is enabled, which a test database may not have.
  """
  @spec picked_langs(map(), [String.t()]) :: [String.t()]
  def picked_langs(params, available) do
    params
    |> Map.get("langs", [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 in available))
    |> Enum.uniq()
  end

  # A checkbox posts its hidden "false" companion when unticked, so the value
  # is always present and always a string.
  defp checked?(%{"value" => v}), do: v == "true"
  defp checked?(_), do: false

  defp positive_integer(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp save(socket, fun, value) do
    case fun.(value) do
      {:ok, _} ->
        socket |> load_settings() |> put_flash(:info, gettext("Saved."))

      {:error, _reason} ->
        # Reload anyway: the screen must show what the box actually holds, not
        # the value the user just failed to write.
        socket |> load_settings() |> put_flash(:error, gettext("Could not save that."))
    end
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={gettext("Catalogue")}
      page_section={gettext("Settings")}
      page_section_path={Routes.path("/admin/settings")}
      current_path={assigns[:url_path] || Routes.path("/admin/settings/catalogue")}
      current_locale={assigns[:current_locale]}
    >
      <div class="flex flex-col w-full max-w-3xl mx-auto px-4 py-6 gap-6">
        <.form_section
          title={gettext("Lists")}
          icon="hero-list-bullet"
          body_class="space-y-4"
        >
          <:subtitle>
            {gettext("How the catalogue's admin lists behave.")}
          </:subtitle>

          <form phx-change="toggle_context_menu" id="catalogue-context-menu-form">
            <.checkbox
              variant="toggle"
              id="catalogue-context-menu"
              name="value"
              checked={@context_menu_enabled}
              label={gettext("Right-click a row for its actions")}
            >
              <:description>
                {gettext(
                  "Right-clicking anywhere on a row opens the same menu its ⋮ button does, at the pointer. Turn this off to leave the browser's own menu — copy, open in a new tab, inspect — in place everywhere."
                )}
              </:description>
            </.checkbox>
          </form>
        </.form_section>

        <.form_section
          title={gettext("Item form")}
          icon="hero-pencil-square"
          body_class="space-y-4"
        >
          <form phx-change="toggle_seo_fields" id="catalogue-seo-fields-form">
            <.checkbox
              variant="toggle"
              id="catalogue-seo-fields"
              name="value"
              checked={@seo_fields_visible}
              label={gettext("Show the URL slug and SEO fields")}
            >
              <:description>
                {gettext(
                  "Off hides them from the item form; what they already hold is kept and saved unchanged, and comes back when you turn this on."
                )}
              </:description>
            </.checkbox>
          </form>
        </.form_section>

        <.form_section
          title={gettext("AI translation sweep")}
          icon="hero-language"
          body_class="space-y-4"
        >
          <%!-- Whole sentences only, the link one of them: a sentence split
               around a link cannot be translated into a language that puts
               the linked noun somewhere else. --%>
          <:subtitle>
            {gettext("Translates catalogue content in the background, on a timer.")}
            <.link navigate={Paths.translations()} class="link link-primary">
              {gettext("See what is missing, or translate on demand.")}
            </.link>
          </:subtitle>

          <form phx-change="toggle_sweep" id="catalogue-sweep-form">
            <.checkbox
              variant="toggle"
              id="catalogue-sweep-enabled"
              name="value"
              checked={@sweep_enabled}
              label={gettext("Run the sweep automatically")}
            >
              <:description>
                {gettext(
                  "Off by default. Turning it on starts the schedule immediately; each tick enqueues translation jobs for whatever is still missing."
                )}
              </:description>
            </.checkbox>
          </form>

          <%!-- The numbers stay editable while the sweep is off: an operator
               sets the pace first and then turns it on, not the other way
               round. --%>
          <div class="grid gap-4 sm:grid-cols-2">
            <form phx-change="save_sweep_interval" id="catalogue-sweep-interval-form">
              <.input
                type="number"
                name="value"
                id="catalogue-sweep-interval"
                value={@sweep_interval}
                min="1"
                step="1"
                phx-debounce="600"
                label={gettext("Minutes between runs")}
              />
            </form>

            <form phx-change="save_sweep_max_per_run" id="catalogue-sweep-max-form">
              <.input
                type="number"
                name="value"
                id="catalogue-sweep-max"
                value={@sweep_max_per_run}
                min="1"
                step="1"
                phx-debounce="600"
                label={gettext("Most jobs per run")}
              />
            </form>
          </div>

          <div>
            <p class="text-sm font-medium mb-2">{gettext("Languages to translate into")}</p>

            <p :if={@available_langs == []} class="text-sm text-base-content/60">
              {gettext("Only the primary language is enabled, so there is nothing to sweep.")}
              <.link navigate={Routes.path("/admin/settings/languages")} class="link link-primary">
                {gettext("Enable more languages.")}
              </.link>
            </p>

            <form
              :if={@available_langs != []}
              phx-change="save_sweep_langs"
              id="catalogue-sweep-langs-form"
              class="flex flex-wrap gap-x-6 gap-y-2"
            >
              <.checkbox
                :for={lang <- @available_langs}
                id={"catalogue-sweep-lang-#{lang}"}
                name="langs[]"
                checked={lang in @sweep_langs}
                label={lang}
              />
            </form>

            <p :if={@available_langs != []} class="text-xs text-base-content/50 mt-2">
              {gettext(
                "A language turned off under Languages stops receiving sweep jobs whether or not it is ticked here."
              )}
            </p>
          </div>
        </.form_section>

        <%!-- Named rather than left out: a settings page that silently omits
             a switch reads as a missing feature, which is how this page came
             to be asked for in the first place. --%>
        <div class="text-sm text-base-content/60 flex flex-wrap items-center gap-x-2 gap-y-1">
          <.icon name="hero-information-circle" class="w-4 h-4 shrink-0" />
          <.link navigate={Routes.path("/admin/modules")} class="link link-primary">
            {gettext("Turn the whole module on or off under Modules.")}
          </.link>
          <span>{gettext("Each list's sort is set from the list itself.")}</span>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
