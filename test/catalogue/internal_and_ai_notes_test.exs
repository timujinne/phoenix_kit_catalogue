defmodule PhoenixKitCatalogue.Catalogue.InternalAndAiNotesTest do
  @moduledoc """
  The context half of two V6 additions.

  `internal` keeps a category — with its subcategories and their items —
  out of the embeddable pop-ups: the fetch layer leaves them out only when
  asked (`exclude_internal: true` — the admin pages call the same
  functions and list everything), and `internal_category_uuids/0` is the
  hidden set.

  `ai_notes` is free text on catalogues, categories and items: kept by
  the changesets (within the length cap), logged as "changed" only,
  carried by duplication, and gathered for an item by
  `ai_notes_for_item/1`.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.BrowseState
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema
  alias PhoenixKitCatalogue.Schemas.{Category, Item}

  # One catalogue: an open category, an internal "Nails" category with a
  # subcategory under it, and an uncategorized item.
  setup do
    public = fixture_catalogue(%{name: "Showroom"})
    open_category = fixture_category(public, %{name: "Shared bracket shelf"})
    nails = fixture_category(public, %{name: "Shared bracket nails", internal: true})
    boxes = fixture_category(public, %{name: "Shared bracket boxes", parent_uuid: nails.uuid})

    open_item =
      fixture_item(%{
        name: "Shared bracket open",
        catalogue_uuid: public.uuid,
        category_uuid: open_category.uuid
      })

    nail =
      fixture_item(%{
        name: "Shared bracket nail",
        catalogue_uuid: public.uuid,
        category_uuid: nails.uuid
      })

    boxed =
      fixture_item(%{
        name: "Shared bracket boxed",
        catalogue_uuid: public.uuid,
        category_uuid: boxes.uuid
      })

    loose = fixture_item(%{name: "Shared bracket loose", catalogue_uuid: public.uuid})

    %{
      public: public,
      open_category: open_category,
      nails: nails,
      boxes: boxes,
      open_item: open_item,
      nail: nail,
      boxed: boxed,
      loose: loose
    }
  end

  describe "the internal flag" do
    test "is off unless set, and the changeset keeps it", %{open_category: open, nails: nails} do
      refute open.internal
      assert nails.internal

      {:ok, updated} = Catalogue.update_category(open, %{internal: true})
      assert updated.internal
    end

    test "an explicit nil is refused rather than reaching the NOT NULL column" do
      changeset =
        Category.changeset(%Category{}, %{
          name: "X",
          catalogue_uuid: Ecto.UUID.generate(),
          internal: nil
        })

      assert %{internal: [_]} = errors_on(changeset)
    end

    test "catalogues no longer carry it" do
      refute Map.has_key?(%CatalogueSchema{}, :internal)
    end

    test "the hidden set is the internal categories and everything under them", ctx do
      assert Enum.sort(Catalogue.internal_category_uuids()) ==
               Enum.sort([ctx.nails.uuid, ctx.boxes.uuid])
    end

    test "search leaves internal items out only when asked, uncategorized ones never", ctx do
      names = &(Enum.map(&1, fn item -> item.name end) |> Enum.sort())

      assert names.(Catalogue.search_items("bracket", catalogue_uuids: [ctx.public.uuid])) ==
               [
                 "Shared bracket boxed",
                 "Shared bracket loose",
                 "Shared bracket nail",
                 "Shared bracket open"
               ]

      # Named in the scope and still left out: the scope cannot widen past it.
      assert names.(
               Catalogue.search_items("bracket",
                 category_uuids: [ctx.nails.uuid],
                 exclude_internal: true
               )
             ) == []

      assert names.(Catalogue.search_items("bracket", exclude_internal: true)) ==
               ["Shared bracket loose", "Shared bracket open"]
    end

    test "the count agrees with the list it counts", ctx do
      for opts <- [
            [],
            [exclude_internal: true],
            [catalogue_uuids: [ctx.public.uuid], exclude_internal: true]
          ] do
        assert Catalogue.count_search_items("bracket", opts) ==
                 length(Catalogue.search_items("bracket", opts)),
               inspect(opts)
      end
    end

    test "category search leaves internal categories and their subtree out when asked", ctx do
      all = Enum.map(Catalogue.search_categories(ctx.public.uuid, "bracket"), & &1.name)
      assert "Shared bracket nails" in all and "Shared bracket boxes" in all

      assert [%Category{name: "Shared bracket shelf"}] =
               Catalogue.search_categories(ctx.public.uuid, "bracket", exclude_internal: true)
    end

    test "the browse state carries the rule into every fetch" do
      state = BrowseState.init(scope: %{catalogue_uuids: ["a", "b"], exclude_internal: true})
      {_state, {:fetch, opts, _gen}} = BrowseState.command(state, :reset)
      assert opts[:exclude_internal] == true

      {_state, {:fetch, opts, _gen}} = BrowseState.command(state, {:search, "x"})
      assert opts[:exclude_internal] == true
    end

    test "a change to it is in the activity log as from/to", %{open_category: open} do
      {:ok, _} = Catalogue.update_category(open, %{internal: true})

      assert_activity_logged("category.updated",
        resource_uuid: open.uuid,
        metadata_has: %{"changes" => %{"internal" => %{"from" => "false", "to" => "true"}}}
      )
    end

    test "duplicating a category keeps it", %{nails: nails} do
      {:ok, %{category: copy}} = Catalogue.duplicate_category(nails)
      assert copy.internal
    end
  end

  describe "notes for AI" do
    test "each level keeps its notes", %{public: public} do
      {:ok, catalogue} = Catalogue.update_catalogue(public, %{ai_notes: "Prices exclude VAT."})
      category = fixture_category(public, %{ai_notes: "Sheet goods."})
      item = fixture_item(%{catalogue_uuid: public.uuid, ai_notes: "Sold by the sheet."})

      assert catalogue.ai_notes == "Prices exclude VAT."
      assert category.ai_notes == "Sheet goods."
      assert item.ai_notes == "Sold by the sheet."
    end

    test "the length cap holds on all three changesets" do
      long = String.duplicate("x", 10_001)
      fits = String.duplicate("x", 10_000)

      for {schema, attrs} <- [
            {CatalogueSchema, %{name: "C"}},
            {Category, %{name: "K", catalogue_uuid: Ecto.UUID.generate()}},
            {Item, %{name: "I", catalogue_uuid: Ecto.UUID.generate()}}
          ] do
        assert %{ai_notes: [_]} =
                 errors_on(schema.changeset(struct(schema), Map.put(attrs, :ai_notes, long)))

        refute Map.has_key?(
                 errors_on(schema.changeset(struct(schema), Map.put(attrs, :ai_notes, fits))),
                 :ai_notes
               )
      end
    end

    test "the activity log records that they changed, never the text", %{open_item: item} do
      {:ok, _} = Catalogue.update_item(item, %{ai_notes: "Secret pricing rule"})

      assert_activity_logged("item.updated",
        resource_uuid: item.uuid,
        metadata_has: %{"changes" => %{"ai_notes" => %{"changed" => true}}}
      )

      refute_activity_logged("item.updated",
        resource_uuid: item.uuid,
        metadata_has: %{"changes" => %{"ai_notes" => %{"to" => "Secret pricing rule"}}}
      )
    end

    test "duplication carries them on every level", %{public: public} do
      {:ok, public} = Catalogue.update_catalogue(public, %{ai_notes: "Catalogue note"})
      category = fixture_category(public, %{ai_notes: "Category note"})

      fixture_item(%{
        catalogue_uuid: public.uuid,
        category_uuid: category.uuid,
        name: "Noted",
        ai_notes: "Item note"
      })

      {:ok, %{catalogue: copy}} = Catalogue.duplicate_catalogue(public)
      assert copy.ai_notes == "Catalogue note"

      [copied_category] =
        Repo.all(
          from(c in Category,
            where: c.catalogue_uuid == ^copy.uuid and c.ai_notes == "Category note"
          )
        )

      assert copied_category.ai_notes == "Category note"

      [copied_item] =
        Repo.all(from(i in Item, where: i.catalogue_uuid == ^copy.uuid and i.name == "Noted"))

      assert copied_item.ai_notes == "Item note"
    end

    test "ai_notes_for_item gathers the catalogue's, the categories' and the item's, general first",
         %{public: public} do
      {:ok, public} = Catalogue.update_catalogue(public, %{ai_notes: "  Catalogue note  "})
      root = fixture_category(public, %{name: "Root", ai_notes: "Root note"})
      silent = fixture_category(public, %{name: "Silent", parent_uuid: root.uuid})

      item =
        fixture_item(%{
          catalogue_uuid: public.uuid,
          category_uuid: silent.uuid,
          name: "Deep item",
          ai_notes: "Item note"
        })

      assert [
               %{level: :catalogue, name: "Showroom", notes: "Catalogue note"},
               %{level: :category, name: "Root", notes: "Root note"},
               %{level: :item, name: "Deep item", notes: "Item note"}
             ] = Catalogue.ai_notes_for_item(item)
    end

    test "an item with no notes anywhere gathers nothing", %{open_item: item} do
      assert Catalogue.ai_notes_for_item(item) == []
    end
  end
end
