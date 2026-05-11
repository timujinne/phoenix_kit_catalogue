defmodule PhoenixKitCatalogue.GettextTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Dashboard.Tab

  setup do
    previous = Gettext.get_locale(PhoenixKitCatalogue.Gettext)
    on_exit(fn -> Gettext.put_locale(PhoenixKitCatalogue.Gettext, previous) end)
    :ok
  end

  test "PhoenixKitCatalogue.Gettext compiles and is a valid gettext backend" do
    assert Code.ensure_loaded?(PhoenixKitCatalogue.Gettext)
  end

  test "Tab.localized_label/1 returns Russian translation for Catalogue" do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "ru")

    tab = %Tab{
      id: :admin_catalogue,
      label: "Catalogue",
      gettext_backend: PhoenixKitCatalogue.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(tab) == "Каталог"
  end

  test "Tab.localized_label/1 returns Estonian translation for Catalogue" do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "et")

    tab = %Tab{
      id: :admin_catalogue,
      label: "Catalogue",
      gettext_backend: PhoenixKitCatalogue.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(tab) == "Kataloog"
  end

  test "Tab.localized_label/1 falls back to raw label when no gettext_backend set" do
    tab = %Tab{
      id: :admin_catalogue,
      label: "Catalogue"
    }

    assert Tab.localized_label(tab) == "Catalogue"
  end

  test "Tab.localized_label/1 falls back to msgid when translation is missing" do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "ru")

    tab = %Tab{
      id: :admin_unknown,
      label: "This string has no translation",
      gettext_backend: PhoenixKitCatalogue.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(tab) == "This string has no translation"
  end

  describe "ngettext plural selection" do
    test "Russian 3-form rules pick the right msgstr for 1 / 2 / 5 / 21 / 22" do
      Gettext.put_locale(PhoenixKitCatalogue.Gettext, "ru")

      assert ngettext_item(1) == "1 позиция"
      assert ngettext_item(2) == "2 позиции"
      assert ngettext_item(5) == "5 позиций"
      assert ngettext_item(21) == "21 позиция"
      assert ngettext_item(22) == "22 позиции"
    end

    test "Estonian 2-form rules pick singular for 1, plural otherwise" do
      Gettext.put_locale(PhoenixKitCatalogue.Gettext, "et")

      assert ngettext_item(1) == "1 toode"
      assert ngettext_item(2) == "2 toodet"
      assert ngettext_item(5) == "5 toodet"
    end

    test "English passthrough" do
      Gettext.put_locale(PhoenixKitCatalogue.Gettext, "en")

      assert ngettext_item(1) == "1 item"
      assert ngettext_item(5) == "5 items"
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
end
