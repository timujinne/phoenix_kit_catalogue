defmodule PhoenixKitCatalogue.Web.ImportLiveHostileUploadTest do
  @moduledoc """
  Whatever bytes are uploaded, the import wizard answers with a step or a
  message. Every case goes through the real upload form and `parse_file`;
  a crash in `handle_event` would exit the test through the linked view.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Errors
  alias PhoenixKitCatalogue.Import.Encoding

  @import_url "/en/admin/catalogues/import"

  setup do
    %{catalogue: fixture_catalogue(%{name: "Hostile Upload Cat"})}
  end

  defp upload(conn, cat, filename, contents, select \\ %{}) do
    {:ok, view, _html} = live(conn, @import_url)
    params = Map.merge(%{"catalogue" => cat.uuid}, select)

    # A new source resets the format, so the format is picked in a second
    # change, as an operator does.
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

  defp escaped(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp step(view), do: :sys.get_state(view.pid).socket.assigns.step

  # Walks the encoding step the way a hostile client could: every page in
  # the select, a value that is not one, and a confirm after each. A crash
  # would exit the test through the linked view.
  defp poke_encoding_step(view) do
    for value <- Enum.map(Encoding.code_pages(), &Atom.to_string/1) ++ ["utf-7", ""] do
      render_change(view, "choose_encoding", %{"encoding" => value})
      render_submit(view, "confirm_encoding", %{})
    end

    render(view)
  end

  describe "a CSV that is not UTF-8" do
    for {label, bytes} <- [
          {"Windows-1257 data", <<"Nimi;Hind\n", "K", 0xF5, "rge kapp;10\n">>},
          {"a Windows-1257 header", <<"Nimi;K", 0xF5, "rgus\n", "Kapp;10\n">>},
          {"Windows-1251", <<0xC8, 0xEC, 0xFF, ";", 0xD6, 0xE5, "\n", 0xD8, 0xEA, ";10\n">>}
        ] do
      test "#{label}: the operator is asked for the encoding, not refused",
           %{conn: conn, catalogue: cat} do
        {view, html} = upload(conn, cat, "hinnad.csv", unquote(bytes))

        assert step(view) == :encoding
        assert has_element?(view, "#encoding-form select[name=encoding]")
        refute html =~ escaped(Errors.message(:csv_not_utf8))
      end
    end

    test "a NUL byte in a cell is refused at upload, not at the confirm step's query",
         %{conn: conn, catalogue: cat} do
      {view, html} = upload(conn, cat, "nul.csv", "name\nBad\0Name\n")

      assert html =~ escaped(Errors.message(:csv_not_utf8))
      assert step(view) == :upload
    end

    test "UTF-16 with a byte-order mark reaches the mapping step with readable cells",
         %{conn: conn, catalogue: cat} do
      bytes =
        <<0xFF, 0xFE>> <>
          :unicode.characters_to_binary(
            "Nimi\tHind\r\nKõrge kapp\t10\r\n",
            :utf8,
            {:utf16, :little}
          )

      {view, html} = upload(conn, cat, "hinnad.csv", bytes)

      assert step(view) == :map
      assert html =~ "Kõrge kapp"
    end

    test "random bytes never crash the wizard", %{conn: conn, catalogue: cat} do
      :rand.seed(:exsss, {7, 8, 9})

      for size <- [1, 2, 3, 17, 64, 255, 1024, 4096] do
        {view, html} = upload(conn, cat, "random.csv", :rand.bytes(size))

        # Either the bytes happened to be text and the wizard moved on, or
        # it asked for their encoding, or it stayed put and said why.
        assert step(view) in [:map, :encoding] or
                 (step(view) == :upload and
                    Enum.any?(
                      [:csv_not_utf8, :csv_empty, {:csv_parse_failed, ""}],
                      &(html =~ escaped(Errors.message(&1)))
                    )),
               "size #{size}: step #{step(view)}"

        if step(view) == :encoding, do: poke_encoding_step(view)
      end
    end

    test "random bytes without a NUL reach the encoding step and survive every page",
         %{conn: conn, catalogue: cat} do
      :rand.seed(:exsss, {13, 14, 15})

      for size <- [1, 2, 3, 17, 64, 255, 1024, 4096] do
        # 0xFF is never valid UTF-8, so no draw happens to be text.
        bytes = <<0xFF>> <> for(<<b <- :rand.bytes(size)>>, into: "", do: <<max(b, 1)>>)
        {view, _html} = upload(conn, cat, "random.csv", bytes)

        assert step(view) == :encoding, "size #{size}"
        poke_encoding_step(view)
        assert step(view) in [:encoding, :map], "size #{size}"
      end
    end

    test "encoding events with no upload waiting change nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, @import_url)

      render_change(view, "choose_encoding", %{"encoding" => "windows_1251"})
      render_submit(view, "confirm_encoding", %{})

      assert step(view) == :upload
    end
  end

  describe "an XLSX the reader cannot read" do
    alias PhoenixKitCatalogue.XlsxFixture

    test "a real archive with a corrupt sheet is refused with a message",
         %{conn: conn, catalogue: cat} do
      xlsx = XlsxFixture.workbook(~s(<row r="x"><c><v>1</v></c></row>))

      {view, html} = upload(conn, cat, "corrupt.xlsx", xlsx)

      assert html =~ escaped(Errors.message({:xlsx_read_failed, :raised}))
      assert step(view) == :upload
    end

    test "a sound workbook built the same way reaches the mapping step",
         %{conn: conn, catalogue: cat} do
      xlsx =
        XlsxFixture.workbook(
          XlsxFixture.row(1, ["name", "sku"]) <> XlsxFixture.row(2, ["Oak shelf", "A1"])
        )

      {view, html} = upload(conn, cat, "sound.xlsx", xlsx)

      assert step(view) == :map
      assert html =~ "Oak shelf"
    end

    test "random bytes never crash the wizard", %{conn: conn, catalogue: cat} do
      :rand.seed(:exsss, {10, 11, 12})

      for size <- [1, 3, 64, 1024, 4096], prefix <- ["", "PK\x03\x04"] do
        {view, html} = upload(conn, cat, "random.xlsx", prefix <> :rand.bytes(size))

        assert step(view) == :upload

        assert Enum.any?(
                 [{:xlsx_open_failed, nil}, {:xlsx_read_failed, nil}],
                 &(html =~ escaped(Errors.message(&1)))
               ),
               "size #{size}: no message"
      end
    end
  end

  describe "a PRO100 file that is not UTF-8" do
    test "a NUL byte is refused with a message", %{conn: conn, catalogue: cat} do
      bytes =
        <<"# Parts\tname\tid\tc3\tprice\tc5\tc6\tc7\n\t\tK", 0xF5, "rge\0\t9\t\t10\t\t\t\n">>

      {view, html} =
        upload(conn, cat, "export.txt", bytes, %{"source" => "pro100", "format" => "furniture"})

      assert html =~ "This file is not UTF-8 text. Save it as UTF-8 and upload it again."
      assert step(view) == :upload
    end

    test "random bytes never crash the wizard", %{conn: conn, catalogue: cat} do
      :rand.seed(:exsss, {1, 2, 3})

      for size <- [1, 3, 64, 1024] do
        {view, _html} =
          upload(conn, cat, "export.txt", :rand.bytes(size), %{
            "source" => "pro100",
            "format" => "furniture"
          })

        assert step(view) in [:upload, :encoding]
        if step(view) == :encoding, do: poke_encoding_step(view)
        assert step(view) in [:upload, :encoding]
      end
    end
  end

  describe "a JSON file that is not an export" do
    for {label, json} <- [
          {"a translated-name object", ~s({"items":[{"name":{"en":"X"}}]})},
          {"items that are not objects", ~s({"items":[1,2]})},
          {"a list of objects as a price", ~s({"items":[{"name":"X","base_price":[{"a":1}]}]})}
        ] do
      test "#{label}: refused with the shape message", %{conn: conn, catalogue: cat} do
        {view, html} = upload(conn, cat, "export.json", unquote(json))

        assert html =~ "This JSON file is not a catalogue export"
        assert step(view) == :upload
      end
    end

    test "the export's own shape still reaches the mapping step", %{conn: conn, catalogue: cat} do
      json = ~s({"items":[{"name":"Oak shelf","sku":"A1","base_price":"10.00","unit":"piece"}]})
      {view, html} = upload(conn, cat, "export.json", json)

      assert step(view) == :map
      assert html =~ "Oak shelf"
    end
  end
end
