defmodule PhoenixKitCatalogue.API.ToolsConformanceTest do
  @moduledoc """
  The catalogue's tool declarations against the shop API tool table
  and against the contract with core: valid structs, closed schemas that use
  only the keywords core's validator implements, and no way to write a shop
  price, markup, discount or raw `data` through a catalogue tool.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.API.MCP.Names
  alias PhoenixKit.API.Tool
  alias PhoenixKit.API.ToolLint
  alias PhoenixKit.API.Validator
  alias PhoenixKitCatalogue.API.Gate
  alias PhoenixKitCatalogue.API.Tools
  alias PhoenixKitCatalogue.Test.ApiCase

  # name => {scope, read_only?, max_items}
  @table %{
    "catalogue.list_products" => {"catalogue.products:read", true, nil},
    "catalogue.get_products" => {"catalogue.products:read", true, 50},
    "catalogue.create_products" => {"catalogue.products:write", false, 500},
    "catalogue.update_products" => {"catalogue.products:write", false, 500},
    "catalogue.set_translations" => {"catalogue.products:write", false, 500},
    "catalogue.delete_products" => {"catalogue.products:delete", false, 500},
    "catalogue.list_categories" => {"catalogue.categories:read", true, nil},
    "catalogue.upsert_categories" => {"catalogue.categories:write", false, 500},
    "catalogue.delete_categories" => {"catalogue.categories:delete", false, 500}
  }

  @validator_keywords ~w(type enum required properties additionalProperties minimum maximum
                         minLength maxLength pattern minItems maxItems items)
  @forbidden_properties ~w(base_price markup_percentage discount_percentage data cost_per_item
                           price compare_at_price price_modifiers)

  test "exactly the nine tools, in the documented order" do
    assert Enum.map(Tools.all(), & &1.name) == [
             "catalogue.list_products",
             "catalogue.get_products",
             "catalogue.create_products",
             "catalogue.update_products",
             "catalogue.set_translations",
             "catalogue.delete_products",
             "catalogue.list_categories",
             "catalogue.upsert_categories",
             "catalogue.delete_categories"
           ]
  end

  test "every tool is a valid admin tool of the catalogue permission" do
    for tool <- Tools.all() do
      assert {:ok, _} = Tool.validate(tool), "#{tool.name} is not valid"
      assert tool.audience == :admin
      assert tool.permission == "catalogue"
      assert is_binary(tool.title) and tool.title != ""
      assert is_binary(tool.description) and String.length(tool.description) > 80
      assert is_map(tool.output_schema)
    end
  end

  test "scopes, read-only annotations and batch caps match the table" do
    for tool <- Tools.all() do
      {scope, read_only?, max_items} = Map.fetch!(@table, tool.name)

      assert tool.scope == scope, "#{tool.name}: scope"
      assert tool.annotations.read_only == read_only?, "#{tool.name}: read_only"
      assert tool.max_items == max_items, "#{tool.name}: max_items"
    end

    scopes = Tools.all() |> Enum.map(& &1.scope) |> Enum.uniq() |> Enum.sort()

    assert scopes ==
             ~w(catalogue.categories:delete catalogue.categories:read catalogue.categories:write
                catalogue.products:delete catalogue.products:read catalogue.products:write)
  end

  test "only the two delete tools are dangerous and destructive" do
    for tool <- Tools.all() do
      if tool.name in ["catalogue.delete_products", "catalogue.delete_categories"] do
        assert tool.danger == :always
        assert tool.annotations.destructive
      else
        assert tool.danger == nil,
               "#{tool.name} must not declare danger (core applies the batch threshold)"

        refute tool.annotations.destructive, "#{tool.name}"
      end
    end
  end

  test "every handler is exported as call/2" do
    for tool <- Tools.all() do
      {module, function} = tool.handler
      assert Code.ensure_loaded?(module), "#{inspect(module)} is not loaded"

      assert function_exported?(module, function, 2),
             "#{tool.name}: #{inspect(module)}.#{function}/2"
    end
  end

  test "every object in every input schema is closed" do
    for tool <- Tools.all(), {path, node} <- objects(tool.input_schema, tool.name) do
      case node["additionalProperties"] do
        false ->
          :ok

        %{} = schema ->
          assert closed_or_scalar?(schema), "#{path}: additionalProperties is an open schema"

        other ->
          flunk("#{path}: additionalProperties is #{inspect(other)}")
      end
    end
  end

  test "schemas use only the keywords core's validator implements" do
    for tool <- Tools.all(), {path, keyword} <- keywords(tool.input_schema, tool.name) do
      assert keyword in @validator_keywords, "#{path}: #{keyword} is ignored by the validator"
    end
  end

  test "no catalogue tool can write a price, markup, discount or raw data" do
    for tool <- Tools.all(), {path, name} <- property_names(tool.input_schema, tool.name) do
      refute name in @forbidden_properties, "#{path} declares #{name}"
    end
  end

  test "the input of a write tool refuses a forbidden field wherever it is put" do
    ref = %{"id" => Ecto.UUID.generate()}

    payloads = %{
      "catalogue.create_products" => &%{"items" => [%{"name" => "N", "sku" => "S", &1 => 1}]},
      "catalogue.update_products" => &%{"items" => [%{"ref" => ref, "changes" => %{&1 => 1}}]},
      "catalogue.set_translations" =>
        &%{"items" => [%{"ref" => ref, "translations" => %{"de-DE" => %{&1 => 1}}}]},
      "catalogue.upsert_categories" =>
        &%{"items" => [%{"external_id" => "C", "name" => "N", &1 => 1}]}
    }

    for {name, build} <- payloads,
        field <- ~w(base_price markup_percentage discount_percentage data) do
      tool = Enum.find(Tools.all(), &(&1.name == name))
      schema = Validator.close_schema(tool.input_schema, %{})

      assert {:error, errors} = Validator.validate(schema, build.(field)),
             "#{name} accepted #{field}"

      assert Enum.any?(errors, &String.ends_with?(&1.path, field)),
             "#{name}/#{field}: #{inspect(errors)}"
    end
  end

  test "api_tools/0 hands core the same tools when the core has the gate, and withholds the delete tools when not" do
    # The stand and the forks pin core by git or path, so the gate is detected on the loaded code
    # (`API.Gate`), not on a version.
    assert Gate.available?(),
           "the core under test lacks the confirmation gate"

    assert Enum.map(PhoenixKitCatalogue.api_tools(), & &1.name) ==
             Enum.map(Tools.all(), & &1.name)

    names = fn gate? -> Enum.map(PhoenixKitCatalogue.API.tools(gate?), & &1.name) end
    assert names.(true) == Enum.map(Tools.all(), & &1.name)

    assert names.(false) ==
             Enum.map(Tools.all(), & &1.name) --
               ["catalogue.delete_products", "catalogue.delete_categories"]
  end

  # The MCP layer (ToolLint, MCP names) may be absent from the core under test; a missing piece
  # shows up as a skipped test with the reason, never as a silent pass.
  if Code.ensure_loaded?(ToolLint) do
    test "ToolLint finds nothing wrong with the tools, and no two MCP names collide" do
      assert :ok = ToolLint.check_tools(Tools.all())
    end
  else
    @tag skip: "core without the MCP layer: PhoenixKit.API.ToolLint is not there"
    test "ToolLint finds nothing wrong with the tools, and no two MCP names collide" do
      flunk("skipped")
    end
  end

  if Code.ensure_loaded?(Names) do
    test "every tool is reachable by its MCP name and answers there exactly as under its dotted name" do
      for tool <- Tools.all() do
        mcp = Names.to_mcp(tool.name)

        refute String.contains?(mcp, "."), "#{tool.name}: the MCP name keeps a dot"

        assert mcp =~ ~r/^[a-zA-Z0-9_-]{1,64}$/,
               "#{tool.name}: #{mcp} is not a legal MCP tool name"

        # An undeclared field fails validation of every closed schema before any handler runs, so
        # this needs no database; the same schema answers under both names.
        input = %{"undeclared_field" => 1}
        assert {:error, :validation_failed, _, %{errors: [_ | _]}} = ApiCase.call(mcp, input)
        assert ApiCase.call(mcp, input) == ApiCase.call(tool.name, input)
      end
    end
  else
    @tag skip: "core without the MCP layer: PhoenixKit.API.MCP.Names is not there"
    test "every tool is reachable by its MCP name and answers there exactly as under its dotted name" do
      flunk("skipped")
    end
  end

  # --- schema walkers ----------------------------------------------------------------

  # Every node that declares `properties`, with a readable path.
  defp objects(schema, path) when is_map(schema) do
    own = if Map.has_key?(schema, "properties"), do: [{path, schema}], else: []

    children =
      Enum.flat_map(Map.get(schema, "properties", %{}), fn {name, child} ->
        objects(child, path <> "." <> name)
      end) ++
        objects_in(schema["items"], path <> "[]") ++
        objects_in(schema["additionalProperties"], path <> ".*")

    own ++ children
  end

  defp objects(_other, _path), do: []
  defp objects_in(%{} = schema, path), do: objects(schema, path)
  defp objects_in(_other, _path), do: []

  # Every keyword used at a schema node (property NAMES are not keywords).
  defp keywords(schema, path) when is_map(schema) do
    own = for key <- Map.keys(schema), do: {path, key}

    children =
      Enum.flat_map(Map.get(schema, "properties", %{}), fn {name, child} ->
        keywords(child, path <> "." <> name)
      end) ++
        keywords_in(schema["items"], path <> "[]") ++
        keywords_in(schema["additionalProperties"], path <> ".*")

    own ++ children
  end

  defp keywords(_other, _path), do: []
  defp keywords_in(%{} = schema, path), do: keywords(schema, path)
  defp keywords_in(_other, _path), do: []

  defp property_names(schema, path) when is_map(schema) do
    own = for name <- Map.keys(Map.get(schema, "properties", %{})), do: {path, name}

    children =
      Enum.flat_map(Map.get(schema, "properties", %{}), fn {name, child} ->
        property_names(child, path <> "." <> name)
      end) ++
        names_in(schema["items"], path <> "[]") ++
        names_in(schema["additionalProperties"], path <> ".*")

    own ++ children
  end

  defp property_names(_other, _path), do: []
  defp names_in(%{} = schema, path), do: property_names(schema, path)
  defp names_in(_other, _path), do: []

  # An `additionalProperties` schema must itself be a closed object (a map of
  # language => fields) or a scalar type.
  defp closed_or_scalar?(%{"type" => "object"} = schema),
    do: schema["additionalProperties"] == false

  defp closed_or_scalar?(%{"type" => type}) when is_binary(type), do: true
  defp closed_or_scalar?(_schema), do: false
end
