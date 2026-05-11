defmodule PhoenixKitCatalogue.GettextTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Dashboard.Tab

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
  after
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "en")
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
  after
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "en")
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
  after
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "en")
  end
end
