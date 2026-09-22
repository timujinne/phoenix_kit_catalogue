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

  # ── One look for the whole module (boss via Max, 2026-09-21) ────────
  #
  # The owner's complaint was that the same furniture rendered differently
  # from screen to screen: the search box was four widths, a status choice
  # was underline tabs here / a daisyUI `join` on the PDF library / `btn-xs`
  # chips reading "Missing: 4" on translations, and some tabs carried a
  # count while their siblings did not. Each check below states the shared
  # component and names the shapes that were replaced, so a new screen that
  # hand-rolls one fails here instead of reaching the owner.

  # Every event that picks which rows a list shows. Sourced from the LVs'
  # handle_event clauses, NOT from the markup, so a screen that adds a
  # fourth tab idiom is still caught.
  @status_events ~w(switch_view switch_catalogue_view set_filter filter_state)

  test "a status choice is rendered by status_tab/1, never hand-rolled" do
    offenders =
      for file <- @web_sources,
          source = File.read!(file),
          event <- @status_events,
          [tag] <-
            Regex.scan(~r/<([\w.]+)[^>]*phx-click="#{event}"/, source, capture: :all_but_first),
          tag not in ~w(.status_tab Shared.status_tab),
          do: "#{file}: <#{tag}> fires #{event}"

    assert offenders == [],
           "a status choice must render through status_tab/1 — it carries the " <>
             "underline, the active colour and the mandatory count:\n" <>
             Enum.join(offenders, "\n")
  end

  test "status_tab/1 cannot render a tab without its count" do
    # The index shipped a bare "Active" beside a "Deleted (19)". The count
    # is a required attr, so the compiler is the check; this pins that it
    # stays required and that the label is not just concatenated in.
    assert {:status_tab, 1} in Components.__info__(:functions)

    attrs =
      Components.__components__()
      |> Map.fetch!(:status_tab)
      |> Map.fetch!(:attrs)
      |> Map.new(&{&1.name, &1.required})

    assert attrs[:count] == true
    assert attrs[:label] == true
  end

  test "every page search box takes the shared width" do
    dead_widths = ~r/sm:w-64|basis-64|sm:max-w-72|sm:max-w-xl/

    offenders =
      for file <- @web_sources,
          {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          # A doc that NAMES a replaced width is the record of why the
          # helper exists, not a use of it, so backticked spans drop out.
          # Everything else counts, including a bare string returned from a
          # helper — that is how a fifth width would arrive.
          Regex.match?(dead_widths, String.replace(line, ~r/`[^`]*`/, "")),
          do: "#{file}:#{number}: #{String.trim(line)}"

    assert offenders == [],
           "search boxes size themselves through Components.search_width_class/0:\n" <>
             Enum.join(offenders, "\n")
  end

  test "search_width_class/0 is one fixed width, not a grow rule" do
    # A `grow` rule reads as consistent in the markup and renders a
    # different width on every page, because what sits beside the box
    # differs. That is how the four widths happened.
    refute Components.search_width_class() =~ ~r/\bgrow\b|\bflex-1\b|\bbasis-/
  end

  test "every sort selector says what it sorts" do
    bare =
      for file <- @web_sources,
          source = File.read!(file),
          [tag] <- Regex.scan(~r/<\.sort_selector\b[^>]*\/>/, source),
          not Regex.match?(~r/\slabel\b/, tag),
          do: "#{file}: #{tag |> String.split("\n") |> Enum.map_join(" ", &String.trim/1)}"

    assert bare == [],
           ~s(a dropdown reading "Manual" does not say what it does — pass `label`:\n) <>
             Enum.join(bare, "\n")
  end
end
