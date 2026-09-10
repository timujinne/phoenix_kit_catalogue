defmodule PhoenixKitCatalogue.ExtensionsTest do
  @moduledoc """
  Unit tests for the item/category form extension slot's discovery and
  absorption (Block 1, Task 4). Mutates the process-global
  `PhoenixKit.ModuleRegistry`, so `async: false` — see
  `PhoenixKitCatalogue.LiveCase`'s and `supplier_comments_test.exs`'s use of
  `start_supervised!(PhoenixKit.ModuleRegistry)` for the same pattern.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitCatalogue.Extensions
  alias PhoenixKitCatalogue.Test.BrokenColumnsModule
  alias PhoenixKitCatalogue.Test.DelimiterModule
  alias PhoenixKitCatalogue.Test.FakeExtension
  alias PhoenixKitCatalogue.Test.FakeModule
  alias PhoenixKitCatalogue.Test.HostileRenderModule

  setup do
    start_supervised!(PhoenixKit.ModuleRegistry)
    :ok
  end

  test "no registered module exports catalogue_extensions/0" do
    assert Extensions.all() == []
    assert Extensions.sections(:item) == []
    assert Extensions.sections(:category) == []
    assert Extensions.columns(:detail_items) == []
    assert Extensions.columns(:detail_categories) == []
  end

  describe "with FakeExtension registered" do
    setup do
      :ok = PhoenixKit.ModuleRegistry.register(FakeModule)

      # `start_supervised!`'s own teardown has already stopped the
      # registry GenServer by the time this callback runs (its process
      # death races ExUnit's on_exit queue, not LIFO with it), so
      # `unregister/1` — a `GenServer.call` — has nothing to reach.
      # `all_modules/0` reads `:persistent_term` directly with no such
      # requirement, so drop `FakeModule` from that same list the same
      # way: leaving it registered would survive this test (the
      # GenServer stopping does not clear `:persistent_term`) and make
      # every later test's item/category form render the "fake" section
      # and require its `note` field.
      on_exit(fn ->
        :persistent_term.put(
          {PhoenixKit, :registered_modules},
          List.delete(PhoenixKit.ModuleRegistry.all_modules(), FakeModule)
        )
      end)

      :ok
    end

    test "all/0 picks it up" do
      assert Extensions.all() == [FakeExtension]
    end

    test "sections/1 lists it for both :item and :category" do
      assert Extensions.sections(:item) == [FakeExtension]
      assert Extensions.sections(:category) == [FakeExtension]
    end

    test "columns/1 namespaces the contributed id under the extension's key" do
      [col] = Extensions.columns(:detail_items)
      assert col.id == "fake:status"
      assert col.label.() == "Fake status"
      assert is_function(col.render, 1)

      [cat_col] = Extensions.columns(:detail_categories)
      assert cat_col.id == "fake:status"
    end

    test "absorb/3 casts a valid submission under the extension's key" do
      assert Extensions.absorb(:item, %{"fake" => %{"note" => "hi"}}, %{}) ==
               {:ok, %{"fake" => %{"note" => "hi"}}}
    end

    test "absorb/3 returns the extension's cast error, tagged with the module" do
      assert Extensions.absorb(:item, %{"fake" => %{}}, %{}) ==
               {:error, {FakeExtension, [note: "can't be blank"]}}
    end

    test "absorb/3 treats a missing namespace key as an empty submission" do
      assert Extensions.absorb(:category, %{}, %{}) ==
               {:error, {FakeExtension, [note: "can't be blank"]}}
    end

    test "absorb/3 preserves sibling data keys and passes the extension's current value through" do
      assert Extensions.absorb(:item, %{"fake" => %{"note" => "hi"}}, %{
               "_name" => "x",
               "fake" => %{"note" => "old"}
             }) == {:ok, %{"_name" => "x", "fake" => %{"note" => "hi"}}}
    end
  end

  describe "with a registered module whose item_columns/0 raises" do
    setup do
      :ok = PhoenixKit.ModuleRegistry.register(BrokenColumnsModule)

      # Same cleanup as the FakeModule setup above — see its comment.
      on_exit(fn ->
        :persistent_term.put(
          {PhoenixKit, :registered_modules},
          List.delete(PhoenixKit.ModuleRegistry.all_modules(), BrokenColumnsModule)
        )
      end)

      :ok
    end

    test "columns/1 contributes nothing instead of crashing" do
      assert Extensions.columns(:detail_items) == []
      assert Extensions.columns(:detail_categories) == []
    end
  end

  describe "with HostileRenderExtension registered (per-row render/label failures)" do
    setup do
      :ok = PhoenixKit.ModuleRegistry.register(HostileRenderModule)

      # Same cleanup as the FakeModule setup above — see its comment.
      on_exit(fn ->
        :persistent_term.put(
          {PhoenixKit, :registered_modules},
          List.delete(PhoenixKit.ModuleRegistry.all_modules(), HostileRenderModule)
        )
      end)

      :ok
    end

    defp col(id) do
      Extensions.columns(:detail_items) |> Enum.find(&(&1.id == "hostile:" <> id))
    end

    test "discovery lets every column through — the shape check can't see what render/label do" do
      ids = Extensions.columns(:detail_items) |> Enum.map(& &1.id)

      assert "hostile:raises" in ids
      assert "hostile:throws" in ids
      assert "hostile:exits" in ids
      assert "hostile:unrenderable" in ids
      assert "hostile:label_raises" in ids
      assert "hostile:ok" in ids
    end

    test "a raising render/1 degrades to a safe fallback instead of crashing the caller" do
      log = capture_log(fn -> assert col("raises").render.(%{uuid: "x"}) == nil end)
      assert log =~ "hostile:raises"
      assert log =~ "cell render exploded"
    end

    test "a throwing render/1 degrades to a safe fallback instead of crashing the caller" do
      log = capture_log(fn -> assert col("throws").render.(%{uuid: "x"}) == nil end)
      assert log =~ "hostile:throws"
    end

    test "an exiting render/1 degrades to a safe fallback instead of crashing the caller" do
      log = capture_log(fn -> assert col("exits").render.(%{uuid: "x"}) == nil end)
      assert log =~ "hostile:exits"
    end

    test "a render/1 returning a non-HTML-safe value degrades to a safe fallback" do
      log = capture_log(fn -> assert col("unrenderable").render.(%{uuid: "x"}) == nil end)
      assert log =~ "hostile:unrenderable"
    end

    test "a raising label/0 degrades to a safe fallback instead of crashing the caller" do
      log = capture_log(fn -> assert col("label_raises").label.() == "" end)
      assert log =~ "hostile:label_raises"
      assert log =~ "label render exploded"
    end

    test "a well-behaved sibling column is unaffected" do
      assert col("ok").label.() == "OK"
      assert is_struct(col("ok").render.(%{uuid: "sibling-uuid"}), Phoenix.LiveView.Rendered)
    end

    test "logs once per column per Extensions.columns/1 call, not once per invocation" do
      render = col("raises").render

      log =
        capture_log(fn ->
          for _ <- 1..5, do: render.(%{uuid: "x"})
        end)

      assert Enum.count(String.split(log, "cell render exploded")) - 1 == 1
    end

    test "a fresh Extensions.columns/1 call (a new render pass) logs again" do
      capture_log(fn -> col("raises").render.(%{uuid: "x"}) end)

      log = capture_log(fn -> col("raises").render.(%{uuid: "x"}) end)
      assert log =~ "hostile:raises"
    end
  end

  describe "with DelimiterModule registered (namespace delimiter guard)" do
    setup do
      :ok = PhoenixKit.ModuleRegistry.register(DelimiterModule)

      on_exit(fn ->
        :persistent_term.put(
          {PhoenixKit, :registered_modules},
          List.delete(PhoenixKit.ModuleRegistry.all_modules(), DelimiterModule)
        )
      end)

      :ok
    end

    test "a column id carrying the delimiter is dropped, not namespaced ambiguously" do
      ids = Extensions.columns(:detail_items) |> Enum.map(& &1.id)
      refute "badid:a:b" in ids
    end

    test "a key carrying the delimiter drops every column that extension contributes" do
      ids = Extensions.columns(:detail_items) |> Enum.map(& &1.id)
      refute Enum.any?(ids, &String.starts_with?(&1, "bad:key"))
      assert ids == []
    end
  end
end
