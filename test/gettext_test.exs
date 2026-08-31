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

  test "every string the UI shows is actually in the catalogues (ru + et)" do
    # The failure this guards is silent by construction: `gettext/1` returns
    # the msgid when a string is missing, so a page renders correct-looking
    # English and no test fails. It is how "Showing catalogues that contain
    # matching items." shipped on 2026-08-28 present in no catalogue at all.
    #
    # A po-vs-po parity check cannot see it either — a string absent from all
    # three files is symmetric. The only thing that catches it is asking the
    # backend, in a non-English locale, for a string the code actually uses.
    for {msgid, ru, et} <- [
          # ("Showing catalogues that contain matching items." was the
          # first entry here; it left with the index's catalogues-
          # containing filter when items search mode replaced it,
          # 2026-08-29.)
          #
          # The items search mode's strings (Max, 2026-08-29):
          {"Search for", "Что искать", "Mida otsida"},
          {"No items match.", "Нет подходящих позиций.", "Sobivaid tooteid pole."},
          {"View in catalogue", "Открыть в каталоге", "Vaata kataloogis"},
          # The category browser's strings (Max, 2026-08-29):
          {"Toggle category", "Развернуть/свернуть категорию", "Ava/sule kategooria"},
          {"Drag to reorder or nest", "Перетащите, чтобы изменить порядок или вложить",
           "Lohista järjestamiseks või pesastamiseks"},
          {"Drop here to move to this level",
           "Перетащите сюда, чтобы переместить на этот уровень",
           "Lohista siia, et tuua sellele tasemele"},
          {"A category cannot move into its own subtree.",
           "Категорию нельзя переместить в её собственное поддерево.",
           "Kategooriat ei saa viia tema enda alampuusse."},
          {"No subcategories here. Switch to Items to browse this level's items.",
           "Здесь нет подкатегорий. Переключитесь на Позиции, чтобы просмотреть позиции этого уровня.",
           "Siin pole alamkategooriaid. Vali Tooted, et sirvida selle taseme tooteid."},
          # Written as the macro inside a HEEx attribute on purpose: the
          # runtime form is NOT extracted from attribute interpolation, which
          # is how these two were in the catalogues but absent from a
          # regenerated .pot. See the Gettext note in AGENTS.md.
          {"Comfortable view", "Просторный вид", "Avar vaade"},
          {"Compact view", "Компактный вид", "Kompaktne vaade"},
          # Found by the 2026-08-29 sweep: all of these were rendered by the
          # UI and present in NO catalogue. `:set_not_found` is the sharpest —
          # `errors_test.exs` pinned `Errors.message(:set_not_found) ==
          # "Attribute set not found."` and passed *because* the string was
          # untranslated, so a green test guarded the bug.
          {"Attribute set not found.", "Набор атрибутов не найден.",
           "Atribuutide komplekti ei leitud."},
          {"Multiple values", "Несколько значений", "Mitu väärtust"},
          {"Fixed value", "Фиксированное значение", "Kindel väärtus"},
          {"Previous page", "Предыдущая страница", "Eelmine leht"},
          {"Next page", "Следующая страница", "Järgmine leht"}
        ] do
      Gettext.put_locale(PhoenixKitCatalogue.Gettext, "ru")
      assert Gettext.gettext(PhoenixKitCatalogue.Gettext, msgid) == ru

      Gettext.put_locale(PhoenixKitCatalogue.Gettext, "et")
      assert Gettext.gettext(PhoenixKitCatalogue.Gettext, msgid) == et
    end
  end

  test "PDF content-search strings are translated (pin for the 2026-08-16 additions)" do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "ru")

    assert Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search PDF contents") ==
             "Поиск по содержимому PDF"

    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "et")

    assert Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search PDF contents") ==
             "Otsi PDF-ide sisust"

    assert Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search by filename…") ==
             "Otsi failinime järgi…"
  end

  test "the supplier-comments note is translated (pin for the per-row threads, 2026-08-24)" do
    msgid =
      "About this supplier for this item only. The company's own comments stay on its CRM page."

    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "ru")

    assert Gettext.gettext(PhoenixKitCatalogue.Gettext, msgid) ==
             "Только об этом поставщике для этого товара. Собственные комментарии компании остаются на её странице в CRM."

    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "et")

    assert Gettext.gettext(PhoenixKitCatalogue.Gettext, msgid) ==
             "Ainult selle tarnija kohta selle toote juures. Ettevõtte enda kommentaarid jäävad tema CRM-i lehele."
  end

  test "the supplier price column label is translated (pin, 2026-08-24)" do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "et")
    assert Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier price") == "Tarnija hind"
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "ru")
    assert Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier price") == "Цена поставщика"
  end

  test "the duplicate strings are translated (pin for the 2026-08-24 Duplicate action)" do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "ru")
    assert Gettext.gettext(PhoenixKitCatalogue.Gettext, "Duplicate") == "Дублировать"

    assert Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{name} (copy)", name: "Труба") ==
             "Труба (копия)"

    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "et")

    assert Gettext.gettext(PhoenixKitCatalogue.Gettext, "Duplicate categories") ==
             "Dubleeri kategooriad"
  end

  test "the category bulk-move strings are translated (pin for the 2026-08-24 toolkit change)" do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "ru")

    assert Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move categories") ==
             "Переместить категории"

    assert Gettext.gettext(PhoenixKitCatalogue.Gettext, "Make them top-level categories") ==
             "Сделать их категориями верхнего уровня"

    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "et")

    assert Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move categories") ==
             "Liiguta kategooriad"

    assert Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select all categories") ==
             "Vali kõik kategooriad"
  end

  test "new #78 error atoms are translated (pin, 2026-08-24)" do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "ru")

    assert Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Cannot move items into a category that is being deleted."
           ) == "Нельзя перенести товары в категорию, которая удаляется."

    assert Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "That selection is not in this catalogue."
           ) ==
             "Этот выбор не принадлежит данному каталогу."

    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "et")

    assert Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Cannot move items into a category that is being deleted."
           ) == "Kirjeid ei saa tõsta kategooriasse, mida kustutatakse."

    assert Gettext.gettext(PhoenixKitCatalogue.Gettext, "This supplier row is no longer current.") ==
             "See tarnija rida ei ole enam kehtiv."
  end

  test "attribute-sets strings are translated (pin for the 2026-08-18 rework, PR #74)" do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "ru")

    assert Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "This set is attached to items — detach it everywhere first."
           ) == "Этот набор прикреплён к товарам — сначала открепите его везде."

    assert Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "The attribute sets module is not enabled."
           ) ==
             "Модуль наборов атрибутов не включён."

    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "et")

    assert Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "This set is attached to items — detach it everywhere first."
           ) == "See komplekt on toodete küljes — eemalda see kõigepealt kõikjalt."

    assert Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "The attribute sets module is not enabled."
           ) ==
             "Atribuudikomplektide moodul ei ole lubatud."
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

  test "Tab.localized_label/1 returns Russian translation for Export" do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "ru")

    tab = %Tab{
      id: :admin_catalogue_export,
      label: "Export",
      gettext_backend: PhoenixKitCatalogue.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(tab) == "Экспорт"
  end

  test "Tab.localized_label/1 returns Estonian translation for Export" do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "et")

    tab = %Tab{
      id: :admin_catalogue_export,
      label: "Export",
      gettext_backend: PhoenixKitCatalogue.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(tab) == "Eksportimine"
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

  # Shared by both describe blocks below.
  #
  # The `en` assertions read the parsed .po file directly (`po_msgstr/2`)
  # rather than going through `Gettext.gettext/2` at runtime
  # (`gettext_in/2`): since the English translation text is identical to
  # the msgid, a runtime lookup returns the same string whether or not
  # the entry actually exists (Gettext's documented behavior on a missing
  # translation is to fall back to the raw msgid) — that would make the
  # assertion pass even with the en.po entry deleted entirely, catching
  # nothing.
  defp gettext_in(locale, msgid) do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, locale)
    Gettext.gettext(PhoenixKitCatalogue.Gettext, msgid)
  end

  # Reads the msgstr for `msgid` straight out of the locale's .po file
  # (nil if the entry is missing), bypassing Gettext's fallback-to-msgid
  # behavior so a deleted/never-added entry actually fails the assertion.
  defp po_msgstr(locale, msgid) do
    path = Path.join(["priv", "gettext", locale, "LC_MESSAGES", "default.po"])
    {:ok, po} = Expo.PO.parse_file(path)

    po.messages
    |> Enum.find(&(IO.iodata_to_binary(&1.msgid) == msgid))
    |> case do
      nil -> nil
      entry -> IO.iodata_to_binary(entry.msgstr)
    end
  end

  # Regression: "Manual order" and "Clear search and filters to
  # drag-and-drop reorder." were added to the .pot and to the et/ru .po
  # files by hand (the manual-order sort feature isn't picked up by
  # `mix gettext.extract`, same as every other string in this backend),
  # but the en.po entry was forgotten — silently harmless today since
  # gettext falls back to the raw msgid, but a ticking trap if the
  # English source text ever changes without updating en.po too.
  describe "manual-order sort strings are present in every locale" do
    test "Manual order" do
      assert po_msgstr("en", "Manual order") == "Manual order"
      assert gettext_in("et", "Manual order") == "Käsitsi järjestus"
      assert gettext_in("ru", "Manual order") == "Ручной порядок"
    end

    test "Clear search and filters to drag-and-drop reorder." do
      msgid = "Clear search and filters to drag-and-drop reorder."
      assert po_msgstr("en", msgid) == msgid

      assert gettext_in("et", msgid) ==
               "Tühjenda otsing ja filtrid, et lohistades ümber järjestada."

      assert gettext_in("ru", msgid) ==
               "Очистите поиск и фильтры, чтобы менять порядок перетаскиванием."
    end
  end

  # Regression: "Export Items" (export_live.ex) had en/ru entries but the
  # et entry was missing, and nothing exercised it — deleting the et entry
  # left the whole suite green. Also covers the four Export-page strings
  # (Destination, Format, "Select a format...", "Add the catalogue name to
  # the item name") that were never added to any locale at all, leaving a
  # Russian or Estonian admin four raw English strings on that page.
  # "Format" and "Select a format..." are shared with the Import page.
  describe "Export tab strings are present in every locale" do
    test "Export Items" do
      assert po_msgstr("en", "Export Items") == "Export Items"
      assert gettext_in("et", "Export Items") == "Ekspordi tooteid"
      assert gettext_in("ru", "Export Items") == "Экспорт позиций"
    end

    test "Destination" do
      assert po_msgstr("en", "Destination") == "Destination"
      assert gettext_in("et", "Destination") == "Sihtkoht"
      assert gettext_in("ru", "Destination") == "Назначение"
    end

    test "Format" do
      assert po_msgstr("en", "Format") == "Format"
      assert gettext_in("et", "Format") == "Formaat"
      assert gettext_in("ru", "Format") == "Формат"
    end

    test "Select a format..." do
      msgid = "Select a format..."
      assert po_msgstr("en", msgid) == msgid
      assert gettext_in("et", msgid) == "Vali formaat..."
      assert gettext_in("ru", msgid) == "Выберите формат..."
    end

    test "Add the catalogue name to the item name" do
      msgid = "Add the catalogue name to the item name"
      assert po_msgstr("en", msgid) == msgid
      assert gettext_in("et", msgid) == "Lisa kataloogi nimi toote nimele"
      assert gettext_in("ru", msgid) == "Добавить название каталога к названию позиции"
    end
  end

  # The featured-image picker names its purpose in the modal heading instead
  # of core's generic "Select Media"; the msgid lives in all three form
  # LiveViews' MediaSelectorModal embeds (catalogue / category / item).
  describe "Media picker strings are present in every locale" do
    test "Select Featured Image" do
      msgid = "Select Featured Image"
      assert po_msgstr("en", msgid) == msgid
      assert gettext_in("et", msgid) == "Vali põhipilt"
      assert gettext_in("ru", msgid) == "Выбрать главное изображение"
    end
  end

  describe "product card strings are present in every locale" do
    test "View item details" do
      assert po_msgstr("en", "View item details") == "View item details"
      assert gettext_in("et", "View item details") == "Vaata toote kaarti"
      assert gettext_in("ru", "View item details") == "Показать карточку товара"
    end

    test "Show this image" do
      assert po_msgstr("en", "Show this image") == "Show this image"
      assert gettext_in("et", "Show this image") == "Näita seda pilti"
      assert gettext_in("ru", "Show this image") == "Показать это изображение"
    end

    test "Close" do
      assert po_msgstr("en", "Close") == "Close"
      assert gettext_in("et", "Close") == "Sulge"
      assert gettext_in("ru", "Close") == "Закрыть"
    end

    test "Open" do
      assert po_msgstr("en", "Open") == "Open"
      assert gettext_in("et", "Open") == "Ava"
      assert gettext_in("ru", "Open") == "Открыть"
    end

    test "Hide" do
      assert po_msgstr("en", "Hide") == "Hide"
      assert gettext_in("et", "Hide") == "Peida"
      assert gettext_in("ru", "Hide") == "Скрыть"
    end

    test "Previous" do
      assert po_msgstr("en", "Previous") == "Previous"
      assert gettext_in("et", "Previous") == "Eelmine"
      assert gettext_in("ru", "Previous") == "Назад"
    end

    test "Next" do
      assert po_msgstr("en", "Next") == "Next"
      assert gettext_in("et", "Next") == "Järgmine"
      assert gettext_in("ru", "Next") == "Вперёд"
    end

    test "view mode strings" do
      for {msgid, et, ru} <- [
            {"Comfortable view", "Avar vaade", "Просторный вид"},
            {"Compact view", "Kompaktne vaade", "Компактный вид"}
          ] do
        assert po_msgstr("en", msgid) == msgid
        assert gettext_in("et", msgid) == et
        assert gettext_in("ru", msgid) == ru
      end
    end

    test "Photos and Files" do
      msgid = "Photos and Files"
      assert po_msgstr("en", msgid) == msgid
      assert gettext_in("et", msgid) == "Fotod ja failid"
      assert gettext_in("ru", msgid) == "Фото и файлы"
    end

    test "folder tree strings" do
      for {msgid, et, ru} <- [
            {"Toggle folder", "Ava/sule kaust", "Развернуть/свернуть папку"},
            {"Up", "Üles", "Вверх"},
            {"Drop here to move to root (unfiled)",
             "Lohista siia, et viia juurtasandile (kaustata)",
             "Перетащите сюда, чтобы переместить в корень (без папки)"},
            {"Drag to reorder or move into a folder",
             "Lohista järjestamiseks või kausta viimiseks",
             "Перетащите, чтобы изменить порядок или переместить в папку"},
            {"Clear search and filters to see the folder tree.",
             "Puhasta otsing ja filtrid, et näha kaustapuud.",
             "Очистите поиск и фильтры, чтобы увидеть дерево папок."}
          ] do
        assert po_msgstr("en", msgid) == msgid
        assert gettext_in("et", msgid) == et
        assert gettext_in("ru", msgid) == ru
      end
    end

    test "empty-only folder delete strings" do
      for {msgid, et, ru} <- [
            {"Empty folder", "Tühi kaust", "Пустая папка"},
            {"Subcategories", "Alamkategooriad", "Подкатегории"},
            {"Only empty folders can be deleted — move its contents out first.",
             "Kustutada saab ainult tühje kaustu — vii sisu enne välja.",
             "Удалять можно только пустые папки — сначала переместите содержимое."}
          ] do
        assert po_msgstr("en", msgid) == msgid
        assert gettext_in("et", msgid) == et
        assert gettext_in("ru", msgid) == ru
      end
    end

    test "save button strings" do
      for {msgid, et, ru} <- [
            {"Save", "Salvesta", "Сохранить"},
            {"Save & Exit", "Salvesta ja välju", "Сохранить и выйти"}
          ] do
        assert po_msgstr("en", msgid) == msgid
        assert gettext_in("et", msgid) == et
        assert gettext_in("ru", msgid) == ru
      end
    end

    test "attribute group strings" do
      for {msgid, et, ru} <- [
            {"Attributes", "Atribuudid", "Атрибуты"},
            {"Archive", "Arhiveeri", "Архивировать"},
            {"Add", "Lisa", "Добавить"},
            {"New Attribute Group", "Uus atribuudirühm", "Новая группа атрибутов"},
            {"Attribute group created.", "Atribuudirühm loodud.", "Группа атрибутов создана."},
            {"Make default", "Määra vaikeväärtuseks", "Сделать по умолчанию"},
            {"This group is used by items — archive it instead.",
             "See rühm on toodetel kasutusel — arhiveeri see kustutamise asemel.",
             "Эта группа используется товарами — вместо удаления заархивируйте её."},
            {"Attribute group", "Atribuudirühm", "Группа атрибутов"},
            {"— No attribute group —", "— Atribuudirühm puudub —", "— Без группы атрибутов —"},
            {"Manage groups", "Halda rühmi", "Управлять группами"}
          ] do
        assert po_msgstr("en", msgid) == msgid
        assert gettext_in("et", msgid) == et
        assert gettext_in("ru", msgid) == ru
      end
    end

    test "View old values interpolates the count" do
      assert po_msgstr("en", "View old values (%{count})") == "View old values (%{count})"

      assert Gettext.with_locale(PhoenixKitCatalogue.Gettext, "ru", fn ->
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "View old values (%{count})",
                 count: 3
               )
             end) == "Старые значения (3)"
    end

    test "reorder-all strings" do
      for {msgid, et, ru} <- [
            {"Reorder all", "Järjesta kõik ümber", "Переупорядочить все"},
            {"Catalogues reordered.", "Kataloogid järjestati ümber.",
             "Каталоги переупорядочены."},
            {"Categories reordered.", "Kategooriad järjestati ümber.",
             "Категории переупорядочены."},
            {"Failed to reorder.", "Ümberjärjestamine ebaõnnestus.",
             "Не удалось изменить порядок."},
            {"catalogue", "kataloog", "каталог"},
            {"catalogues", "kataloogid", "каталоги"},
            {"category", "kategooria", "категория"},
            {"categories", "kategooriad", "категории"}
          ] do
        assert po_msgstr("en", msgid) == msgid
        assert gettext_in("et", msgid) == et
        assert gettext_in("ru", msgid) == ru
      end
    end

    test "Show image %{number}" do
      msgid = "Show image %{number}"
      assert po_msgstr("en", msgid) == msgid

      assert Gettext.gettext(PhoenixKitCatalogue.Gettext, msgid, number: 2) =~ "2"

      Gettext.put_locale(PhoenixKitCatalogue.Gettext, "et")
      assert Gettext.gettext(PhoenixKitCatalogue.Gettext, msgid, number: 2) == "Näita pilti 2"

      Gettext.put_locale(PhoenixKitCatalogue.Gettext, "ru")

      assert Gettext.gettext(PhoenixKitCatalogue.Gettext, msgid, number: 2) ==
               "Показать изображение 2"
    end
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

  # PR #76 — item selector modal / embeddable browse. These were added by
  # hand to default.pot and en/et/ru (mix gettext.extract would wipe the
  # catalogues). Empty en msgstr is Gettext's "use the msgid" convention.
  describe "item selector strings are present in every locale" do
    test "Select items" do
      msgid = "Select items"
      assert po_msgstr("en", msgid) != nil
      assert gettext_in("et", msgid) == "Vali tooted"
      assert gettext_in("ru", msgid) == "Выберите позиции"
    end

    test "Confirm selection" do
      msgid = "Confirm selection"
      assert po_msgstr("en", msgid) != nil
      assert gettext_in("et", msgid) == "Kinnita valik"
      assert gettext_in("ru", msgid) == "Подтвердить выбор"
    end

    test "Not available in this selection" do
      msgid = "Not available in this selection"
      assert po_msgstr("en", msgid) != nil
      assert gettext_in("et", msgid) == "Selles valikus pole saadaval"
      assert gettext_in("ru", msgid) == "Недоступно в этом выборе"
    end

    test "No items match your search." do
      msgid = "No items match your search."
      assert po_msgstr("en", msgid) != nil
      assert gettext_in("et", msgid) == "Otsingule vastavaid tooteid pole."
      assert gettext_in("ru", msgid) == "Нет позиций, соответствующих запросу."
    end

    # The item-details page's mode-aware footer control (2026-08-30).
    test "Add to selection" do
      msgid = "Add to selection"
      assert po_msgstr("en", msgid) != nil
      assert gettext_in("et", msgid) == "Lisa valikusse"
      assert gettext_in("ru", msgid) == "Добавить в выбор"
    end

    test "Remove from selection" do
      msgid = "Remove from selection"
      assert po_msgstr("en", msgid) != nil
      assert gettext_in("et", msgid) == "Eemalda valikust"
      assert gettext_in("ru", msgid) == "Убрать из выбора"
    end

    # The details page's Back button (2026-08-31 sweep caught the
    # missing pin — its two sibling msgids from the same feature were
    # pinned, this one wasn't).
    test "Back" do
      msgid = "Back"
      assert po_msgstr("en", msgid) != nil
      assert gettext_in("et", msgid) == "Tagasi"
      assert gettext_in("ru", msgid) == "Назад"
    end

    # The kmpl (Estonian set/komplekt) unit option (boss, 2026-08-31).
    test "Set (kmpl)" do
      msgid = "Set (kmpl)"
      assert po_msgstr("en", msgid) != nil
      assert gettext_in("et", msgid) == "Komplekt (kmpl)"
      assert gettext_in("ru", msgid) == "Комплект (компл.)"
    end

    # The built-in supplier field's label, translated at call time in
    # SupplierFields.builtin_fields/0 (a compile-time map can only carry
    # the msgid).
    test "Unit cost" do
      msgid = "Unit cost"
      assert po_msgstr("en", msgid) != nil
      assert gettext_in("et", msgid) == "Ühikuhind"
      assert gettext_in("ru", msgid) == "Цена за единицу"

      # The label is resolved at CALL time for the process locale.
      Gettext.put_locale(PhoenixKitCatalogue.Gettext, "et")

      assert PhoenixKitCatalogue.Catalogue.supplier_builtin_field("unit_cost")["label"] ==
               "Ühikuhind"
    end
  end

  describe "import failed-step strings are present in every locale" do
    test "Import Failed" do
      msgid = "Import Failed"
      assert po_msgstr("en", msgid) != nil
      assert gettext_in("et", msgid) == "Import ebaõnnestus"
      assert gettext_in("ru", msgid) == "Импорт не удался"
    end

    test "failure explanation" do
      msgid =
        "The import stopped unexpectedly before it finished. Rows written before the failure were kept. Check the server log for details."

      assert po_msgstr("en", msgid) != nil

      assert gettext_in("et", msgid) ==
               "Import katkes ootamatult enne lõpetamist. Enne tõrget kirjutatud read jäid alles. Üksikasjad leiad serveri logist."

      assert gettext_in("ru", msgid) ==
               "Импорт неожиданно прервался до завершения. Строки, записанные до сбоя, сохранены. Подробности — в журнале сервера."
    end
  end
end
