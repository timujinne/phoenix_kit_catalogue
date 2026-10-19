defmodule PhoenixKitCatalogue.Import.EncodingTest do
  @moduledoc """
  A text upload is UTF-8 by the time a parser sees it, or it is refused.
  Nothing downstream of a parser — header matching, the JSON-serialised
  preview, the database — survives a cell that is not valid UTF-8. A file
  in a single-byte code page is decoded only with a page named by the
  caller; no page is ever applied on the parser's own guess.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Import.{Encoding, Parser, Pro100Parser}
  alias PhoenixKitCatalogue.Import.Source.Universal

  # "Kõrge kapp" as Excel's plain "CSV" writes it on a Windows-1252/1257
  # machine: õ is the single byte 0xF5.
  @cp125x_data <<"Nimi;Hind\n", "K", 0xF5, "rge kapp;10\n">>
  @cp125x_header <<"Nimi;K", 0xF5, "rgus\n", "Kapp;10\n">>
  # "Имя;Цена" / "Шкаф;10" in Windows-1251.
  @cp1251 <<0xC8, 0xEC, 0xFF, ";", 0xD6, 0xE5, 0xED, 0xE0, "\n", 0xD8, 0xEA, 0xE0, 0xF4, ";10\n">>

  defp utf16(text, endianness, bom),
    do: bom <> :unicode.characters_to_binary(text, :utf8, {:utf16, endianness})

  describe "Encoding.to_utf8/1" do
    test "valid UTF-8 passes through, with or without a byte-order mark" do
      assert Encoding.to_utf8("Kõrge kapp") == {:ok, "Kõrge kapp"}
      assert Encoding.to_utf8(<<0xEF, 0xBB, 0xBF, "Kõrge kapp">>) == {:ok, "Kõrge kapp"}
      assert Encoding.to_utf8("") == {:ok, ""}
    end

    test "UTF-16 with a byte-order mark is decoded, either endianness" do
      assert Encoding.to_utf8(utf16("Kõrge Шкаф", :little, <<0xFF, 0xFE>>)) == {:ok, "Kõrge Шкаф"}
      assert Encoding.to_utf8(utf16("Kõrge Шкаф", :big, <<0xFE, 0xFF>>)) == {:ok, "Kõrge Шкаф"}
    end

    test "a truncated UTF-16 file is refused, not half-decoded" do
      assert Encoding.to_utf8(<<0xFF, 0xFE, 0x4B, 0x00, 0x61>>) == {:error, :not_utf8}
    end

    test "a NUL byte is refused: valid UTF-8, but not text the database can hold" do
      assert Encoding.to_utf8("name\nBad\0Name\n") == {:error, :not_utf8}
      assert Encoding.to_utf8(<<0>>) == {:error, :not_utf8}
    end

    test "a single-byte code page is refused when no page is named" do
      assert Encoding.to_utf8(@cp125x_data) == {:error, :not_utf8}
      assert Encoding.to_utf8(@cp1251) == {:error, :not_utf8}
    end
  end

  # Each sentence is spelled as the bytes a Windows program writes, so the
  # tables are checked against the code pages and not against themselves.
  @estonian_1257 {"Kõrge kapp, šokolaad ja žürii",
                  [0x4B, 0xF5, 0x72, 0x67, 0x65, 0x20, 0x6B, 0x61, 0x70, 0x70, 0x2C, 0x20] ++
                    [0xF0, 0x6F, 0x6B, 0x6F, 0x6C, 0x61, 0x61, 0x64, 0x20, 0x6A, 0x61, 0x20] ++
                    [0xFE, 0xFC, 0x72, 0x69, 0x69]}
  @russian_1251 {"Высокий шкаф, цена № 5",
                 [0xC2, 0xFB, 0xF1, 0xEE, 0xEA, 0xE8, 0xE9, 0x20, 0xF8, 0xEA, 0xE0, 0xF4] ++
                   [0x2C, 0x20, 0xF6, 0xE5, 0xED, 0xE0, 0x20, 0xB9, 0x20, 0x35]}
  @french_1252 {"Étagère en chêne, cœur de hêtre — 10 €",
                [0xC9, 0x74, 0x61, 0x67, 0xE8, 0x72, 0x65, 0x20, 0x65, 0x6E, 0x20, 0x63] ++
                  [0x68, 0xEA, 0x6E, 0x65, 0x2C, 0x20, 0x63, 0x9C, 0x75, 0x72, 0x20, 0x64] ++
                  [0x65, 0x20, 0x68, 0xEA, 0x74, 0x72, 0x65, 0x20, 0x97, 0x20, 0x31, 0x30] ++
                  [0x20, 0x80]}
  @polish_1250 {"Łóżko dębowe, ściana",
                [0xA3, 0xF3, 0xBF, 0x6B, 0x6F, 0x20, 0x64, 0xEA, 0x62, 0x6F, 0x77, 0x65] ++
                  [0x2C, 0x20, 0x9C, 0x63, 0x69, 0x61, 0x6E, 0x61]}
  @estonian_8859_15 {"Žürii šokolaad, 5 €",
                     [0xB4, 0xFC, 0x72, 0x69, 0x69, 0x20, 0xA8, 0x6F, 0x6B, 0x6F, 0x6C, 0x61] ++
                       [0x61, 0x64, 0x2C, 0x20, 0x35, 0x20, 0xA4]}

  @sentences [
    windows_1257: @estonian_1257,
    windows_1251: @russian_1251,
    windows_1252: @french_1252,
    windows_1250: @polish_1250,
    iso_8859_15: @estonian_8859_15
  ]

  # "Kõrge kapp": õ is 0xF5 in Windows-1252, -1257 and ISO-8859-15 alike.
  @korge_kapp :binary.list_to_bin([0x4B, 0xF5, 0x72, 0x67, 0x65, 0x20, 0x6B, 0x61, 0x70, 0x70])

  describe "Encoding.to_utf8/2 with a code page" do
    for {page, {text, bytes}} <- @sentences do
      test "#{page} bytes decode to the sentence they spell" do
        binary = :binary.list_to_bin(unquote(bytes))
        assert Encoding.to_utf8(binary, unquote(page)) == {:ok, unquote(text)}
      end
    end

    test "the same byte is a different letter in each page" do
      assert Encoding.to_utf8(@korge_kapp, :windows_1257) == {:ok, "Kõrge kapp"}
      assert Encoding.to_utf8(@korge_kapp, :windows_1251) == {:ok, "Kхrge kapp"}
      assert Encoding.to_utf8(<<0xF0>>, :windows_1257) == {:ok, "š"}
      assert Encoding.to_utf8(<<0xF0>>, :windows_1252) == {:ok, "ð"}
      assert Encoding.to_utf8(<<0xF0>>, :windows_1250) == {:ok, "đ"}
    end

    test "a byte the page does not define refuses the page" do
      # 0x9C is œ in Windows-1252 and nothing in Windows-1257; 0x98 is
      # nothing in Windows-1251; ISO-8859-15 has no 0x80..0x9F at all.
      assert Encoding.to_utf8(<<"c", 0x9C, "ur">>, :windows_1252) == {:ok, "cœur"}
      assert Encoding.to_utf8(<<"c", 0x9C, "ur">>, :windows_1257) == {:error, :wrong_encoding}
      assert Encoding.to_utf8(<<"a", 0x98>>, :windows_1251) == {:error, :wrong_encoding}
      assert Encoding.to_utf8(<<"a", 0x80>>, :iso_8859_15) == {:error, :wrong_encoding}
    end

    test "a file that names its own encoding ignores the page" do
      assert Encoding.to_utf8("Kõrge kapp", :windows_1251) == {:ok, "Kõrge kapp"}

      assert Encoding.to_utf8(<<0xEF, 0xBB, 0xBF, "Kõrge kapp">>, :windows_1251) ==
               {:ok, "Kõrge kapp"}

      assert Encoding.to_utf8(utf16("Шкаф", :little, <<0xFF, 0xFE>>), :windows_1252) ==
               {:ok, "Шкаф"}
    end

    test "a NUL byte is refused under every page" do
      for page <- Encoding.code_pages() do
        assert Encoding.to_utf8(<<"K", 0xF5, "rge", 0, "kapp">>, page) == {:error, :not_utf8}
      end
    end

    test "no page is to_utf8/1" do
      assert Encoding.to_utf8("Kõrge", nil) == {:ok, "Kõrge"}
      assert Encoding.to_utf8(@korge_kapp, nil) == {:error, :not_utf8}
    end

    test "no byte sequence raises, and what decodes is UTF-8 without a NUL" do
      :rand.seed(:exsss, {21, 22, 23})

      for size <- [0, 1, 2, 3, 17, 64, 255, 1024], page <- Encoding.code_pages() do
        binary = :rand.bytes(size)

        case Encoding.to_utf8(binary, page) do
          {:ok, text} -> assert String.valid?(text) and not String.contains?(text, <<0>>)
          {:error, reason} -> assert reason in [:not_utf8, :wrong_encoding]
        end

        assert Enum.all?(Encoding.preview(binary, page), &String.valid?/1)
        assert Encoding.guess(binary, "et") in Encoding.code_pages()
      end
    end
  end

  describe "Encoding.needs_code_page?/1" do
    test "only a file that is neither self-describing nor binary" do
      assert Encoding.needs_code_page?(@korge_kapp)
      refute Encoding.needs_code_page?("Kõrge kapp")
      refute Encoding.needs_code_page?(utf16("Kõrge", :little, <<0xFF, 0xFE>>))
      refute Encoding.needs_code_page?(<<"K", 0xF5, "rge", 0>>)
      refute Encoding.needs_code_page?("name\nBad\0Name\n")
    end
  end

  describe "Encoding.preview/2 and undefined_bytes/2" do
    test "an undefined byte shows as the replacement character and is counted" do
      binary = <<"c", 0x9C, "ur;1\nb", 0x9C, "uf;2\n">>

      assert Encoding.preview(binary, :windows_1252) == ["cœur;1", "bœuf;2"]
      assert Encoding.undefined_bytes(binary, :windows_1252) == 0

      assert Encoding.preview(binary, :windows_1257) == ["c\uFFFDur;1", "b\uFFFDuf;2"]
      assert Encoding.undefined_bytes(binary, :windows_1257) == 2
    end

    test "the preview is the first lines only, blank ones dropped" do
      binary = :binary.copy(<<"K", 0xF5, "rge\r\n\r\n">>, 50)

      assert Encoding.preview(binary, :windows_1257) == List.duplicate("Kõrge", 6)
    end
  end

  describe "Encoding.guess/2" do
    for {page, {text, bytes}} <- @sentences, locale <- ["en", "et", "ru", "uk", nil] do
      test "#{inspect(text)} is #{page} for a #{inspect(locale)} viewer" do
        assert Encoding.guess(:binary.list_to_bin(unquote(bytes)), unquote(locale)) ==
                 unquote(page)
      end
    end

    test "pages that read the file alike fall to the viewer's locale" do
      # No š or ž: Windows-1252, -1257 and ISO-8859-15 all read "Kõrge kapp".
      assert Encoding.guess(@korge_kapp, "et") == :windows_1257
      assert Encoding.guess(@korge_kapp, "en") == :windows_1252
      assert Encoding.guess(@korge_kapp, "fr") == :windows_1252
      # Windows-1251 reads it as a word mixing Latin and Cyrillic letters,
      # so a Russian viewer's page is not among the equals.
      assert Encoding.guess(@korge_kapp, "ru") == :windows_1252

      # "10 °C": 0xB0 is the degree sign in every page.
      degrees = :binary.list_to_bin([0x31, 0x30, 0x20, 0xB0, 0x43])
      assert Encoding.guess(degrees, "et") == :windows_1257
      assert Encoding.guess(degrees, "ru") == :windows_1251
      assert Encoding.guess(degrees, "uk") == :windows_1251
      assert Encoding.guess(degrees, "de") == :windows_1252
      assert Encoding.guess(degrees, nil) == :windows_1252
    end

    test "a regional locale is read by its language" do
      degrees = <<"10 ", 0xB0, "C">>
      assert Encoding.guess(degrees, "et-EE") == :windows_1257
      assert Encoding.guess(degrees, "ru_RU") == :windows_1251
    end
  end

  describe "Encoding.parse_code_page/1" do
    test "reads back what a form posts and nothing else" do
      for page <- Encoding.code_pages() do
        assert Encoding.parse_code_page(Atom.to_string(page)) == {:ok, page}
      end

      assert Encoding.parse_code_page("utf8") == :error
      assert Encoding.parse_code_page("") == :error
      assert Encoding.parse_code_page(nil) == :error
      assert Encoding.parse_code_page(%{"x" => 1}) == :error
    end
  end

  describe "Parser.parse/2 on a CSV" do
    test "non-UTF-8 data cells are refused with :csv_not_utf8" do
      assert Parser.parse(@cp125x_data, "hinnad.csv") == {:error, :csv_not_utf8}
    end

    test "a non-UTF-8 header is refused with :csv_not_utf8" do
      assert Parser.parse(@cp125x_header, "hinnad.csv") == {:error, :csv_not_utf8}
      assert Parser.parse(@cp1251, "price.csv") == {:error, :csv_not_utf8}
    end

    test "with the code page named, the cells are that page's letters" do
      assert {:ok, %{headers: ["Nimi", "Hind"], rows: [["Kõrge kapp", "10"]]}} =
               Parser.parse(@cp125x_data, "hinnad.csv", encoding: :windows_1257)

      assert {:ok, %{headers: ["Nimi", "Kõrgus"], rows: [["Kapp", "10"]]}} =
               Parser.parse(@cp125x_header, "hinnad.csv", encoding: :windows_1257)

      assert {:ok, %{headers: ["Имя", "Цена"], rows: [["Шкаф", "10"]]}} =
               Parser.parse(@cp1251, "price.csv", encoding: :windows_1251)

      assert {:ok, %{headers: ["Имя", "Цена"], rows: [["Шкаф", "10"]]}} =
               Universal.parse(@cp1251, "price.csv", :spreadsheet, encoding: :windows_1251)
    end

    test "a page the file is not in is :wrong_encoding" do
      assert Parser.parse(<<"name\nc", 0x9C, "ur\n">>, "x.csv", encoding: :windows_1257) ==
               {:error, :wrong_encoding}
    end

    test "a UTF-8 byte-order mark does not end up in the first header" do
      assert {:ok, %{headers: ["Nimi", "Hind"], rows: [["Kõrge kapp", "10"]]}} =
               Parser.parse(<<0xEF, 0xBB, 0xBF, "Nimi;Hind\nKõrge kapp;10\n">>, "hinnad.csv")
    end

    test "Excel's \"Unicode Text\" (UTF-16 LE, tabs) parses to UTF-8 cells" do
      binary = utf16("Nimi\tHind\r\nKõrge kapp\t10\r\n", :little, <<0xFF, 0xFE>>)

      assert {:ok, %{headers: ["Nimi", "Hind"], rows: [["Kõrge kapp", "10"]]}} =
               Parser.parse(binary, "hinnad.csv")
    end

    test "no byte sequence raises or yields a cell that is not UTF-8" do
      :rand.seed(:exsss, {11, 22, 33})

      for size <- Enum.flat_map(0..40, &[&1, &1 * 7, &1 * 53]) do
        binary = :rand.bytes(size)

        case Parser.parse(binary, "random.csv") do
          {:ok, %{headers: headers, rows: rows}} ->
            assert Enum.all?(headers ++ List.flatten(rows), &String.valid?/1),
                   "invalid cell from #{inspect(binary, limit: :infinity)}"

          {:error, _reason} ->
            :ok
        end
      end
    end
  end

  describe "Pro100Parser.parse/2" do
    test "a non-UTF-8 file is refused with :not_utf8" do
      binary = <<"# Parts\tname\tid\tc3\tprice\tc5\tc6\tc7\n\t\tK", 0xF5, "rge\t9\t\t10\t\t\t\n">>
      assert Pro100Parser.parse(binary, :furniture) == {:error, :not_utf8}
      assert Pro100Parser.parse(binary, :materials) == {:error, :not_utf8}
    end

    test "with the code page named, the rows are that page's letters" do
      binary = <<"# Parts\tname\tid\tc3\tprice\tc5\tc6\tc7\n\t\tK", 0xF5, "rge\t9\t\t10\t\t\t\n">>

      assert {:ok, [%{name: "Kõrge", id: "9"}]} =
               Pro100Parser.parse(binary, :furniture, encoding: :windows_1257)

      assert {:ok, [%{name: "Kхrge", id: "9"}]} =
               Pro100Parser.parse(binary, :furniture, encoding: :windows_1251)

      assert Pro100Parser.parse(<<binary::binary, 0x98>>, :furniture, encoding: :windows_1251) ==
               {:error, :wrong_encoding}
    end

    test "a UTF-16 file with a byte-order mark parses" do
      text = "# Parts\tname\tid\tc3\tprice\tc5\tc6\tc7\r\n\t\tKõrge\t9\t\t10\t\t\t\r\n"

      assert {:ok, [%{name: "Kõrge", id: "9"}]} =
               Pro100Parser.parse(utf16(text, :little, <<0xFF, 0xFE>>), :furniture)
    end

    test "a file that is only a byte-order mark is empty" do
      assert Pro100Parser.parse(<<0xEF, 0xBB, 0xBF>>, :furniture) == {:error, :empty}
    end

    test "no byte sequence raises" do
      :rand.seed(:exsss, {4, 5, 6})

      for size <- 0..120, format <- [:furniture, :materials] do
        assert match?(
                 {tag, _} when tag in [:ok, :error],
                 Pro100Parser.parse(:rand.bytes(size), format)
               )
      end
    end
  end

  describe "Universal.parse/3 on JSON" do
    test "the export's own shape parses, with a missing or null field as an empty cell" do
      json =
        ~s({"items":[{"name":"Oak","sku":"A1","base_price":"10.00","unit":null,"item_type":""}]})

      assert Universal.parse(json, "export.json", :json) ==
               {:ok,
                %{
                  sheets: [],
                  headers: ~w(name sku base_price unit item_type ai_notes catalogue dependencies),
                  rows: [["Oak", "A1", "10.00", "", "", "", "", ""]],
                  row_count: 1
                }}
    end

    test "numbers and booleans are plain values" do
      assert {:ok, %{rows: [["7", "", "9.5", "true", "", "", "", ""]]}} =
               Universal.parse(
                 ~s({"items":[{"name":7,"base_price":9.5,"unit":true}]}),
                 "x.json",
                 :json
               )
    end

    for {label, json} <- [
          {"a translated-name object", ~s({"items":[{"name":{"en":"X"}}]})},
          {"items that are not objects", ~s({"items":[1,2]})},
          {"a list of objects as a price", ~s({"items":[{"name":"X","base_price":[{"a":1}]}]})},
          {"a list of numbers as a unit", ~s({"items":[{"name":"X","unit":[1,2]}]})},
          {"one bad item after a good one", ~s({"items":[{"name":"X"},"oops"]})},
          {"a NUL inside a string", ~S({"items":[{"name":"Bad\u0000Name"}]})},
          {"items that is an object", ~s({"items":{"name":"X"}})},
          {"no items key", ~s({"rows":[]})},
          {"a top-level list", ~s([{"name":"X"}])}
        ] do
      test "#{label} is :bad_json_shape" do
        assert Universal.parse(unquote(json), "x.json", :json) == {:error, :bad_json_shape}
      end
    end

    test "bytes that are not JSON are an error, not a raise" do
      assert {:error, %Jason.DecodeError{}} =
               Universal.parse(<<0xFF, 0xFE, 0x00>>, "x.json", :json)
    end
  end
end
