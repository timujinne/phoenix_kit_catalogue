defmodule PhoenixKitCatalogue.Web.ImportLiveEncodingTest do
  @moduledoc """
  A text upload that is not UTF-8 goes through the wizard's encoding step:
  a proposed code page, a preview that follows the select, and an import
  in the page the operator confirmed. Every case goes through the real
  upload form.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Errors

  @import_url "/en/admin/catalogues/import"

  # "name;sku" / "Kõrge kapp;K-1" / "Žürii šokolaad;K-2" as Excel on an
  # Estonian Windows machine writes a plain CSV: Windows-1257, where õ is
  # 0xF5, Ž 0xDE, ü 0xFC and š 0xF0.
  @cp1257_csv :binary.list_to_bin(
                [0x6E, 0x61, 0x6D, 0x65, 0x3B, 0x73, 0x6B, 0x75, 0x0A] ++
                  [0x4B, 0xF5, 0x72, 0x67, 0x65, 0x20, 0x6B, 0x61, 0x70, 0x70, 0x3B] ++
                  [0x4B, 0x2D, 0x31, 0x0A] ++
                  [0xDE, 0xFC, 0x72, 0x69, 0x69, 0x20, 0xF0, 0x6F, 0x6B, 0x6F, 0x6C] ++
                  [0x61, 0x61, 0x64, 0x3B, 0x4B, 0x2D, 0x32, 0x0A]
              )

  setup do
    %{catalogue: fixture_catalogue(%{name: "Encoding Cat"})}
  end

  defp upload(conn, cat, filename, contents, select \\ %{}) do
    {:ok, view, _html} = live(conn, @import_url)
    params = Map.merge(%{"catalogue" => cat.uuid}, select)

    render_change(view, "validate_upload", Map.delete(params, "format"))
    render_change(view, "validate_upload", params)

    file =
      file_input(view, "#upload-form", :import_file, [
        %{last_modified: 1_700_000_000_000, name: filename, content: contents, type: "text/plain"}
      ])

    render_upload(file, filename)
    html = render_submit(view, "parse_file", params)
    {view, html}
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp preview(view), do: view |> element("#encoding-preview") |> render()

  defp choose(view, page),
    do: view |> form("#encoding-form", %{"encoding" => page}) |> render_change()

  defp confirm(view), do: view |> form("#encoding-form") |> render_submit()

  defp await_step(view, step, tries \\ 100) do
    cond do
      assigns(view).step == step -> :ok
      tries == 0 -> flunk("step is #{assigns(view).step}, expected #{step}")
      true -> Process.sleep(50) && await_step(view, step, tries - 1)
    end
  end

  describe "a Windows-1257 CSV" do
    test "stops at the encoding step with the page proposed and the letters right",
         %{conn: conn, catalogue: cat} do
      {view, html} = upload(conn, cat, "hinnad.csv", @cp1257_csv)

      assert assigns(view).step == :encoding
      assert assigns(view).encoding_choice == :windows_1257
      assert has_element?(view, "#import-encoding option[value=windows_1257][selected]")
      assert html =~ "hinnad.csv"

      assert preview(view) =~ "Kõrge kapp;K-1"
      assert preview(view) =~ "Žürii šokolaad;K-2"
      refute has_element?(view, "#encoding-refusal")
    end

    test "the preview is decoded again when the select changes",
         %{conn: conn, catalogue: cat} do
      {view, _html} = upload(conn, cat, "hinnad.csv", @cp1257_csv)

      choose(view, "windows_1251")

      assert assigns(view).encoding_choice == :windows_1251
      assert preview(view) =~ "Kхrge kapp;K-1"
      refute preview(view) =~ "Kõrge"

      choose(view, "windows_1252")
      assert preview(view) =~ "Kõrge kapp;K-1"
      assert preview(view) =~ "Þürii ðokolaad;K-2"

      choose(view, "windows_1257")
      assert preview(view) =~ "Žürii šokolaad;K-2"
    end

    test "confirming imports the items under the names the page spells",
         %{conn: conn, catalogue: cat} do
      {view, _html} = upload(conn, cat, "hinnad.csv", @cp1257_csv)

      html = confirm(view)

      assert assigns(view).step == :map
      assert assigns(view).file_encoding == :windows_1257
      assert assigns(view).pending_file == nil
      assert html =~ "Kõrge kapp"

      render_click(view, "continue_to_confirm", %{})
      assert assigns(view).step == :confirm
      render_click(view, "execute_import", %{})
      await_step(view, :done)

      names = cat.uuid |> Catalogue.list_items_for_catalogue() |> Enum.map(& &1.name)
      assert Enum.sort(names) == ["Kõrge kapp", "Žürii šokolaad"]
    end

    test "the page chosen in the select is the one the import uses",
         %{conn: conn, catalogue: cat} do
      {view, _html} = upload(conn, cat, "hinnad.csv", @cp1257_csv)

      choose(view, "windows_1252")
      confirm(view)

      assert assigns(view).step == :map
      assert assigns(view).file_encoding == :windows_1252
      assert Enum.map(assigns(view).preview_rows, &hd/1) == ["Kõrge kapp", "Þürii ðokolaad"]
    end

    test "a later parse of the same upload reads it in the confirmed page",
         %{conn: conn, catalogue: cat} do
      {view, _html} = upload(conn, cat, "hinnad.csv", @cp1257_csv)
      confirm(view)

      html = render_change(view, "select_sheet", %{"sheet" => "Sheet1"})

      refute html =~ "CSV UTF-8"
      assert assigns(view).headers == ["name", "sku"]
      assert Enum.map(assigns(view).preview_rows, &hd/1) == ["Kõrge kapp", "Žürii šokolaad"]
    end

    test "Back returns to the upload step and forgets the file", %{conn: conn, catalogue: cat} do
      {view, _html} = upload(conn, cat, "hinnad.csv", @cp1257_csv)

      view |> element("#encoding-form button[phx-click=go_back]") |> render_click()

      assert assigns(view).step == :upload
      assert assigns(view).pending_file == nil
      assert assigns(view).filename == nil
    end
  end

  describe "a page the file is not in" do
    # "name" / "cœur": 0x9C is œ in Windows-1252 and no character in
    # Windows-1257.
    @cp1252_csv <<"name\n", "c", 0x9C, "ur\n">>

    test "shows the replacement character and will not go on", %{conn: conn, catalogue: cat} do
      {view, _html} = upload(conn, cat, "noms.csv", @cp1252_csv)

      assert assigns(view).encoding_choice == :windows_1252
      assert preview(view) =~ "cœur"

      choose(view, "windows_1257")

      assert preview(view) =~ "c�ur"
      assert has_element?(view, "#encoding-refusal", Errors.message(:wrong_encoding))
      assert has_element?(view, "#encoding-form button[type=submit][disabled]")

      # The button is disabled in the page; the server refuses it as well.
      html = render_submit(view, "confirm_encoding", %{})

      assert html =~ Errors.message(:wrong_encoding)
      assert assigns(view).step == :encoding
      assert Catalogue.list_items_for_catalogue(cat.uuid) == []

      choose(view, "windows_1252")
      refute has_element?(view, "#encoding-refusal")
      confirm(view)
      assert assigns(view).step == :map
    end
  end

  describe "a file that names its own encoding" do
    test "UTF-8 goes straight to the mapping step", %{conn: conn, catalogue: cat} do
      {view, html} = upload(conn, cat, "hinnad.csv", "name;sku\nKõrge kapp;K-1\n")

      assert assigns(view).step == :map
      assert assigns(view).file_encoding == nil
      assert html =~ "Kõrge kapp"
    end

    test "UTF-8 with a byte-order mark goes straight to the mapping step",
         %{conn: conn, catalogue: cat} do
      {view, _html} =
        upload(conn, cat, "hinnad.csv", <<0xEF, 0xBB, 0xBF, "name;sku\nKõrge kapp;K-1\n">>)

      assert assigns(view).step == :map
      assert assigns(view).headers == ["name", "sku"]
    end
  end

  describe "a Windows-1257 PRO100 file" do
    @pro100 <<"# Parts\tname\tid\tc3\tprice\tc5\tc6\tc7\r\n\t\tK", 0xF5,
              "rge kapp\t9\t\t10\t\t\t\r\n">>

    test "is read in the confirmed page", %{conn: conn, catalogue: cat} do
      {view, _html} =
        upload(conn, cat, "export.txt", @pro100, %{"source" => "pro100", "format" => "furniture"})

      assert assigns(view).step == :encoding
      assert preview(view) =~ "Kõrge kapp"

      choose(view, "windows_1257")
      html = confirm(view)

      assert assigns(view).step == :preview
      assert assigns(view).file_encoding == :windows_1257
      assert html =~ "Kõrge kapp"
    end
  end
end
