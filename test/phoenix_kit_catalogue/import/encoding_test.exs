defmodule PhoenixKitCatalogue.Import.EncodingTest do
  @moduledoc """
  A text upload is UTF-8 by the time a parser sees it, or it is refused.
  Nothing downstream of a parser — header matching, the JSON-serialised
  preview, the database — survives a cell that is not valid UTF-8.
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

    test "a single-byte code page is refused" do
      assert Encoding.to_utf8(@cp125x_data) == {:error, :not_utf8}
      assert Encoding.to_utf8(@cp1251) == {:error, :not_utf8}
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
                  headers: ~w(name sku base_price unit item_type catalogue),
                  rows: [["Oak", "A1", "10.00", "", "", ""]],
                  row_count: 1
                }}
    end

    test "numbers and booleans are plain values" do
      assert {:ok, %{rows: [["7", "", "9.5", "true", "", ""]]}} =
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
