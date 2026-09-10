defmodule PhoenixKitCatalogue.Test.FakeExtension do
  @moduledoc """
  Minimal stand-in for a `PhoenixKitCatalogue.Extension` implementer,
  compiled only under `MIX_ENV=test` (see `elixirc_paths/1` in mix.exs).
  Exercises the extension slot end to end without depending on
  `phoenix_kit_ecommerce` — namespace `"fake"`, a single `"note"` field
  that `cast_item/2`/`cast_category/2` require to be a non-blank string.
  """

  use Phoenix.Component

  @behaviour PhoenixKitCatalogue.Extension

  @impl true
  def key, do: "fake"

  @impl true
  def enabled?, do: true

  @impl true
  def item_section(assigns), do: section(assigns, "item")

  @impl true
  def category_section(assigns), do: section(assigns, "category")

  @impl true
  def cast_item(params, current), do: cast(params, current)

  @impl true
  def cast_category(params, current), do: cast(params, current)

  # `id: "status"` deliberately collides with the catalogue's own
  # "status" column id — `PhoenixKitCatalogue.Extensions.columns/1` must
  # namespace it under `key/0` ("fake:status") before it ever reaches
  # `PhoenixKitCatalogue.Web.TableConfig`, so a naive implementation
  # that forgot to namespace would show up here as a collision.
  @impl true
  def item_columns, do: [%{id: "status", label: fn -> "Fake status" end, render: &column/1}]

  @impl true
  def category_columns, do: [%{id: "status", label: fn -> "Fake status" end, render: &column/1}]

  defp column(record) do
    assigns = %{record: record}

    ~H"""
    <%!-- `data-marker`, not `id`: the same column renders through this
         same `render/1` for BOTH the desktop table row and the mobile
         card's facts grid on one page load (CSS/JS picks which is
         visible, not the server) — an `id` scoped only by the record
         would duplicate across the two. `data-*` has no such
         uniqueness constraint. --%>
    <span data-marker={"ext-fake-status-#{@record.uuid}"}>fake-status</span>
    """
  end

  defp section(assigns, form_prefix) do
    note =
      assigns
      |> Map.get(:data, %{})
      |> Kernel.||(%{})
      |> Map.get("fake", %{})
      |> Map.get("note", "")

    assigns =
      assigns
      |> Map.new()
      |> Phoenix.Component.assign(:form_prefix, form_prefix)
      |> Phoenix.Component.assign(:note, note)
      |> Phoenix.Component.assign(:error, field_error(assigns[:form], :note))

    ~H"""
    <div id="ext-fake-section">
      <input type="text" name={"#{@form_prefix}[fake][note]"} value={@note} />
      <p :if={@error} class="text-error">{@error}</p>
    </div>
    """
  end

  # Reads an error `Ecto.Changeset.add_error/4`-tagged with
  # `extension: "fake", field: field` off the `:data` field's errors on a
  # `to_form/2`-built form. Mirrors how the LiveView is expected to
  # surface an extension's cast failure (see `PhoenixKitCatalogue.Extensions.absorb/3`).
  defp field_error(%{errors: errors}, field) when is_list(errors) do
    Enum.find_value(errors, fn
      {:data, {msg, opts}} ->
        if Keyword.get(opts, :extension) == "fake" and Keyword.get(opts, :field) == field,
          do: msg

      _ ->
        nil
    end)
  end

  defp field_error(_form, _field), do: nil

  defp cast(params, current) do
    case Map.get(params, "note") do
      note when is_binary(note) and note != "" -> {:ok, Map.put(current, "note", note)}
      _ -> {:error, [note: "can't be blank"]}
    end
  end
end

defmodule PhoenixKitCatalogue.Test.FakeModule do
  @moduledoc """
  Carries `catalogue_extensions/0` so `PhoenixKit.ModuleRegistry.register/1`
  has something to add to the registry in extension-slot tests, mirroring
  how `phoenix_kit_ecommerce` exposes `PhoenixKitEcommerce.catalogue_extensions/0`.
  Not a real `PhoenixKit.Module` — the registry only needs the one callback.
  """

  alias PhoenixKitCatalogue.Test.FakeExtension

  def catalogue_extensions, do: [FakeExtension]
end

defmodule PhoenixKitCatalogue.Test.BrokenColumnsExtension do
  @moduledoc """
  A `PhoenixKitCatalogue.Extension` implementer whose `item_columns/0`
  and `category_columns/0` raise — exercises
  `PhoenixKitCatalogue.Extensions.columns/1`'s resilience contract (a
  raising extension contributes nothing rather than crashing the
  Columns modal or the table render), the same way `contributed_by/1`
  already tolerates a raising `catalogue_extensions/0`.
  """

  @behaviour PhoenixKitCatalogue.Extension

  @impl true
  def key, do: "broken"

  @impl true
  def enabled?, do: true

  @impl true
  def item_columns, do: raise("boom")

  @impl true
  def category_columns, do: raise("boom")
end

defmodule PhoenixKitCatalogue.Test.BrokenColumnsModule do
  @moduledoc "Registry carrier for `BrokenColumnsExtension` (see `FakeModule`)."

  alias PhoenixKitCatalogue.Test.BrokenColumnsExtension

  def catalogue_extensions, do: [BrokenColumnsExtension]
end

defmodule PhoenixKitCatalogue.Test.HostileRenderExtension do
  @moduledoc """
  A `PhoenixKitCatalogue.Extension` implementer whose contributed
  columns are individually well-formed — `item_columns/0` /
  `category_columns/0` return valid entries, so
  `PhoenixKitCatalogue.Extensions.columns/1`'s DISCOVERY-time
  validation (`valid_column?/1`, the same check `BrokenColumnsExtension`
  above exercises by raising) lets every one of them through — but
  whose `label`/`render` misbehave once actually INVOKED against a row,
  in each of the ways a cell renderer can: raise, throw, exit, or
  return a value with no `Phoenix.HTML.Safe` representation. Discovery-
  time validation cannot see any of this; it only checks that `label`
  is a 0-arity fn and `render` a 1-arity fn, never calls them.

  `"ok"` is a normal, well-behaved sibling column — present so a test
  can assert the REST of a row (and the rest of the table) survives a
  neighbor column blowing up.
  """

  use Phoenix.Component

  @behaviour PhoenixKitCatalogue.Extension

  @impl true
  def key, do: "hostile"

  @impl true
  def enabled?, do: true

  @impl true
  def item_columns, do: columns()

  @impl true
  def category_columns, do: columns()

  defp columns do
    [
      %{
        id: "raises",
        label: fn -> "Raises" end,
        render: fn _record -> raise "cell render exploded" end
      },
      %{
        id: "throws",
        label: fn -> "Throws" end,
        render: fn _record -> throw(:cell_render_boom) end
      },
      %{
        id: "exits",
        label: fn -> "Exits" end,
        render: fn _record -> exit(:cell_render_boom) end
      },
      %{
        id: "unrenderable",
        label: fn -> "Unrenderable" end,
        # No `Phoenix.HTML.Safe` impl for a PID — the value itself is
        # the failure, not the call producing it.
        render: fn _record -> self() end
      },
      %{
        id: "label_raises",
        label: fn -> raise "label render exploded" end,
        render: &ok_cell/1
      },
      %{id: "ok", label: fn -> "OK" end, render: &ok_cell/1}
    ]
  end

  defp ok_cell(record) do
    assigns = %{record: record}

    ~H"""
    <%!-- `data-marker`, not `id` — see `FakeExtension.column/1`'s
         comment: this same render/1 runs for both the table row and
         the card facts grid on one page load. --%>
    <span data-marker={"ext-hostile-ok-#{@record.uuid}"}>hostile-ok</span>
    """
  end
end

defmodule PhoenixKitCatalogue.Test.HostileRenderModule do
  @moduledoc "Registry carrier for `HostileRenderExtension` (see `FakeModule`)."

  alias PhoenixKitCatalogue.Test.HostileRenderExtension

  def catalogue_extensions, do: [HostileRenderExtension]
end

defmodule PhoenixKitCatalogue.Test.BadIdExtension do
  @moduledoc """
  A well-formed `key/0` but a column `id` that itself carries the
  namespace delimiter (`"a:b"`) — exercises
  `PhoenixKitCatalogue.Extensions.valid_column?/1`'s guard against an
  ambiguous namespaced id: without it, key `"badid"` + id `"a:b"` and
  key `"badid:a"` + id `"b"` would both namespace to `"badid:a:b"`, so
  the composed string alone couldn't tell the two apart.
  """

  @behaviour PhoenixKitCatalogue.Extension

  @impl true
  def key, do: "badid"

  @impl true
  def enabled?, do: true

  @impl true
  def item_columns, do: [%{id: "a:b", label: fn -> "Ambiguous" end, render: fn _ -> "x" end}]

  @impl true
  def category_columns, do: item_columns()
end

defmodule PhoenixKitCatalogue.Test.BadKeyExtension do
  @moduledoc """
  A `key/0` that itself carries the namespace delimiter — every column
  it contributes must be dropped, since a key already containing the
  delimiter creates the same ambiguity `BadIdExtension` above tests for
  the id half.
  """

  @behaviour PhoenixKitCatalogue.Extension

  @impl true
  def key, do: "bad:key"

  @impl true
  def enabled?, do: true

  @impl true
  def item_columns, do: [%{id: "status", label: fn -> "Evil" end, render: fn _ -> "x" end}]

  @impl true
  def category_columns, do: item_columns()
end

defmodule PhoenixKitCatalogue.Test.DelimiterModule do
  @moduledoc "Registry carrier for `BadIdExtension` and `BadKeyExtension` (see `FakeModule`)."

  alias PhoenixKitCatalogue.Test.BadIdExtension
  alias PhoenixKitCatalogue.Test.BadKeyExtension

  def catalogue_extensions, do: [BadIdExtension, BadKeyExtension]
end
