defmodule PhoenixKitCatalogue.Web.FormLVBranchesExtrasTest do
  @moduledoc """
  Additional branch coverage for events the existing form LV tests
  haven't pinned: ItemFormLive metadata + cancel_upload paths,
  schemas.Catalogue validation edges.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatSchema

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "ItemFormLive — metadata + clear_featured_image branches" do
    setup do
      cat = fixture_catalogue(%{name: "ItemBranchCat"})
      item = fixture_item(%{name: "BranchTarget", catalogue_uuid: cat.uuid})
      %{item: item, catalogue: cat}
    end

    test "add_meta_field with unknown key is a no-op", %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogues/items/#{item.uuid}/edit")

      before = :sys.get_state(view.pid).socket.assigns.meta_state
      render_click(view, "add_meta_field", %{"key" => "definitely_not_a_real_key"})
      after_ = :sys.get_state(view.pid).socket.assigns.meta_state

      assert before == after_,
             "Expected unknown meta-field key to be a no-op; got #{inspect(after_)}"
    end

    test "add_meta_field + remove_meta_field round-trip on a known key",
         %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogues/items/#{item.uuid}/edit")

      # `color` is a known metadata definition for items.
      render_click(view, "add_meta_field", %{"key" => "color"})
      attached = :sys.get_state(view.pid).socket.assigns.meta_state.attached
      assert "color" in attached

      render_click(view, "remove_meta_field", %{"key" => "color"})
      attached = :sys.get_state(view.pid).socket.assigns.meta_state.attached
      refute "color" in attached
    end
  end

  describe "Schemas.Catalogue — validation edges" do
    test "valid changeset on minimal attrs" do
      cs = CatSchema.changeset(%CatSchema{}, %{name: "Plain"})
      assert cs.valid?
    end

    test "rejects status outside the allowed set" do
      cs = CatSchema.changeset(%CatSchema{}, %{name: "X", status: "bogus"})
      refute cs.valid?
      assert %{status: [_ | _]} = errors_on(cs)
    end

    test "rejects kind outside the allowed set" do
      cs = CatSchema.changeset(%CatSchema{}, %{name: "X", kind: "weird"})
      refute cs.valid?
      assert %{kind: [_ | _]} = errors_on(cs)
    end

    test "accepts kind: standard and kind: smart" do
      assert CatSchema.changeset(%CatSchema{}, %{name: "X", kind: "standard"}).valid?
      assert CatSchema.changeset(%CatSchema{}, %{name: "X", kind: "smart"}).valid?
    end

    test "rejects markup_percentage > 1000" do
      cs = CatSchema.changeset(%CatSchema{}, %{name: "X", markup_percentage: "1001"})
      refute cs.valid?
      assert %{markup_percentage: [_ | _]} = errors_on(cs)
    end

    test "rejects markup_percentage < 0" do
      cs = CatSchema.changeset(%CatSchema{}, %{name: "X", markup_percentage: "-1"})
      refute cs.valid?
      assert %{markup_percentage: [_ | _]} = errors_on(cs)
    end

    test "rejects discount_percentage > 100" do
      cs = CatSchema.changeset(%CatSchema{}, %{name: "X", discount_percentage: "101"})
      refute cs.valid?
      assert %{discount_percentage: [_ | _]} = errors_on(cs)
    end

    test "accepts boundary values (0 and 100/1000)" do
      assert CatSchema.changeset(%CatSchema{}, %{
               name: "X",
               markup_percentage: "0",
               discount_percentage: "0"
             }).valid?

      assert CatSchema.changeset(%CatSchema{}, %{
               name: "X",
               markup_percentage: "1000",
               discount_percentage: "100"
             }).valid?
    end

    test "rejects 256-char name" do
      long = String.duplicate("a", 256)
      cs = CatSchema.changeset(%CatSchema{}, %{name: long})
      refute cs.valid?
      assert %{name: [_ | _]} = errors_on(cs)
    end

    test "allowed_kinds/0 returns the canonical list" do
      assert CatSchema.allowed_kinds() == ~w(standard smart)
    end
  end

  describe "Catalogue.list_items_referencing_catalogue/1 — smart-rule lookup" do
    test "lists items whose smart rules point at the given catalogue" do
      ref_cat = fixture_catalogue(%{name: "Referenced", kind: "standard"})
      smart = fixture_catalogue(%{name: "SmartRef", kind: "smart"})

      {:ok, item} =
        Catalogue.create_item(%{
          name: "Smart Item",
          catalogue_uuid: smart.uuid,
          base_price: Decimal.new("10")
        })

      # Attach a rule that references the standard catalogue.
      {:ok, _rule} =
        Catalogue.create_catalogue_rule(%{
          item_uuid: item.uuid,
          referenced_catalogue_uuid: ref_cat.uuid,
          value: Decimal.new("1"),
          unit: "flat"
        })

      results = Catalogue.list_items_referencing_catalogue(ref_cat.uuid)
      assert Enum.any?(results, &(&1.uuid == item.uuid))
    end

    test "returns empty list when no items reference the catalogue" do
      orphan = fixture_catalogue(%{name: "Orphan"})
      assert Catalogue.list_items_referencing_catalogue(orphan.uuid) == []
    end
  end
end
