defmodule PhoenixKitCatalogue.UkLocaleTest do
  @moduledoc """
  Pins the Ukrainian (`uk`) catalogue.

  Every locale of this module carries exactly the msgids of `default.pot`
  (`msgid_plural` included), in both directions, because new strings are
  added by hand to the template and to every locale; that check runs over
  every locale directory. The Ukrainian file also has no fuzzy or empty
  entries, and each `msgstr` keeps the `%{...}` bindings of its
  msgid. It also resolves through the backend, picks the right plural branch,
  localizes the `strftime` date formats, and leaves English untouched.
  """
  use ExUnit.Case, async: true

  alias Expo.Message
  alias Expo.Messages

  @pot_path Path.join(["priv", "gettext", "default.pot"])
  @uk_path Path.join(["priv", "gettext", "uk", "LC_MESSAGES", "default.po"])

  @date_formats [
    {"%b %d, %Y", "11.10.2026"},
    {"%b %d, %Y %H:%M", "11.10.2026 10:05"}
  ]

  # New strings are added by hand to the template and to every locale, so
  # nothing but this keeps a locale from missing one or keeping a stale
  # one — and a missing string renders as English without a word.
  describe "every locale's catalogue file" do
    test "has exactly the msgids of default.pot, in both directions" do
      pot_ids = msgid_keys(parse!(@pot_path))
      assert MapSet.size(pot_ids) > 1000

      locales = locales()
      assert "uk" in locales
      assert length(locales) >= 6

      for locale <- locales do
        path = Path.join(["priv", "gettext", locale, "LC_MESSAGES", "default.po"])
        assert File.exists?(path), "#{path} is missing"

        ids = msgid_keys(parse!(path))

        assert MapSet.to_list(MapSet.difference(pot_ids, ids)) == [],
               "#{locale} lacks msgids that default.pot has"

        assert MapSet.to_list(MapSet.difference(ids, pot_ids)) == [],
               "#{locale} has msgids that default.pot lacks"
      end
    end
  end

  describe "uk catalogue file" do
    test "has no empty msgstr and no fuzzy entries" do
      messages = parse!(@uk_path).messages

      empty = for m <- messages, empty_msgstr?(m), do: IO.iodata_to_binary(m.msgid)
      fuzzy = for m <- messages, fuzzy?(m), do: IO.iodata_to_binary(m.msgid)

      assert empty == []
      assert fuzzy == []
    end

    test "every msgstr form keeps the %{...} bindings of its msgid" do
      mismatches =
        for message <- parse!(@uk_path).messages,
            {expected, actual} <- binding_pairs(message),
            expected != actual,
            do: {IO.iodata_to_binary(message.msgid), expected, actual}

      assert mismatches == []
    end
  end

  describe "runtime lookup" do
    test "known strings resolve to Ukrainian under the uk locale" do
      for {msgid, uk} <- [
            {"Manual order", "Ручний порядок"},
            {"Export items", "Експорт позицій"},
            {"Catalogue", "Каталог"},
            {"Suppliers", "Постачальники"}
          ] do
        assert gettext_in("uk", msgid) == uk
      end
    end

    test "date formats are localized, not left as the English strftime patterns" do
      datetime = ~U[2026-10-11 10:05:00Z]

      for {msgid, expected} <- @date_formats do
        assert datetime |> Calendar.strftime(gettext_in("uk", msgid)) == expected
      end
    end

    test "plural forms pick the right branch for 1 / 2 / 5 / 11 / 21 / 22 / 25" do
      Gettext.put_locale(PhoenixKitCatalogue.Gettext, "uk")

      assert ngettext_item(1) == "1 позиція"
      assert ngettext_item(2) == "2 позиції"
      assert ngettext_item(5) == "5 позицій"
      assert ngettext_item(11) == "11 позицій"
      assert ngettext_item(21) == "21 позиція"
      assert ngettext_item(22) == "22 позиції"
      assert ngettext_item(25) == "25 позицій"
    end

    test "English is unchanged for the same strings (regression guard)" do
      for msgid <- ["Manual order", "Export items", "Catalogue", "Suppliers"] do
        assert gettext_in("en", msgid) == msgid
      end

      for {msgid, _} <- @date_formats do
        assert gettext_in("en", msgid) == msgid
      end

      Gettext.put_locale(PhoenixKitCatalogue.Gettext, "en")
      assert ngettext_item(1) == "1 item"
      assert ngettext_item(5) == "5 items"
    end
  end

  # Every directory under priv/gettext is a locale.
  defp locales do
    root = Path.join("priv", "gettext")
    root |> File.ls!() |> Enum.filter(&File.dir?(Path.join(root, &1))) |> Enum.sort()
  end

  defp parse!(path) do
    {:ok, po} = Expo.PO.parse_file(path)
    po
  end

  defp msgid_keys(%Messages{messages: messages}), do: MapSet.new(messages, &Message.key/1)

  defp fuzzy?(%{flags: flags}), do: Enum.any?(flags, &("fuzzy" in &1))

  defp empty_msgstr?(%Message.Singular{msgstr: msgstr}),
    do: IO.iodata_to_binary(msgstr) == ""

  defp empty_msgstr?(%Message.Plural{msgstr: forms}),
    do: Enum.any?(forms, fn {_, s} -> IO.iodata_to_binary(s) == "" end)

  # {expected, actual} sorted binding lists for every msgstr form. Plural form 0
  # is checked against the singular msgid, the other forms against msgid_plural.
  defp binding_pairs(%Message.Singular{msgid: msgid, msgstr: msgstr}),
    do: [{bindings(msgid), bindings(msgstr)}]

  defp binding_pairs(%Message.Plural{msgid: msgid, msgid_plural: plural, msgstr: forms}) do
    for {index, msgstr} <- forms do
      source = if index == 0, do: msgid, else: plural
      {bindings(source), bindings(msgstr)}
    end
  end

  defp bindings(iodata) do
    ~r/%\{[^}]*\}/
    |> Regex.scan(IO.iodata_to_binary(iodata))
    |> List.flatten()
    |> Enum.sort()
  end

  defp gettext_in(locale, msgid) do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, locale)
    Gettext.gettext(PhoenixKitCatalogue.Gettext, msgid)
  end

  defp ngettext_item(count) do
    Gettext.dngettext(
      PhoenixKitCatalogue.Gettext,
      "default",
      "%{count} item",
      "%{count} items",
      count,
      count: count
    )
  end
end
