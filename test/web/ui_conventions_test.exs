defmodule PhoenixKitCatalogue.Web.UIConventionsTest do
  @moduledoc """
  The module's UI conventions, checked over the source so a slip fails here
  rather than in front of the owner (2026-09-19: "why a different font?", and
  "Add supplier" beside "Unit Cost"). The conventions themselves:
  `dev_docs/guides/ui-conventions.md`.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Web.Components

  @web_sources Path.wildcard("lib/phoenix_kit_catalogue/web/**/*.ex")
  # Words that keep their capital inside a sentence-case string: names of
  # things, not headings. Acronyms (SKU, PDF) and words with digits (Pro100)
  # are allowed without listing.
  @proper_nouns ~w(Deleted Shopify Entities Incoterm)

  # The strings the code shows — gettext literals in lib/, not the whole
  # catalog (which also holds entries no page uses any more).
  defp ui_strings do
    sources = Enum.map_join(Path.wildcard("lib/**/*.ex"), "\n", &File.read!/1)

    ~r/gettext(?:_noop)?\(\s*(?:PhoenixKitCatalogue\.Gettext,\s*)?"((?:[^"\\]|\\.)+)"/
    |> Regex.scan(sources, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  test "no field is wrapped in daisyUI's .fieldset — it sets 12px and shrinks the label" do
    offenders =
      for file <- @web_sources,
          {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ ~r/class="[^"]*\bfieldset(-label|-legend)?\b/,
          do: "#{file}:#{number}"

    assert offenders == []
  end

  test "labels, buttons, headings and tabs are sentence case" do
    offenders =
      for id <- ui_strings(),
          # Sentences carry their own capitals; examples are names as typed.
          not (id =~ ~r/[.?!]$|\. [A-Z]|^e\.g\./),
          [_first | rest] <- [List.flatten(Regex.scan(~r/[A-Za-z][A-Za-z'’]*/, id))],
          Enum.any?(rest, &title_word?/1),
          do: id

    assert offenders == []
  end

  defp title_word?(word) do
    String.match?(word, ~r/^[A-Z][a-z]/) and word not in @proper_nouns and
      word not in ~w(No)
  end

  test "an ellipsis is one character" do
    assert Enum.filter(ui_strings(), &String.contains?(&1, "...")) == []
  end

  test "a select prompt reads — X —, or All … for a filter" do
    prompts =
      for file <- @web_sources,
          [_, text] <-
            Regex.scan(
              ~r/\bprompt=\{\s*(?:Gettext\.)?gettext\(\s*(?:PhoenixKitCatalogue\.Gettext,\s*)?"([^"]+)"/,
              File.read!(file)
            ),
          do: text

    assert prompts != []
    assert Enum.reject(prompts, &(&1 =~ ~r/^— .+ —$|^All /)) == []
  end

  # The listing tables the catalogue pages are read from. Their name column is
  # the row's title, and a bare `font-medium` on the cell inherits daisyUI's
  # `table-sm` 12px — smaller than the `text-sm` facts beside it, which is
  # what the owner saw (2026-09-20: "too small"). `name_cell_class/0` sets the
  # size in one place; a new name cell must use it rather than hand-roll one.
  @listing_sources ~w(
    lib/phoenix_kit_catalogue/web/components.ex
    lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex
    lib/phoenix_kit_catalogue/web/catalogues_live.ex
    lib/phoenix_kit_catalogue/web/components/item_selector_modal.ex
  )

  test "a listing table's name cell sizes itself through name_cell_class/0" do
    offenders =
      for file <- @listing_sources,
          {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          # a table cell whose only styling is `font-medium`
          Regex.match?(~r/<(?:\.table_default_cell|td) class="(?:relative )?font-medium">/, line),
          do: "#{file}:#{number}: #{String.trim(line)}"

    assert offenders == [],
           "these cells inherit table-sm's 12px — use name_cell_class():\n" <>
             Enum.join(offenders, "\n")
  end

  test "name_cell_class/0 is larger than the text-sm cells beside it" do
    # text-base (16px) over the siblings' text-sm (14px): the title outranks
    # the facts. A change back to text-sm or smaller is the regression.
    assert Components.name_cell_class() =~ "text-base"
  end

  # The first pass at this only looked for a `<td class="font-medium">`, and
  # the index page's names are `<.link class="link link-hover font-medium">`
  # inside an unclassed cell — so they stayed 12px while the deeper pages
  # grew (caught by Max, 2026-09-20). A name is a name wherever it renders:
  # a table cell, a card header, a link or a button.
  #
  # A broad "unsized font-medium" scan flags buttons, labels and links that
  # correctly inherit from a sized cell, so this counts the helper's call
  # sites per file instead: removing one fails here and names the file. Raise
  # a number when a page legitimately gains a name; never lower one to get
  # green.
  @name_cell_sites %{
    "lib/phoenix_kit_catalogue/web/catalogues_live.ex" => 8,
    "lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex" => 5,
    "lib/phoenix_kit_catalogue/web/components.ex" => 4,
    "lib/phoenix_kit_catalogue/web/components/item_selector_modal.ex" => 2
  }

  test "every listing page still sizes its row names through the helper" do
    actual =
      Map.new(@name_cell_sites, fn {file, _expected} ->
        count =
          file
          |> File.read!()
          |> then(&Regex.scan(~r/name_cell_class\(\)/, &1))
          |> length()

        {file, count}
      end)

    for {file, expected} <- @name_cell_sites do
      assert actual[file] >= expected,
             "#{file} sizes #{actual[file]} row names through name_cell_class/0, " <>
               "down from #{expected} — a name went back to inheriting table-sm's 12px"
    end
  end
end
