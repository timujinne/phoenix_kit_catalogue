defmodule PhoenixKitCatalogue.Catalogue.SupplierCommentsTest do
  @moduledoc """
  The per-row comment thread: minted once per item × supplier pair, carried
  across price revisions and removal, inherited on re-attach, never taken
  from attrs — and resolved back to the item's Suppliers tab for the
  central Comments admin.
  """

  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.ItemSupplierInfos
  alias PhoenixKitCatalogue.Catalogue.SupplierComments
  alias PhoenixKitCatalogue.Schemas.ItemSupplierInfo
  alias PhoenixKitCatalogue.Test.Repo, as: TestRepo

  @key "comment_thread_uuid"

  defp create_item(name \\ "Oak Panel") do
    {:ok, catalogue} =
      Catalogue.create_catalogue(%{name: "Cat #{System.unique_integer([:positive])}"})

    {:ok, item} = Catalogue.create_item(%{name: name, catalogue_uuid: catalogue.uuid})
    item
  end

  defp create_supplier(name \\ "Acme Metals") do
    {:ok, supplier} = Catalogue.create_supplier(%{name: name})
    supplier
  end

  defp attach(item, supplier, attrs \\ %{}) do
    {:ok, info} =
      ItemSupplierInfos.create(
        Map.merge(
          %{
            "item_uuid" => item.uuid,
            "supplier_uuid" => supplier.uuid,
            "supplier_source" => "local",
            "supplier_name_snapshot" => supplier.name,
            "unit_cost" => "10.00"
          },
          attrs
        )
      )

    info
  end

  # A row written before the key existed: strip it behind the context's back.
  defp make_legacy(%ItemSupplierInfo{} = info) do
    info
    |> Ecto.Changeset.change(metadata: Map.delete(info.metadata, @key))
    |> TestRepo.update!()
  end

  defp uuid?(value),
    do: is_binary(value) and byte_size(value) == 36 and match?({:ok, _}, Ecto.UUID.cast(value))

  describe "thread_uuid/1" do
    test "create/2 mints a textual uuid under the reserved key and thread_uuid/1 reads it" do
      info = attach(create_item(), create_supplier())

      assert uuid?(info.metadata[@key])
      assert SupplierComments.thread_uuid(info) == info.metadata[@key]
      refute SupplierComments.thread_uuid(info) == info.uuid
    end

    test "a row without the key — or with garbage under it — is its own thread" do
      uuid = UUIDv7.generate()

      for metadata <- [
            nil,
            %{},
            %{@key => nil},
            %{@key => ""},
            %{@key => "not-a-uuid"},
            %{@key => 42}
          ] do
        assert SupplierComments.thread_uuid(%{uuid: uuid, metadata: metadata}) == uuid
      end

      # Ecto.UUID.cast/1 accepts a 16-byte binary as a raw uuid; the key must
      # be the textual form, so this is garbage too.
      assert SupplierComments.thread_uuid(%{uuid: uuid, metadata: %{@key => "0123456789abcdef"}}) ==
               uuid
    end

    test "attrs cannot set or change the key on create or update" do
      item = create_item()
      supplier = create_supplier()
      foreign = UUIDv7.generate()

      info =
        attach(item, supplier, %{"metadata" => %{@key => foreign, "custom_fields" => %{"a" => 1}}})

      thread = SupplierComments.thread_uuid(info)

      refute thread == foreign
      assert info.metadata["custom_fields"] == %{"a" => 1}

      {:ok, updated} =
        ItemSupplierInfos.update(info, %{
          "metadata" => %{@key => foreign, "custom_fields" => %{"b" => 2}}
        })

      assert SupplierComments.thread_uuid(updated) == thread
      assert updated.metadata["custom_fields"] == %{"b" => 2}
    end

    test "a metadata replacement on update keeps the key (the custom-field save replaces the map)" do
      info = attach(create_item(), create_supplier())
      thread = SupplierComments.thread_uuid(info)

      {:ok, updated} =
        ItemSupplierInfos.update(info, %{"metadata" => %{"custom_fields" => %{"x" => "y"}}})

      assert updated.metadata[@key] == thread
      assert updated.metadata["custom_fields"] == %{"x" => "y"}
    end

    test "update pins a legacy row's own uuid as its key" do
      info = attach(create_item(), create_supplier()) |> make_legacy()
      refute Map.has_key?(info.metadata, @key)

      {:ok, updated} = ItemSupplierInfos.update(info, %{"supplier_sku" => "SKU-1"})

      assert updated.metadata[@key] == info.uuid
      assert SupplierComments.thread_uuid(updated) == info.uuid
    end
  end

  describe "the thread across the row's life" do
    test "a price revision carries the thread to the successor row" do
      info = attach(create_item(), create_supplier())
      thread = SupplierComments.thread_uuid(info)

      {:ok, successor} = ItemSupplierInfos.revise_unit_cost(info, Decimal.new("12.50"))

      refute successor.uuid == info.uuid
      assert SupplierComments.thread_uuid(successor) == thread

      {:ok, third} = ItemSupplierInfos.revise_unit_cost(successor, Decimal.new("13.00"))
      assert SupplierComments.thread_uuid(third) == thread
    end

    test "a legacy row's first revision pins its own uuid as the thread" do
      info = attach(create_item(), create_supplier()) |> make_legacy()

      {:ok, successor} = ItemSupplierInfos.revise_unit_cost(info, Decimal.new("12.50"))

      assert successor.metadata[@key] == info.uuid
      assert SupplierComments.thread_uuid(successor) == info.uuid
    end

    test "delete/2 closes the current row instead of deleting it, and keeps the thread" do
      item = create_item()
      info = attach(item, create_supplier())
      thread = SupplierComments.thread_uuid(info)

      assert {:ok, closed} = ItemSupplierInfos.delete(info)

      assert closed.uuid == info.uuid
      assert closed.valid_to == Date.utc_today()
      assert closed.is_primary == false
      assert SupplierComments.thread_uuid(closed) == thread

      # Gone from every "current" reader, kept in the pair's history.
      assert ItemSupplierInfos.list_for_item(item.uuid) == []
      assert is_nil(ItemSupplierInfos.primary_for_item(item.uuid))

      assert [%ItemSupplierInfo{uuid: uuid}] =
               ItemSupplierInfos.history_for_pair(item.uuid, info.supplier_uuid)

      assert uuid == info.uuid

      assert {:error, :not_current} = ItemSupplierInfos.delete(closed)
    end

    test "re-attaching a removed supplier resumes its thread — including a never-revised one" do
      item = create_item()
      supplier = create_supplier()

      first = attach(item, supplier)
      thread = SupplierComments.thread_uuid(first)
      {:ok, _} = ItemSupplierInfos.delete(first)

      second = attach(item, supplier)

      refute second.uuid == first.uuid
      assert SupplierComments.thread_uuid(second) == thread
    end

    test "re-attaching after a revision and a removal resumes the same thread" do
      item = create_item()
      supplier = create_supplier()

      first = attach(item, supplier)
      thread = SupplierComments.thread_uuid(first)
      {:ok, revised} = ItemSupplierInfos.revise_unit_cost(first, Decimal.new("11.00"))
      {:ok, _} = ItemSupplierInfos.delete(revised)

      third = attach(item, supplier)
      assert SupplierComments.thread_uuid(third) == thread
    end

    test "re-attaching a legacy pair resumes the closed row's own uuid" do
      item = create_item()
      supplier = create_supplier()

      first = attach(item, supplier) |> make_legacy()
      # Closing pins the key from the row's own uuid…
      {:ok, closed} = ItemSupplierInfos.delete(first)
      assert closed.metadata[@key] == first.uuid

      # …and a pair whose only history is an unkeyed closed row (written by
      # an older release) still resumes on that row's uuid.
      _ = make_legacy(closed)
      second = attach(item, supplier)
      assert SupplierComments.thread_uuid(second) == first.uuid
    end

    test "a different supplier on the same item, or the same supplier on another item, is another thread" do
      item = create_item()
      other_item = create_item("Pine Panel")
      supplier = create_supplier()
      other_supplier = create_supplier("Bolt & Co")

      threads =
        [attach(item, supplier), attach(item, other_supplier), attach(other_item, supplier)]
        |> Enum.map(&SupplierComments.thread_uuid/1)

      assert length(Enum.uniq(threads)) == 3
    end
  end

  describe "resolve_resources/1" do
    test "resolves a thread to the item's Suppliers tab, titled item — supplier" do
      item = create_item("Oak Panel")
      info = attach(item, create_supplier("Acme Metals"))
      thread = SupplierComments.thread_uuid(info)

      assert %{^thread => %{title: title, path: path}} =
               SupplierComments.resolve_resources([thread])

      assert title == "Oak Panel — Acme Metals"
      assert path == "/admin/catalogue/items/#{item.uuid}/edit?tab=sourcing"
      # RAW path: the comments module applies the URL prefix itself.
      refute path =~ "/phoenix_kit"
    end

    test "the same result through the host-facing handler" do
      info = attach(create_item(), create_supplier())
      thread = SupplierComments.thread_uuid(info)

      assert PhoenixKitCatalogue.resolve_comment_resources([thread]) ==
               SupplierComments.resolve_resources([thread])

      assert Map.has_key?(PhoenixKitCatalogue.resolve_comment_resources([thread]), thread)
    end

    test "prefers the current row when a thread matches both a closed and a current row" do
      item = create_item("Oak Panel")
      supplier = create_supplier("Acme Metals")
      first = attach(item, supplier) |> make_legacy()
      # Legacy: the thread IS the first row's uuid. Its revision carries the
      # key, so the thread now matches the closed row by uuid AND the
      # current row by key.
      {:ok, successor} = ItemSupplierInfos.revise_unit_cost(first, Decimal.new("11.00"))

      {:ok, _} =
        ItemSupplierInfos.update(successor, %{"supplier_name_snapshot" => "Acme Metals (current)"})

      assert %{title: "Oak Panel — Acme Metals (current)"} =
               SupplierComments.resolve_resources([first.uuid])[first.uuid]
    end

    test "a closed-only thread (removed supplier) still resolves, to its newest row" do
      item = create_item("Oak Panel")
      info = attach(item, create_supplier("Acme Metals"))
      thread = SupplierComments.thread_uuid(info)
      {:ok, _} = ItemSupplierInfos.delete(info)

      assert %{^thread => %{title: "Oak Panel — Acme Metals"}} =
               SupplierComments.resolve_resources([thread])
    end

    test "omits unknown uuids, ignores garbage, and returns keys only for what was asked" do
      info = attach(create_item(), create_supplier())
      thread = SupplierComments.thread_uuid(info)
      unknown = UUIDv7.generate()

      result = SupplierComments.resolve_resources([thread, unknown, "garbage", nil, 42, thread])

      assert Map.keys(result) == [thread]
      assert SupplierComments.resolve_resources([]) == %{}
      assert SupplierComments.resolve_resources(["garbage"]) == %{}
    end
  end

  test "the resolver is self-registered through the resource_links/0 callback" do
    assert PhoenixKitCatalogue.resource_links() == %{
             "catalogue_item_supplier" => PhoenixKitCatalogue
           }

    assert function_exported?(PhoenixKitCatalogue, :resolve_comment_resources, 1)
  end

  # Core's boot starts the module registry, which scans beams for
  # `@phoenix_kit_module` and then reads `resource_links/0` off every entry.
  # Nothing in this suite runs that boot, so the test starts the registry
  # itself and clears any host `:comment_resource_handlers` config: the
  # resolver has to arrive through the module's own callback alone.
  test "core's registry picks the resolver up without host config" do
    previous = Application.get_env(:phoenix_kit, :comment_resource_handlers)
    Application.put_env(:phoenix_kit, :comment_resource_handlers, %{})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :comment_resource_handlers, previous),
        else: Application.delete_env(:phoenix_kit, :comment_resource_handlers)
    end)

    start_supervised!(PhoenixKit.ModuleRegistry)

    assert PhoenixKitCatalogue in PhoenixKit.ModuleRegistry.all_modules()
    assert PhoenixKit.ResourceLinks.handlers()["catalogue_item_supplier"] == PhoenixKitCatalogue
  end

  test "the resource type is stable and shared by the LiveView and the resolver" do
    assert SupplierComments.resource_type() == "catalogue_item_supplier"
    assert Catalogue.supplier_comment_resource_type() == "catalogue_item_supplier"
    assert SupplierComments.thread_key() == @key
  end
end
