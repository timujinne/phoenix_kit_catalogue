defmodule PhoenixKitCatalogue.BrowseSortVocabularyConformanceTest do
  @moduledoc """
  Three lists name the module's shared item sort, and they must stay one
  list:

    * `TableConfig.columns(:detail_items)`'s `sortable?` ids — the only
      values `ViewConfig.load_global_sort/1` will read back out of the
      `catalogue_sort_detail_items` setting, so the only values
      `Browse.global_items_order/0` can return.
    * `BrowseState.order_fields/0` — what `BrowseState.init/1` accepts;
      it RAISES on anything else, and the embed
      (`CatalogueBrowse.update/2`) and the popup
      (`ItemSelectorModal.update/2`) both feed it `global_items_order/0`
      at init.
    * `Search.apply_search_order/2`'s clauses — what the fetch layer has
      an `ORDER BY` for; since 2026-09-12 it raises on anything else too.

  Make a `:detail_items` column sortable without the matching fetch
  clause and an admin who picks it in the sort selector takes down the
  embed and the popup on OPEN, everywhere in the host, for every user.
  `global_items_order/0` clamps as a backstop; this test is what keeps
  the clamp from ever being the thing that fires.
  """

  use ExUnit.Case, async: true

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitCatalogue.Catalogue.BrowseState
  alias PhoenixKitCatalogue.Catalogue.Search
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Web.TableConfig

  # The three bindings `search_items_base/2` establishes, built without a
  # database: an ORDER BY clause that references a binding or a column
  # that is not there fails right here, at query-build time.
  defp base_query do
    from(i in Item,
      left_join: cat in assoc(i, :catalogue),
      left_join: c in assoc(i, :category)
    )
  end

  test "Search has an ORDER BY for every field in the vocabulary, in both directions" do
    for field <- BrowseState.order_fields(), dir <- [:asc, :desc] do
      assert %Ecto.Query{order_bys: [_ | _]} =
               Search.apply_search_order(base_query(), {field, dir})
    end

    assert %Ecto.Query{order_bys: [_ | _]} = Search.apply_search_order(base_query(), :position)
    assert_raise ArgumentError, fn -> Search.apply_search_order(base_query(), {:bogus, :asc}) end
  end

  test "every sortable :detail_items column is in the browse vocabulary" do
    sortable =
      :detail_items
      |> TableConfig.columns()
      |> Enum.filter(& &1.sortable?)
      |> Enum.map(& &1.id)

    # Sanity: the list is not empty (a refactor that renamed `sortable?`
    # would otherwise make this test vacuously pass).
    assert "position" in sortable
    assert "name" in sortable

    assert Enum.sort(sortable) ==
             BrowseState.order_fields() |> Enum.map(&to_string/1) |> Enum.sort()
  end

  test "BrowseState.init/1 accepts every field in its own vocabulary" do
    for field <- BrowseState.order_fields(), dir <- [:asc, :desc] do
      assert %BrowseState{order: {^field, ^dir}} = BrowseState.init(order: {field, dir})
    end
  end

  test "the default :detail_items sort is Manual, and Manual is in the vocabulary" do
    assert {"position", :asc} = TableConfig.default_sort(:detail_items)
    assert :position in BrowseState.order_fields()
  end
end
