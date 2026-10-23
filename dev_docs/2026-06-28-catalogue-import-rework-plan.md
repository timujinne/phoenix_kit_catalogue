# Catalogue Import Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make catalogue import symmetric with export — a Source registry, a PRO100 update-by-id import with diff preview + report, round-trip of PRO100 service columns, and Universal JSON import.

**Architecture:** New `Import.Source` behaviour/registry mirrors `Export.Destination`. Pure modules (`Pro100Parser`, `Matcher`, `Pro100Plan`) carry the testable core; `Web.ImportLive` branches between the existing `:mapping` flow (Universal) and a new `:sync` flow (PRO100). Round-trip data lives in the existing `item.data["pro100"]` JSONB — no new tables.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto, ExUnit, NimbleCSV, XlsxReader, Decimal.

## Global Constraints

- Module is a live path dep; compile/verify via `cd <host-app> && mix compile` (standalone `mix compile` fails on a stale deps tree).
- `mix format` + `mix quality` must pass before each commit.
- Commit per task directly to `main` (no feature branches). No AI attribution in commit messages.
- No new DB tables/columns/migrations — everything goes in `item.data` (JSONB).
- Existing PRO100 export byte-output for items **never imported from PRO100** must stay byte-identical (existing `pro100_test.exs` must pass unchanged).
- Digits-only id normalization must be identical to today's export rule: `String.replace(sku, ~r/\D/, "")`.
- Reference spec: `dev_docs/2026-06-28-catalogue-import-rework-design.md`.

---

## File Structure

Create:
- `lib/phoenix_kit_catalogue/pro100/id.ex` — `PhoenixKitCatalogue.Pro100.Id` (shared `digits_only/1`)
- `lib/phoenix_kit_catalogue/import/pro100_parser.ex` — fixed-layout text parser
- `lib/phoenix_kit_catalogue/import/matcher.ex` — digits-id resolver within a catalogue
- `lib/phoenix_kit_catalogue/import/pro100_plan.ex` — diff/report builder
- `lib/phoenix_kit_catalogue/import/source.ex` — behaviour
- `lib/phoenix_kit_catalogue/import/source/universal.ex`
- `lib/phoenix_kit_catalogue/import/source/pro100.ex`
- Tests mirroring each under `test/phoenix_kit_catalogue/import/...`
- Fixtures: `test/support/fixtures/pro100/furniture_8.txt`, `materials_3.txt`

Modify:
- `lib/phoenix_kit_catalogue/export/pro100.ex` — read `data["pro100"]` with constant fallback; delegate id to `Pro100.Id`
- `lib/phoenix_kit_catalogue/import.ex` (context) — `sources/0`, `source_by_key/1`, `analyze/2`
- `lib/phoenix_kit_catalogue/import/mapper.ex` — `m → running_meter` alias; `resolve_pro100_unit/1`
- `lib/phoenix_kit_catalogue/web/import_live.ex` — Source/Format selects, `:mapping` vs `:sync` branch, preview + report steps

---

## Task 1: Shared `Pro100.Id.digits_only/1`

Extract the digits-only rule into one neutral module used by both export and import, so matching and export can never drift.

**Files:**
- Create: `lib/phoenix_kit_catalogue/pro100/id.ex`
- Test: `test/phoenix_kit_catalogue/pro100/id_test.exs`
- Modify: `lib/phoenix_kit_catalogue/export/pro100.ex` (delegate `pro100_id/1`)

**Interfaces:**
- Produces: `PhoenixKitCatalogue.Pro100.Id.digits_only(sku :: String.t() | nil) :: String.t()`

- [ ] **Step 1: Write the failing test**

```elixir
# test/phoenix_kit_catalogue/pro100/id_test.exs
defmodule PhoenixKitCatalogue.Pro100.IdTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Pro100.Id

  test "keeps digits only" do
    assert Id.digits_only("76.0026.12") == "76002612"
    assert Id.digits_only("C-01") == "01"
  end

  test "nil and no-digit collapse to empty string" do
    assert Id.digits_only(nil) == ""
    assert Id.digits_only("abc") == ""
  end
end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `cd <host-app> && mix test ../phoenix_kit_catalogue/test/phoenix_kit_catalogue/pro100/id_test.exs`
Expected: FAIL (module `PhoenixKitCatalogue.Pro100.Id` undefined). If the path form is awkward, run from the catalogue dir per project convention; the host app compile path is what matters.

- [ ] **Step 3: Implement**

```elixir
# lib/phoenix_kit_catalogue/pro100/id.ex
defmodule PhoenixKitCatalogue.Pro100.Id do
  @moduledoc """
  PRO100 numeric id: the SKU reduced to digits only (`"76.0026.12"` ->
  `"76002612"`). Shared by the PRO100 export (id column) and import (match key)
  so the two never drift. `nil`/no-digit -> `""`.
  """
  @spec digits_only(String.t() | nil) :: String.t()
  def digits_only(nil), do: ""
  def digits_only(sku) when is_binary(sku), do: String.replace(sku, ~r/\D/, "")
end
```

- [ ] **Step 4: Delegate export to it (no behavior change)**

In `lib/phoenix_kit_catalogue/export/pro100.ex` replace the `pro100_id/1` body:

```elixir
  alias PhoenixKitCatalogue.Pro100.Id

  @doc false
  def pro100_id(sku), do: Id.digits_only(sku)
```

- [ ] **Step 5: Run tests, verify pass (incl. unchanged export tests)**

Run: `cd <host-app> && mix test ../phoenix_kit_catalogue/test/phoenix_kit_catalogue/pro100/id_test.exs ../phoenix_kit_catalogue/test/phoenix_kit_catalogue/export/pro100_test.exs`
Expected: PASS (export byte tests unchanged).

- [ ] **Step 6: `mix format` + commit**

```bash
cd /www/phoenix_kit_catalogue
mix format
git add lib/phoenix_kit_catalogue/pro100/id.ex lib/phoenix_kit_catalogue/export/pro100.ex test/phoenix_kit_catalogue/pro100/id_test.exs
git commit -m "Extract PRO100 digits-only id into shared Pro100.Id"
```

---

## Task 2: `Import.Pro100Parser`

Pure parser for the fixed-layout `# Parts` / `# Materials` text formats.

**Files:**
- Create: `lib/phoenix_kit_catalogue/import/pro100_parser.ex`
- Test: `test/phoenix_kit_catalogue/import/pro100_parser_test.exs`
- Fixtures: copy the real reference files
  - `cp "<host-app>/.claude/tmp/export_examples/Furniture 8.txt" test/support/fixtures/pro100/furniture_8.txt`
  - `cp "<host-app>/.claude/tmp/export_examples/Materials 3.txt" test/support/fixtures/pro100/materials_3.txt`

**Interfaces:**
- Consumes: `Pro100.Id.digits_only/1`, `Import.Mapper.normalize_price/1`
- Produces: `Pro100Parser.parse(binary :: binary(), format :: :furniture | :materials) :: {:ok, [row]} | {:error, term()}` where
  `row = %{line_no: pos_integer(), raw_line: String.t(), id: String.t(), name: String.t(), base_price: Decimal.t() | nil, unit: String.t() | nil, service: %{String.t() => String.t()}, format: :furniture | :materials}`

- [ ] **Step 1: Write failing tests (use the real fixtures)**

```elixir
# test/phoenix_kit_catalogue/import/pro100_parser_test.exs
defmodule PhoenixKitCatalogue.Import.Pro100ParserTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Import.Pro100Parser

  defp fixture(name),
    do: File.read!(Path.join([__DIR__, "..", "..", "support", "fixtures", "pro100", name]))

  test "parses furniture rows, stripping BOM and the two leading tabs" do
    {:ok, rows} = Pro100Parser.parse(fixture("furniture_8.txt"), :furniture)
    assert length(rows) == 3
    [first | _] = rows
    assert first.name == "Second 1 furniture 222"
    assert first.id == "1111"
    assert Decimal.equal?(first.base_price, Decimal.new("2222.00"))
    assert first.service == %{"c3" => "0", "c5" => "1.0", "c6" => "222.00", "c7" => "1.0"}
    assert first.format == :furniture
    assert first.raw_line =~ "Second 1 furniture 222"
  end

  test "furniture preserves varying service columns (c6 empty, c7 = 2.0)" do
    {:ok, rows} = Pro100Parser.parse(fixture("furniture_8.txt"), :furniture)
    third = Enum.at(rows, 2)
    assert third.name == "Third 3 furniture 333"
    assert third.service == %{"c3" => "0", "c5" => "1.0", "c6" => "", "c7" => "2.0"}
  end

  test "parses materials rows with unit in c6" do
    {:ok, rows} = Pro100Parser.parse(fixture("materials_3.txt"), :materials)
    assert length(rows) == 4
    [first | _] = rows
    assert first.unit == "pc"
    assert first.service == %{"c3" => "0", "c5" => "1.0"}
    third = Enum.at(rows, 2)
    assert third.name == "sdfsdfsadf"
    assert third.id == "1111111111"
    assert third.unit == "m³"
  end

  test "rejects a header that does not match the requested format" do
    assert {:error, :bad_header} =
             Pro100Parser.parse(fixture("furniture_8.txt"), :materials)
  end

  test "errors on empty input" do
    assert {:error, :empty} = Pro100Parser.parse("", :furniture)
  end
end
```

- [ ] **Step 2: Run, verify fail**

Run: `cd <host-app> && mix test ../phoenix_kit_catalogue/test/phoenix_kit_catalogue/import/pro100_parser_test.exs`
Expected: FAIL (module undefined). First create the fixtures dir + copy the two files (Step 3 includes it).

- [ ] **Step 3: Create fixtures + implement parser**

```bash
mkdir -p test/support/fixtures/pro100
cp "<host-app>/.claude/tmp/export_examples/Furniture 8.txt" test/support/fixtures/pro100/furniture_8.txt
cp "<host-app>/.claude/tmp/export_examples/Materials 3.txt" test/support/fixtures/pro100/materials_3.txt
```

```elixir
# lib/phoenix_kit_catalogue/import/pro100_parser.ex
defmodule PhoenixKitCatalogue.Import.Pro100Parser do
  @moduledoc """
  Parses the PRO100 fixed-layout text formats (`# Parts` / `# Materials`).

  UTF-8 with an optional leading BOM, TAB-separated, CRLF (or LF) lines. Each
  data row begins with two empty fields (the leading `\\t\\t`); after dropping
  them the positional columns are:

      Furniture: name  id  c3  price  c5  c6  c7
      Materials: name  id  c3  price  c5  unit
  """
  alias PhoenixKitCatalogue.Pro100.Id
  alias PhoenixKitCatalogue.Import.Mapper

  @bom <<0xEF, 0xBB, 0xBF>>

  @type row :: %{
          line_no: pos_integer(),
          raw_line: String.t(),
          id: String.t(),
          name: String.t(),
          base_price: Decimal.t() | nil,
          unit: String.t() | nil,
          service: %{String.t() => String.t()},
          format: :furniture | :materials
        }

  @spec parse(binary(), :furniture | :materials) :: {:ok, [row()]} | {:error, term()}
  def parse(<<@bom, rest::binary>>, format), do: parse(rest, format)
  def parse("", _format), do: {:error, :empty}

  def parse(binary, format) when is_binary(binary) and format in [:furniture, :materials] do
    lines =
      binary
      |> String.split(["\r\n", "\n"])
      |> Enum.reject(&(&1 == ""))

    case lines do
      [header | data] ->
        if valid_header?(header, format) do
          rows = data |> Enum.with_index(2) |> Enum.map(&row(&1, format))
          {:ok, rows}
        else
          {:error, :bad_header}
        end

      [] ->
        {:error, :empty}
    end
  end

  defp valid_header?(header, :furniture), do: String.starts_with?(header, "# Parts\t")
  defp valid_header?(header, :materials), do: String.starts_with?(header, "# Materials\t")

  # Drop the two leading empty fields produced by the row's "\t\t" prefix.
  defp row({raw_line, line_no}, format) do
    cols =
      case String.split(raw_line, "\t") do
        ["", "" | rest] -> rest
        other -> other
      end

    base = %{
      line_no: line_no,
      raw_line: raw_line,
      name: Enum.at(cols, 0, ""),
      id: Id.digits_only(Enum.at(cols, 1)),
      base_price: price(Enum.at(cols, 3)),
      format: format
    }

    columns(base, cols, format)
  end

  defp columns(base, cols, :furniture) do
    base
    |> Map.put(:unit, nil)
    |> Map.put(:service, %{
      "c3" => Enum.at(cols, 2, ""),
      "c5" => Enum.at(cols, 4, ""),
      "c6" => Enum.at(cols, 5, ""),
      "c7" => Enum.at(cols, 6, "")
    })
  end

  defp columns(base, cols, :materials) do
    base
    |> Map.put(:unit, Enum.at(cols, 5))
    |> Map.put(:service, %{"c3" => Enum.at(cols, 2, ""), "c5" => Enum.at(cols, 4, "")})
  end

  defp price(nil), do: nil
  defp price(str) do
    case Mapper.normalize_price(str) do
      {:ok, dec} -> dec
      :error -> nil
    end
  end
end
```

- [ ] **Step 4: Run, verify pass**

Run: `cd <host-app> && mix test ../phoenix_kit_catalogue/test/phoenix_kit_catalogue/import/pro100_parser_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: `mix format` + commit**

```bash
cd /www/phoenix_kit_catalogue && mix format
git add lib/phoenix_kit_catalogue/import/pro100_parser.ex test/phoenix_kit_catalogue/import/pro100_parser_test.exs test/support/fixtures/pro100/
git commit -m "Add PRO100 fixed-layout import parser with round-trip service columns"
```

---

## Task 3: `Import.Matcher`

Resolve a parsed row's digits-id against the items of one catalogue.

**Files:**
- Create: `lib/phoenix_kit_catalogue/import/matcher.ex`
- Test: `test/phoenix_kit_catalogue/import/matcher_test.exs`

**Interfaces:**
- Consumes: `Pro100.Id.digits_only/1`
- Produces:
  - `Matcher.index(items :: [Item.t()]) :: %{String.t() => [Item.t()]}`
  - `Matcher.resolve(index :: map(), id :: String.t()) :: {:matched, Item.t()} | {:ambiguous, [Item.t()]} | :unmatched`

- [ ] **Step 1: Write failing tests (pure — build Item structs inline)**

```elixir
# test/phoenix_kit_catalogue/import/matcher_test.exs
defmodule PhoenixKitCatalogue.Import.MatcherTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Import.Matcher
  alias PhoenixKitCatalogue.Schemas.Item

  defp item(sku), do: %Item{uuid: sku, sku: sku}

  test "indexes by digits-only sku and resolves a unique match" do
    idx = Matcher.index([item("76.0026.12"), item("C-01")])
    assert {:matched, %Item{sku: "76.0026.12"}} = Matcher.resolve(idx, "76002612")
  end

  test "returns :unmatched for unknown and blank ids" do
    idx = Matcher.index([item("76.0026.12")])
    assert :unmatched = Matcher.resolve(idx, "999")
    assert :unmatched = Matcher.resolve(idx, "")
  end

  test "returns :ambiguous when two skus reduce to the same digits" do
    idx = Matcher.index([item("76.00.26.12"), item("7600.2612")])
    assert {:ambiguous, [_, _]} = Matcher.resolve(idx, "76002612")
  end

  test "skips items whose sku has no digits" do
    idx = Matcher.index([item("ABC")])
    assert idx == %{}
  end
end
```

- [ ] **Step 2: Run, verify fail**

Run: `cd <host-app> && mix test ../phoenix_kit_catalogue/test/phoenix_kit_catalogue/import/matcher_test.exs`
Expected: FAIL (module undefined).

- [ ] **Step 3: Implement**

```elixir
# lib/phoenix_kit_catalogue/import/matcher.ex
defmodule PhoenixKitCatalogue.Import.Matcher do
  @moduledoc """
  Matches PRO100 rows to existing catalogue items by digits-only SKU. The index
  is built once over the selected catalogue's items; resolution is O(1).
  """
  alias PhoenixKitCatalogue.Pro100.Id
  alias PhoenixKitCatalogue.Schemas.Item

  @spec index([Item.t()]) :: %{String.t() => [Item.t()]}
  def index(items) do
    items
    |> Enum.reduce(%{}, fn item, acc ->
      case Id.digits_only(item.sku) do
        "" -> acc
        key -> Map.update(acc, key, [item], &[item | &1])
      end
    end)
  end

  @spec resolve(map(), String.t()) ::
          {:matched, Item.t()} | {:ambiguous, [Item.t()]} | :unmatched
  def resolve(_index, ""), do: :unmatched

  def resolve(index, id) do
    case Map.get(index, id) do
      nil -> :unmatched
      [one] -> {:matched, one}
      many -> {:ambiguous, many}
    end
  end
end
```

- [ ] **Step 4: Run, verify pass**

Run: `cd <host-app> && mix test ../phoenix_kit_catalogue/test/phoenix_kit_catalogue/import/matcher_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: `mix format` + commit**

```bash
cd /www/phoenix_kit_catalogue && mix format
git add lib/phoenix_kit_catalogue/import/matcher.ex test/phoenix_kit_catalogue/import/matcher_test.exs
git commit -m "Add PRO100 import matcher (digits-id index within a catalogue)"
```

---

## Task 4: Unit resolution for PRO100 (Mapper)

Add `m → running_meter` and a non-coercing resolver that returns `:unknown` for unrecognized units (so `m³` is not silently turned into `piece`).

**Files:**
- Modify: `lib/phoenix_kit_catalogue/import/mapper.ex`
- Test: `test/phoenix_kit_catalogue/import/mapper_unit_test.exs`

**Interfaces:**
- Produces: `Mapper.resolve_pro100_unit(label :: String.t() | nil) :: {:ok, String.t()} | :unknown`

- [ ] **Step 1: Write failing test**

```elixir
# test/phoenix_kit_catalogue/import/mapper_unit_test.exs
defmodule PhoenixKitCatalogue.Import.MapperUnitTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Import.Mapper

  test "maps known PRO100 unit labels to canonical units" do
    assert Mapper.resolve_pro100_unit("pc") == {:ok, "piece"}
    assert Mapper.resolve_pro100_unit("m²") == {:ok, "m2"}
    assert Mapper.resolve_pro100_unit("m") == {:ok, "running_meter"}
  end

  test "returns :unknown for unmappable units instead of defaulting to piece" do
    assert Mapper.resolve_pro100_unit("m³") == :unknown
    assert Mapper.resolve_pro100_unit(nil) == :unknown
    assert Mapper.resolve_pro100_unit("") == :unknown
  end
end
```

- [ ] **Step 2: Run, verify fail**

Run: `cd <host-app> && mix test ../phoenix_kit_catalogue/test/phoenix_kit_catalogue/import/mapper_unit_test.exs`
Expected: FAIL (`resolve_pro100_unit/1` undefined).

- [ ] **Step 3: Implement**

In `lib/phoenix_kit_catalogue/import/mapper.ex` add `"m" => "running_meter"` to `@unit_aliases`, then add:

```elixir
  @doc """
  Resolves a PRO100 unit label to a canonical unit, or `:unknown` if it has no
  mapping. Unlike `normalize_unit/2`, never coerces unknown labels to "piece"
  (PRO100's `m³` has no equivalent and must surface in the report).
  """
  @spec resolve_pro100_unit(String.t() | nil) :: {:ok, String.t()} | :unknown
  def resolve_pro100_unit(label) when is_binary(label) do
    case Map.get(@unit_aliases, String.downcase(String.trim(label))) do
      nil -> :unknown
      unit -> {:ok, unit}
    end
  end

  def resolve_pro100_unit(_), do: :unknown
```

- [ ] **Step 4: Run, verify pass (+ existing mapper tests)**

Run: `cd <host-app> && mix test ../phoenix_kit_catalogue/test/import/mapper_test.exs ../phoenix_kit_catalogue/test/phoenix_kit_catalogue/import/mapper_unit_test.exs`
Expected: PASS.

- [ ] **Step 5: `mix format` + commit**

```bash
cd /www/phoenix_kit_catalogue && mix format
git add lib/phoenix_kit_catalogue/import/mapper.ex test/phoenix_kit_catalogue/import/mapper_unit_test.exs
git commit -m "Add PRO100 unit resolver (m->running_meter; :unknown for m³)"
```

---

## Task 5: `Import.Pro100Plan`

Turn parsed rows + a matcher index into a diff/report plan.

**Files:**
- Create: `lib/phoenix_kit_catalogue/import/pro100_plan.ex`
- Test: `test/phoenix_kit_catalogue/import/pro100_plan_test.exs`

**Interfaces:**
- Consumes: `Matcher.resolve/2`, `Mapper.resolve_pro100_unit/1`, the parser `row` type
- Produces: `Pro100Plan.build(rows :: [Pro100Parser.row()], index :: map()) :: %{updates: [change], skipped: [skip], stats: map()}` where
  - `change = %{item: Item.t(), row: row, changes: %{atom() => {old, new}}, data: map(), status: :update | :nochange, flags: [atom()]}`
  - `skip = %{row: row, reason: :unmatched | :ambiguous}`

- [ ] **Step 1: Write failing tests (pure — inline Item structs and rows)**

```elixir
# test/phoenix_kit_catalogue/import/pro100_plan_test.exs
defmodule PhoenixKitCatalogue.Import.Pro100PlanTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Import.{Matcher, Pro100Plan}
  alias PhoenixKitCatalogue.Schemas.Item

  defp item(attrs), do: struct(%Item{uuid: "u", sku: "76.0026.12", unit: "piece"}, attrs)

  defp row(attrs) do
    Map.merge(
      %{
        line_no: 2,
        raw_line: "raw",
        id: "76002612",
        name: "X",
        base_price: Decimal.new("100.00"),
        unit: nil,
        service: %{"c3" => "0", "c5" => "1.0", "c6" => "222.00", "c7" => "2.0"},
        format: :furniture
      },
      attrs
    )
  end

  test "matched row with a new price yields an :update with a price change + pro100 data" do
    idx = Matcher.index([item(base_price: Decimal.new("80.00"))])
    plan = Pro100Plan.build([row(%{})], idx)
    assert [change] = plan.updates
    assert change.status == :update
    {old, new} = change.changes.base_price
    assert Decimal.equal?(old, Decimal.new("80.00"))
    assert Decimal.equal?(new, Decimal.new("100.00"))
    assert change.data["pro100"] == %{"format" => "furniture", "c3" => "0", "c5" => "1.0", "c6" => "222.00", "c7" => "2.0"}
  end

  test "identical price yields :nochange (still carries pro100 data)" do
    idx = Matcher.index([item(base_price: Decimal.new("100.00"))])
    plan = Pro100Plan.build([row(%{})], idx)
    assert [change] = plan.updates
    assert change.status == :nochange
  end

  test "materials unknown unit flags unit_unrecognized and keeps current unit" do
    mat_item = item(unit: "piece")
    idx = Matcher.index([mat_item])
    r = row(%{format: :materials, unit: "m³", base_price: Decimal.new("100.00"), service: %{"c3" => "0", "c5" => "1.0"}})
    plan = Pro100Plan.build([r], Map.merge(idx, %{}))
    assert [change] = plan.updates
    assert :unit_unrecognized in change.flags
    refute Map.has_key?(change.changes, :unit)
    assert change.data["original_unit"] == "m³"
  end

  test "unmatched and ambiguous rows go to skipped with reasons" do
    idx = Matcher.index([])
    plan = Pro100Plan.build([row(%{})], idx)
    assert [%{reason: :unmatched}] = plan.skipped
    assert plan.stats.unmatched == 1
  end
end
```

- [ ] **Step 2: Run, verify fail**

Run: `cd <host-app> && mix test ../phoenix_kit_catalogue/test/phoenix_kit_catalogue/import/pro100_plan_test.exs`
Expected: FAIL (module undefined).

- [ ] **Step 3: Implement**

```elixir
# lib/phoenix_kit_catalogue/import/pro100_plan.ex
defmodule PhoenixKitCatalogue.Import.Pro100Plan do
  @moduledoc """
  Builds the PRO100 sync diff/report: matched rows become per-field change sets
  (`base_price`, materials `unit`) plus a `data["pro100"]` round-trip blob;
  unmatched/ambiguous rows go to `:skipped` for the report. Pure — no DB.
  """
  alias PhoenixKitCatalogue.Import.{Matcher, Mapper}

  @spec build([map()], map()) :: %{updates: [map()], skipped: [map()], stats: map()}
  def build(rows, index) do
    {updates, skipped} =
      Enum.reduce(rows, {[], []}, fn row, {ups, skips} ->
        case Matcher.resolve(index, row.id) do
          {:matched, item} -> {[change(item, row) | ups], skips}
          {:ambiguous, _} -> {ups, [%{row: row, reason: :ambiguous} | skips]}
          :unmatched -> {ups, [%{row: row, reason: :unmatched} | skips]}
        end
      end)

    updates = Enum.reverse(updates)
    skipped = Enum.reverse(skipped)

    %{
      updates: updates,
      skipped: skipped,
      stats: %{
        update: Enum.count(updates, &(&1.status == :update)),
        nochange: Enum.count(updates, &(&1.status == :nochange)),
        unmatched: Enum.count(skipped, &(&1.reason == :unmatched)),
        ambiguous: Enum.count(skipped, &(&1.reason == :ambiguous))
      }
    }
  end

  defp change(item, row) do
    {price_changes, _} = price_change(item, row)
    {unit_changes, flags, extra_data} = unit_change(item, row)

    changes = Map.merge(price_changes, unit_changes)
    data = build_data(item, row, extra_data)

    %{
      item: item,
      row: row,
      changes: changes,
      data: data,
      flags: flags,
      status: if(map_size(changes) > 0, do: :update, else: :nochange)
    }
  end

  defp price_change(item, %{base_price: new}) when not is_nil(new) do
    cond do
      is_nil(item.base_price) -> {%{base_price: {nil, new}}, :changed}
      Decimal.equal?(item.base_price, new) -> {%{}, :same}
      true -> {%{base_price: {item.base_price, new}}, :changed}
    end
  end

  defp price_change(_item, _row), do: {%{}, :same}

  # materials: resolve unit; unknown -> keep current unit, flag + stash raw.
  # furniture (unit: nil) and blank labels fall through to the catch-all.
  defp unit_change(item, %{format: :materials, unit: label})
       when is_binary(label) and label != "" do
    case Mapper.resolve_pro100_unit(label) do
      {:ok, unit} ->
        if unit == item.unit,
          do: {%{}, [], %{}},
          else: {%{unit: {item.unit, unit}}, [], %{}}

      :unknown ->
        {%{}, [:unit_unrecognized], %{"original_unit" => label}}
    end
  end

  defp unit_change(_item, _row), do: {%{}, [], %{}}

  defp build_data(item, row, extra) do
    pro100 = Map.put(row.service, "format", Atom.to_string(row.format))
    base = item.data || %{}

    base
    |> Map.put("pro100", pro100)
    |> Map.merge(extra)
  end
end
```

- [ ] **Step 4: Run, verify pass**

Run: `cd <host-app> && mix test ../phoenix_kit_catalogue/test/phoenix_kit_catalogue/import/pro100_plan_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: `mix format` + commit**

```bash
cd /www/phoenix_kit_catalogue && mix format
git add lib/phoenix_kit_catalogue/import/pro100_plan.ex test/phoenix_kit_catalogue/import/pro100_plan_test.exs
git commit -m "Add PRO100 import diff/report plan builder"
```

---

## Task 6: Export round-trip read-back (`Export.Pro100`)

Emit stored `data["pro100"]` service columns, falling back to today's constants.

**Files:**
- Modify: `lib/phoenix_kit_catalogue/export/pro100.ex`
- Test: `test/phoenix_kit_catalogue/export/pro100_roundtrip_test.exs`

**Interfaces:**
- Consumes: `item.data["pro100"]` written by `Pro100Plan`
- Produces: no new public fns; behavior change in `render/2` rows.

- [ ] **Step 1: Write failing tests**

```elixir
# test/phoenix_kit_catalogue/export/pro100_roundtrip_test.exs
defmodule PhoenixKitCatalogue.Export.Pro100RoundtripTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Export.Pro100

  defp ctx(items), do: %{items: items, index: 1_111_111_111, catalogues: [], prefix_catalogue: false}

  test "furniture emits stored service columns instead of constants" do
    item = %{
      name: "Second 1 furniture 222",
      sku: "1111",
      base_price: Decimal.new("2222.00"),
      unit: "piece",
      catalogue: nil,
      data: %{"pro100" => %{"format" => "furniture", "c3" => "0", "c5" => "1.0", "c6" => "222.00", "c7" => "1.0"}}
    }

    {_name, iodata, _mime} = Pro100.render(:furniture, ctx([item]))
    text = IO.iodata_to_binary(iodata)
    assert text =~ "\t\tSecond 1 furniture 222\t1111\t0\t2222.00\t1.0\t222.00\t1.0\r\n"
  end

  test "item without pro100 data falls back to today's constants" do
    item = %{name: "Plain", sku: "W-9", base_price: Decimal.new("5.00"), unit: "piece", catalogue: nil, data: %{}}
    {_n, iodata, _m} = Pro100.render(:furniture, ctx([item]))
    text = IO.iodata_to_binary(iodata)
    assert text =~ "\t\tPlain\tW9\t0\t5.00\t1.0\t\t0.0\r\n"
  end
end
```

- [ ] **Step 2: Run, verify fail**

Run: `cd <host-app> && mix test ../phoenix_kit_catalogue/test/phoenix_kit_catalogue/export/pro100_roundtrip_test.exs`
Expected: FAIL (first test fails — current code hardcodes `c6=""`, `c7="0.0"`).

- [ ] **Step 3: Implement**

In `pro100.ex`, add a private accessor and use it in both row builders:

```elixir
  # Stored PRO100 service column, falling back to the given default when the
  # item was never imported from PRO100.
  defp service(item, key, default) do
    case item do
      %{data: %{"pro100" => %{^key => value}}} when is_binary(value) -> value
      _ -> default
    end
  end
```

Furniture row builder — replace the constant cells:

```elixir
  defp furniture_row(item, prefix?) do
    [
      @tab, @tab,
      sanitize(display_name(item, prefix?)),
      @tab, pro100_id(item.sku),
      @tab, service(item, "c3", "0"),
      @tab, format_price(item.base_price),
      @tab, service(item, "c5", "1.0"),
      @tab, service(item, "c6", ""),
      @tab, service(item, "c7", "0.0"),
      @crlf
    ]
  end
```

Materials row builder — `c3`/`c5` from storage, `c6` stays the real unit:

```elixir
  defp materials_row(item, prefix?) do
    [
      @tab, @tab,
      sanitize(display_name(item, prefix?)),
      @tab, pro100_id(item.sku),
      @tab, service(item, "c3", "0"),
      @tab, format_price(item.base_price),
      @tab, service(item, "c5", "1.0"),
      @tab, sanitize(Item.unit_label(item.unit)),
      @crlf
    ]
  end
```

- [ ] **Step 4: Run, verify pass (incl. existing byte tests unchanged)**

Run: `cd <host-app> && mix test ../phoenix_kit_catalogue/test/phoenix_kit_catalogue/export/pro100_test.exs ../phoenix_kit_catalogue/test/phoenix_kit_catalogue/export/pro100_roundtrip_test.exs`
Expected: PASS (existing tests still green because items there have no `data["pro100"]`; the existing test items must include a `data: %{}` field if the new `service/3` match needs it — `service/3`'s catch-all handles any item shape, so no change required).

- [ ] **Step 5: `mix format` + commit**

```bash
cd /www/phoenix_kit_catalogue && mix format
git add lib/phoenix_kit_catalogue/export/pro100.ex test/phoenix_kit_catalogue/export/pro100_roundtrip_test.exs
git commit -m "PRO100 export reads round-trip service columns with constant fallback"
```

---

## Task 7: Full round-trip integration test (parse → export → byte-identical)

Prove a parsed PRO100 file re-exports byte-identically (minus the freshly-generated header index).

**Files:**
- Test: `test/phoenix_kit_catalogue/import/pro100_roundtrip_test.exs`

**Interfaces:**
- Consumes: `Pro100Parser.parse/2`, `Export.Pro100.render/2`

- [ ] **Step 1: Write the test**

```elixir
# test/phoenix_kit_catalogue/import/pro100_roundtrip_test.exs
defmodule PhoenixKitCatalogue.Import.Pro100RoundtripTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Import.Pro100Parser
  alias PhoenixKitCatalogue.Export.Pro100

  defp fixture(name),
    do: File.read!(Path.join([__DIR__, "..", "..", "support", "fixtures", "pro100", name]))

  # Rebuild item maps from parsed rows the way Pro100Plan would persist them.
  defp to_item(row) do
    %{
      name: row.name,
      sku: row.id,
      base_price: row.base_price,
      unit: "piece",
      catalogue: nil,
      data: %{"pro100" => Map.put(row.service, "format", Atom.to_string(row.format))}
    }
  end

  test "furniture round-trips byte-identically except the header index" do
    original = fixture("furniture_8.txt")
    {:ok, rows} = Pro100Parser.parse(original, :furniture)
    items = Enum.map(rows, &to_item/1)

    {_name, iodata, _mime} =
      Pro100.render(:furniture, %{items: items, index: 1_111_111_111, catalogues: [], prefix_catalogue: false})

    produced = IO.iodata_to_binary(iodata)

    # Compare body (everything after the first CRLF) byte-for-byte.
    body = fn bin -> bin |> String.split("\r\n", parts: 2) |> List.last() end
    # Strip BOM from the original for the body comparison.
    original_nobom = String.replace_prefix(original, <<0xEF, 0xBB, 0xBF>>, "")
    assert body.(produced) == body.(original_nobom)
  end
end
```

- [ ] **Step 2: Run, verify pass**

Run: `cd <host-app> && mix test ../phoenix_kit_catalogue/test/phoenix_kit_catalogue/import/pro100_roundtrip_test.exs`
Expected: PASS. If it fails, diff `produced` vs `original_nobom` — the most likely cause is a unit/price formatting drift; fix the parser/export accordingly (do not weaken the assertion).

- [ ] **Step 3: Commit**

```bash
cd /www/phoenix_kit_catalogue && mix format
git add test/phoenix_kit_catalogue/import/pro100_roundtrip_test.exs
git commit -m "Add PRO100 parse->export byte round-trip test"
```

---

## Task 8: `Import.Source` registry + sources + context wiring

**Files:**
- Create: `lib/phoenix_kit_catalogue/import/source.ex`, `source/universal.ex`, `source/pro100.ex`
- Modify: `lib/phoenix_kit_catalogue/import.ex` (add `sources/0`, `source_by_key/1`, `analyze_pro100/3`)
- Test: `test/phoenix_kit_catalogue/import/source_test.exs`

**Interfaces:**
- Consumes: `Pro100Parser`, `Matcher`, `Pro100Plan`, `Catalogue.list_items/1` (confirm exact name during research — the researcher must find the function that lists a catalogue's items; if none, add a focused query in the context)
- Produces:
  - `Import.sources() :: [module()]`
  - `Import.source_by_key(key) :: module() | nil`
  - `Source` behaviour: `key/0`, `label/0`, `formats/0`, `accept/0`, `flow/0`
  - `Source.Pro100.analyze(binary, format, catalogue_uuid) :: {:ok, plan} | {:error, term()}`
  - `Source.Universal.parse(binary, filename, format) :: {:ok, parsed_file} | {:error, term()}`

- [ ] **Step 1: Write failing tests**

```elixir
# test/phoenix_kit_catalogue/import/source_test.exs
defmodule PhoenixKitCatalogue.Import.SourceTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Import
  alias PhoenixKitCatalogue.Import.Source

  test "registry lists universal + pro100 and looks up by key" do
    keys = Enum.map(Import.sources(), & &1.key())
    assert :universal in keys
    assert :pro100 in keys
    assert Import.source_by_key("pro100") == Source.Pro100
    assert Import.source_by_key(:universal) == Source.Universal
    assert Import.source_by_key("nope") == nil
  end

  test "pro100 source advertises furniture/materials, .txt, :sync flow" do
    assert Source.Pro100.flow() == :sync
    assert Source.Pro100.accept() == ~w(.txt)
    assert Keyword.keys(for {k, _v} <- Source.Pro100.formats(), do: {k, nil}) == [:furniture, :materials]
  end

  test "universal source advertises spreadsheet/json, :mapping flow" do
    assert Source.Universal.flow() == :mapping
    assert {:json, _} = Enum.find(Source.Universal.formats(), fn {k, _} -> k == :json end)
  end
end
```

- [ ] **Step 2: Run, verify fail**

Run: `cd <host-app> && mix test ../phoenix_kit_catalogue/test/phoenix_kit_catalogue/import/source_test.exs`
Expected: FAIL (modules undefined).

- [ ] **Step 3: Implement behaviour + sources**

```elixir
# lib/phoenix_kit_catalogue/import/source.ex
defmodule PhoenixKitCatalogue.Import.Source do
  @moduledoc "Behaviour for import sources — the inbound mirror of Export.Destination."
  @callback key() :: atom()
  @callback label() :: String.t()
  @callback formats() :: [{atom(), String.t()}]
  @callback accept() :: [String.t()]
  @callback flow() :: :mapping | :sync
end
```

```elixir
# lib/phoenix_kit_catalogue/import/source/pro100.ex
defmodule PhoenixKitCatalogue.Import.Source.Pro100 do
  @moduledoc "PRO100 import source: fixed-layout # Parts / # Materials, update-by-id."
  @behaviour PhoenixKitCatalogue.Import.Source
  alias PhoenixKitCatalogue.Import.{Pro100Parser, Matcher, Pro100Plan}

  @impl true
  def key, do: :pro100
  @impl true
  def label, do: "PRO100"
  @impl true
  def formats, do: [{:furniture, "Фурнитура (Furniture)"}, {:materials, "Материалы (Materials)"}]
  @impl true
  def accept, do: ~w(.txt)
  @impl true
  def flow, do: :sync

  @doc "Parse + match + plan against the selected catalogue's items."
  @spec analyze(binary(), :furniture | :materials, [PhoenixKitCatalogue.Schemas.Item.t()]) ::
          {:ok, map()} | {:error, term()}
  def analyze(binary, format, catalogue_items) do
    with {:ok, rows} <- Pro100Parser.parse(binary, format) do
      index = Matcher.index(catalogue_items)
      {:ok, Pro100Plan.build(rows, index)}
    end
  end
end
```

```elixir
# lib/phoenix_kit_catalogue/import/source/universal.ex
defmodule PhoenixKitCatalogue.Import.Source.Universal do
  @moduledoc "Universal import source: XLSX/CSV (existing parser) + JSON (export round-trip)."
  @behaviour PhoenixKitCatalogue.Import.Source
  alias PhoenixKitCatalogue.Import.Parser

  @impl true
  def key, do: :universal
  @impl true
  def label, do: "Универсальный (Universal)"
  @impl true
  def formats, do: [{:spreadsheet, "XLSX / CSV"}, {:json, "JSON (экспорт)"}]
  @impl true
  def accept, do: ~w(.xlsx .csv .tsv .json)
  @impl true
  def flow, do: :mapping

  @doc "Parse a uploaded file into the mapper's parsed_file shape."
  @spec parse(binary(), String.t(), atom()) :: {:ok, map()} | {:error, term()}
  def parse(binary, filename, :json), do: parse_json(binary)
  def parse(binary, filename, _spreadsheet), do: Parser.parse(binary, filename)

  defp parse_json(binary) do
    with {:ok, %{"items" => items}} when is_list(items) <- Jason.decode(binary) do
      headers = ~w(name sku base_price unit catalogue)
      rows = Enum.map(items, fn it -> Enum.map(headers, &to_string(Map.get(it, &1, ""))) end)
      {:ok, %{sheets: [], headers: headers, rows: rows, row_count: length(rows)}}
    else
      {:ok, _} -> {:error, :bad_json_shape}
      err -> err
    end
  end
end
```

Add to `lib/phoenix_kit_catalogue/import.ex`:

```elixir
  @sources [PhoenixKitCatalogue.Import.Source.Universal, PhoenixKitCatalogue.Import.Source.Pro100]

  @spec sources() :: [module()]
  def sources, do: @sources

  @spec source_by_key(atom() | String.t()) :: module() | nil
  def source_by_key(key) when is_atom(key), do: Enum.find(@sources, &(&1.key() == key))

  def source_by_key(key) when is_binary(key) do
    source_by_key(String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end
```

(If `import.ex` does not yet exist as a context module, the researcher confirms where `Import.*` public fns belong — there may be an existing `PhoenixKitCatalogue.Import` namespace only as submodules. In that case create `lib/phoenix_kit_catalogue/import.ex` with `defmodule PhoenixKitCatalogue.Import`.)

- [ ] **Step 4: Run, verify pass**

Run: `cd <host-app> && mix test ../phoenix_kit_catalogue/test/phoenix_kit_catalogue/import/source_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: `mix format` + commit**

```bash
cd /www/phoenix_kit_catalogue && mix format
git add lib/phoenix_kit_catalogue/import/source.ex lib/phoenix_kit_catalogue/import/source/ lib/phoenix_kit_catalogue/import.ex test/phoenix_kit_catalogue/import/source_test.exs
git commit -m "Add Import.Source registry (Universal + PRO100) mirroring Export.Destination"
```

---

## Task 9: `Web.ImportLive` — Source/Format selects + sync flow (preview + report)

Wire the UI: source/format selects on the upload step, branch to `:mapping` (existing) or `:sync` (new preview→apply→report). This is the integration task; it is DB-backed, so its LiveView tests run in the host test env (Postgres) — when local Postgres is unavailable, verify live via Tidewave + the manual steps in the spec's "Live verification".

**Files:**
- Modify: `lib/phoenix_kit_catalogue/web/import_live.ex`
- Test: `test/web/import_live_pro100_test.exs`

**Interfaces:**
- Consumes: `Import.sources/0`, `Import.source_by_key/1`, `Source.Pro100.analyze/3`, `Source.Universal.parse/3`, `Catalogue.update_item/3`, the catalogue's item list query

- [ ] **Step 1: Research the existing wizard (no code yet)**

Read `import_live.ex` end to end. Note: `mount/3` (catalogue list, `allow_upload`), `@step` values (`:upload, :map, :confirm, :importing, :done`), `parse_file`, `continue_to_confirm`, `execute_import`, the ETS row cache, and how the catalogue picker assigns `:catalogue_uuid`. Identify the minimal insertion points. Write findings as a comment block at the top of your working notes (not committed).

- [ ] **Step 2: Add source/format assigns + selects (upload step)**

- Add assigns `:source_key` (default `:universal`), `:format_key` (default first format of the source).
- Add a `handle_event("select_source", %{"source" => key}, socket)` that sets `:source_key`, resets `:format_key` to the source's first format, and updates `allow_upload` accept by re-allowing (`cancel_upload` + `allow_upload` with the new `accept`, or gate parsing on the source — simplest: keep accept as the union `~w(.xlsx .csv .tsv .json .txt)` and validate extension against the source at parse time).
- Add `handle_event("select_format", %{"format" => key}, socket)`.
- Render two `<select>`s above the file input, options from `Import.sources/0` and `source_mod.formats()`, exactly like `ExportLive`'s destination/format selects.

- [ ] **Step 3: Branch parse_file by source flow**

In `parse_file` (after upload is consumed), look up `source_mod = Import.source_by_key(socket.assigns.source_key)`:

```elixir
case source_mod.flow() do
  :mapping ->
    {:ok, parsed} = Import.Source.Universal.parse(binary, filename, socket.assigns.format_key)
    # ... existing mapping path (cache rows in ETS, auto-detect mappings, step: :map)
  :sync ->
    items = Catalogue.list_catalogue_items(socket.assigns.catalogue_uuid)  # confirm exact fn in research
    case Import.Source.Pro100.analyze(binary, socket.assigns.format_key, items) do
      {:ok, plan} -> assign(socket, plan: plan, step: :preview)
      {:error, reason} -> put_flash(socket, :error, pro100_error_message(reason))
    end
end
```

- [ ] **Step 4: Render the preview step**

Add `render` clause for `@step == :preview`: a table of `plan.updates` (item name, sku, per-field `was → will be` from `change.changes`, status badge, flags) and a section listing `plan.skipped` with `row.raw_line` + reason. An **Apply** button (`phx-click="apply_pro100"`), disabled when `plan.stats.update == 0`.

- [ ] **Step 5: Implement apply + report**

```elixir
def handle_event("apply_pro100", _params, socket) do
  %{plan: plan} = socket.assigns
  {ok, failed} =
    plan.updates
    |> Enum.filter(&(&1.status == :update))
    |> Enum.reduce({0, []}, fn change, {ok, failed} ->
      attrs = build_update_attrs(change)   # %{base_price: new, unit: new?, data: change.data}
      case Catalogue.update_item(change.item, attrs) do
        {:ok, _} -> {ok + 1, failed}
        {:error, cs} -> {ok, [%{row: change.row, reason: :error, message: errors(cs)} | failed]}
      end
    end)

  report = %{updated: ok, skipped: plan.skipped ++ Enum.reverse(failed)}
  {:noreply, assign(socket, report: report, step: :report)}
end
```

where `build_update_attrs/1` turns `change.changes` (`%{field => {_old, new}}`) into `%{field => new}` and adds `data: change.data`.

- [ ] **Step 6: Render the report step**

`render` clause for `@step == :report`: "Обновлено: N", then a table of `report.skipped` showing `row.raw_line`, reason (`не опознан`/`неоднозначно`/`ошибка`), and `message` when present. An "Импортировать ещё" reset button.

- [ ] **Step 7: Write a LiveView test (DB-backed)**

```elixir
# test/web/import_live_pro100_test.exs — sketch; align with existing import_live_*_test.exs setup
# Seeds a catalogue with an item sku "1111", uploads furniture_8.txt, asserts the
# preview shows one matched update (price 2222.00) and two unmatched rows in the
# report, applies, and asserts the item's base_price and data["pro100"] persisted.
```

Follow the existing `test/web/import_live_*_test.exs` for upload simulation (`file_input`/`render_upload`). Keep assertions on: preview matched count, skipped raw lines present, post-apply DB state.

- [ ] **Step 8: Run tests (host test env) / live verify**

Run (if Postgres available): `cd <host-app> && mix test ../phoenix_kit_catalogue/test/web/import_live_pro100_test.exs`
Otherwise: recompile + restart elixir, then walk the spec's "Live verification" steps, and verify DB state via Tidewave.

- [ ] **Step 9: `mix format` + `mix quality` + commit**

```bash
cd /www/phoenix_kit_catalogue && mix format
cd <host-app> && mix quality
cd /www/phoenix_kit_catalogue
git add lib/phoenix_kit_catalogue/web/import_live.ex test/web/import_live_pro100_test.exs
git commit -m "Add PRO100 import source + Universal JSON to the import wizard (preview + report)"
```

---

## Task 10: Live verification + recompile/restart

**Files:** none (verification only)

- [ ] **Step 1:** `cd <host-app> && mix compile` — fix any warnings.
- [ ] **Step 2:** `sudo /usr/bin/supervisorctl restart elixir` (path-dep is boot-time). If recompile hits root-owned `_build` artifacts, apply the `_build` root-ownership fix from memory.
- [ ] **Step 3:** Walk the spec's "Live verification" 1–5 (PRO100 import preview/report, round-trip export, Universal JSON, regression check on XLSX/CSV import + plain export).
- [ ] **Step 4:** Confirm `mix quality` is clean. No commit needed unless fixes were made.

---

## Self-Review (completed by plan author)

**Spec coverage:**
- Source registry → Task 8. Source/Format selects + target catalogue → Task 9.
- PRO100 parser (Furniture/Materials) → Task 2. Match-by-digits-id within catalogue → Task 3 + Task 9 (item list). Update-only + report → Task 5 (plan) + Task 9 (apply/report).
- Round-trip `data["pro100"]` → Task 5 (write) + Task 6 (export read-back) + Task 7 (byte round-trip).
- Units `m`/`m³` → Task 4.
- Universal JSON → Task 8 (`Source.Universal.parse/3` json clause) + Task 9 (mapping flow).
- Backward-compat (plain items export unchanged) → Task 6 Step 4 + Task 1 (export tests unchanged).
- Markup (c5) deferred → not implemented (stage 2, per spec non-goals). ✔

**Placeholder scan:** Task 8/9 defer two exact fn names (`Catalogue.list_catalogue_items/1`, `import.ex` location) to a research step because they must be verified against the live codebase — these are research instructions, not placeholders. All code steps carry runnable code.

**Type consistency:** `row` map shape is identical across Tasks 2/5/7. `change`/`skip`/`stats` shapes consistent across Task 5 and consumed in Task 9. `digits_only/1`, `resolve/2`, `resolve_pro100_unit/1`, `parse/2`, `analyze/3` signatures match between producer and consumer tasks.
