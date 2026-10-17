defmodule PhoenixKitCatalogue.Import.Encoding do
  @moduledoc """
  Normalises the bytes of an uploaded text file to UTF-8 before parsing.

  Everything downstream of a text parser — header matching, the mapping
  preview the socket serialises as JSON, the database — assumes valid
  UTF-8, so a file in any other encoding is settled here, at the parse
  entry, rather than wherever its first non-ASCII byte happens to land.

  A byte-order mark names the encoding exactly, so UTF-8 and UTF-16 files
  that carry one are decoded, and a file with no mark that is valid UTF-8
  is UTF-8. Anything else is in some single-byte code page, and which one
  cannot be told from the bytes: Windows-1252, -1257 and -1251 give the
  same byte different letters. So the code page is never applied silently:
  `to_utf8/1` refuses such a file, `guess/2` proposes the likeliest page,
  and `to_utf8/2` decodes with the page a person confirmed after seeing
  `preview/2`.

  The tables are the Unicode Consortium's vendor mappings, held here
  rather than taken from a library: an encoding library compiles its
  tables from the host application's config, which a dependency cannot
  set. A byte a page leaves undefined has no character, and the C1
  control range of ISO-8859-15 is treated the same way — no text file
  holds one, so such a byte means the file is in another page.
  ISO-8859-1 is not listed: Windows-1252 reads every byte Latin-1 text
  can hold to the same character.
  """

  @utf8_bom <<0xEF, 0xBB, 0xBF>>
  @utf16_le_bom <<0xFF, 0xFE>>
  @utf16_be_bom <<0xFE, 0xFF>>

  @typedoc "A single-byte code page a person can choose for a file."
  @type code_page ::
          :windows_1252 | :windows_1257 | :windows_1251 | :windows_1250 | :iso_8859_15

  # Listed in the order a tie in `guess/2` falls back to.
  @code_pages [:windows_1252, :windows_1257, :windows_1251, :windows_1250, :iso_8859_15]

  # Where ISO-8859-15 departs from Latin-1, whose bytes are their own
  # code points.
  @latin_9_replacements %{
    0xA4 => "20AC",
    0xA6 => "0160",
    0xA8 => "0161",
    0xB4 => "017D",
    0xB8 => "017E",
    0xBC => "0152",
    0xBD => "0153",
    0xBE => "0178"
  }

  # The upper half (bytes 0x80..0xFF) of each page as hex code points;
  # `----` is a byte the page does not define. The lower half is ASCII in
  # all of them.
  @upper_halves %{
    windows_1250: ~w(
      20AC ---- 201A ---- 201E 2026 2020 2021
      ---- 2030 0160 2039 015A 0164 017D 0179
      ---- 2018 2019 201C 201D 2022 2013 2014
      ---- 2122 0161 203A 015B 0165 017E 017A
      00A0 02C7 02D8 0141 00A4 0104 00A6 00A7
      00A8 00A9 015E 00AB 00AC 00AD 00AE 017B
      00B0 00B1 02DB 0142 00B4 00B5 00B6 00B7
      00B8 0105 015F 00BB 013D 02DD 013E 017C
      0154 00C1 00C2 0102 00C4 0139 0106 00C7
      010C 00C9 0118 00CB 011A 00CD 00CE 010E
      0110 0143 0147 00D3 00D4 0150 00D6 00D7
      0158 016E 00DA 0170 00DC 00DD 0162 00DF
      0155 00E1 00E2 0103 00E4 013A 0107 00E7
      010D 00E9 0119 00EB 011B 00ED 00EE 010F
      0111 0144 0148 00F3 00F4 0151 00F6 00F7
      0159 016F 00FA 0171 00FC 00FD 0163 02D9
    ),
    windows_1251: ~w(
      0402 0403 201A 0453 201E 2026 2020 2021
      20AC 2030 0409 2039 040A 040C 040B 040F
      0452 2018 2019 201C 201D 2022 2013 2014
      ---- 2122 0459 203A 045A 045C 045B 045F
      00A0 040E 045E 0408 00A4 0490 00A6 00A7
      0401 00A9 0404 00AB 00AC 00AD 00AE 0407
      00B0 00B1 0406 0456 0491 00B5 00B6 00B7
      0451 2116 0454 00BB 0458 0405 0455 0457
      0410 0411 0412 0413 0414 0415 0416 0417
      0418 0419 041A 041B 041C 041D 041E 041F
      0420 0421 0422 0423 0424 0425 0426 0427
      0428 0429 042A 042B 042C 042D 042E 042F
      0430 0431 0432 0433 0434 0435 0436 0437
      0438 0439 043A 043B 043C 043D 043E 043F
      0440 0441 0442 0443 0444 0445 0446 0447
      0448 0449 044A 044B 044C 044D 044E 044F
    ),
    windows_1252: ~w(
      20AC ---- 201A 0192 201E 2026 2020 2021
      02C6 2030 0160 2039 0152 ---- 017D ----
      ---- 2018 2019 201C 201D 2022 2013 2014
      02DC 2122 0161 203A 0153 ---- 017E 0178
      00A0 00A1 00A2 00A3 00A4 00A5 00A6 00A7
      00A8 00A9 00AA 00AB 00AC 00AD 00AE 00AF
      00B0 00B1 00B2 00B3 00B4 00B5 00B6 00B7
      00B8 00B9 00BA 00BB 00BC 00BD 00BE 00BF
      00C0 00C1 00C2 00C3 00C4 00C5 00C6 00C7
      00C8 00C9 00CA 00CB 00CC 00CD 00CE 00CF
      00D0 00D1 00D2 00D3 00D4 00D5 00D6 00D7
      00D8 00D9 00DA 00DB 00DC 00DD 00DE 00DF
      00E0 00E1 00E2 00E3 00E4 00E5 00E6 00E7
      00E8 00E9 00EA 00EB 00EC 00ED 00EE 00EF
      00F0 00F1 00F2 00F3 00F4 00F5 00F6 00F7
      00F8 00F9 00FA 00FB 00FC 00FD 00FE 00FF
    ),
    windows_1257: ~w(
      20AC ---- 201A ---- 201E 2026 2020 2021
      ---- 2030 ---- 2039 ---- 00A8 02C7 00B8
      ---- 2018 2019 201C 201D 2022 2013 2014
      ---- 2122 ---- 203A ---- 00AF 02DB ----
      00A0 ---- 00A2 00A3 00A4 ---- 00A6 00A7
      00D8 00A9 0156 00AB 00AC 00AD 00AE 00C6
      00B0 00B1 00B2 00B3 00B4 00B5 00B6 00B7
      00F8 00B9 0157 00BB 00BC 00BD 00BE 00E6
      0104 012E 0100 0106 00C4 00C5 0118 0112
      010C 00C9 0179 0116 0122 0136 012A 013B
      0160 0143 0145 00D3 014C 00D5 00D6 00D7
      0172 0141 015A 016A 00DC 017B 017D 00DF
      0105 012F 0101 0107 00E4 00E5 0119 0113
      010D 00E9 017A 0117 0123 0137 012B 013C
      0161 0144 0146 00F3 014D 00F5 00F6 00F7
      0173 0142 015B 016B 00FC 017C 017E 02D9
    ),
    # Latin-1 with eight characters replaced, and no C1 range.
    iso_8859_15:
      List.duplicate("----", 32) ++
        Enum.map(0xA0..0xFF, &Map.get(@latin_9_replacements, &1, Integer.to_string(&1, 16)))
  }

  # Per page: a 256-tuple of code points (`nil` where undefined), the same
  # as UTF-8 binaries with U+FFFD in the undefined slots, and the list of
  # undefined bytes as binaries for `:binary.matches/2`.
  @pages Map.new(@upper_halves, fn {page, upper} ->
           128 = length(upper)

           code_points =
             Enum.to_list(0x00..0x7F) ++
               Enum.map(upper, fn
                 "----" -> nil
                 hex -> String.to_integer(hex, 16)
               end)

           {page,
            %{
              code_points: List.to_tuple(code_points),
              utf8: code_points |> Enum.map(&<<&1 || 0xFFFD::utf8>>) |> List.to_tuple(),
              undefined: for({nil, byte} <- Enum.with_index(code_points), do: <<byte>>)
            }}
         end)

  # How much of a file `guess/2` reads. A code page is one byte per
  # character, so the sample can be cut anywhere.
  @guess_sample_bytes 65_536

  @preview_lines 6
  @preview_line_chars 200

  # The letters the UI languages add to ASCII: Estonian's, and (below, by
  # range) Cyrillic. Other accented Latin letters are plausible, but less
  # so than these.
  @estonian ~c"õäöüšžÕÄÖÜŠŽ"

  # Non-letters a price list plausibly holds: spacing, quotes, dashes,
  # currency and measurement signs. Anything else outside ASCII (box
  # drawing, stray diacritics, rare symbols) counts against a page.
  @plain_symbols [
    0x00A0,
    0x00A3,
    0x00A7,
    0x00A9,
    0x00AB,
    0x00AD,
    0x00AE,
    0x00B0,
    0x00B1,
    0x00B2,
    0x00B3,
    0x00B5,
    0x00B7,
    0x00BB,
    0x00BC,
    0x00BD,
    0x00BE,
    0x00D7,
    0x00F7,
    0x2013,
    0x2014,
    0x2018,
    0x2019,
    0x201A,
    0x201C,
    0x201D,
    0x201E,
    0x2022,
    0x2026,
    0x2030,
    0x2039,
    0x203A,
    0x20AC,
    0x2116,
    0x2122
  ]

  @doc "The code pages a person can choose from, likeliest first."
  @spec code_pages() :: [code_page()]
  def code_pages, do: @code_pages

  @doc """
  Reads a code page from the string a form posts (`Atom.to_string/1` of a
  `t:code_page/0`). Anything else is `:error`.
  """
  @spec parse_code_page(term()) :: {:ok, code_page()} | :error
  def parse_code_page(value) when is_binary(value) do
    case Enum.find(@code_pages, &(Atom.to_string(&1) == value)) do
      nil -> :error
      page -> {:ok, page}
    end
  end

  def parse_code_page(_value), do: :error

  @doc """
  Returns the file's text as UTF-8 with any byte-order mark removed, or
  `{:error, :not_utf8}` when the bytes are not text in an encoding the
  file itself names (a NUL byte included — no text file holds one, and
  the database refuses it).
  """
  @spec to_utf8(binary()) :: {:ok, String.t()} | {:error, :not_utf8}
  def to_utf8(<<@utf8_bom, rest::binary>>), do: validate(rest)
  def to_utf8(<<@utf16_le_bom, rest::binary>>), do: from_utf16(rest, :little)
  def to_utf8(<<@utf16_be_bom, rest::binary>>), do: from_utf16(rest, :big)
  def to_utf8(binary) when is_binary(binary), do: validate(binary)

  @doc """
  As `to_utf8/1`, with the code page to read the file in when it does not
  name its own encoding. A file that is UTF-8 or carries a byte-order mark
  is decoded as that whatever page is passed, so a page can never garble
  it. `{:error, :wrong_encoding}` when the file holds a byte the page does
  not define; `nil` for the page is `to_utf8/1`.
  """
  @spec to_utf8(binary(), code_page() | nil) ::
          {:ok, String.t()} | {:error, :not_utf8 | :wrong_encoding}
  def to_utf8(binary, nil), do: to_utf8(binary)

  def to_utf8(binary, page) when is_binary(binary) and page in @code_pages do
    with {:error, :not_utf8} <- to_utf8(binary) do
      cond do
        not needs_code_page?(binary) -> {:error, :not_utf8}
        undefined_bytes(binary, page) > 0 -> {:error, :wrong_encoding}
        true -> {:ok, decode(binary, page)}
      end
    end
  end

  @doc """
  True for a file `to_utf8/1` refuses that can still be text: no NUL byte,
  so it is in a single-byte code page somebody has to name.
  """
  @spec needs_code_page?(binary()) :: boolean()
  def needs_code_page?(binary) when is_binary(binary) do
    match?({:error, :not_utf8}, to_utf8(binary)) and :binary.match(binary, <<0>>) == :nomatch
  end

  @doc "How many bytes of the file the page has no character for."
  @spec undefined_bytes(binary(), code_page()) :: non_neg_integer()
  def undefined_bytes(binary, page) when is_binary(binary) and page in @code_pages do
    case @pages[page].undefined do
      [] -> 0
      undefined -> binary |> :binary.matches(undefined) |> length()
    end
  end

  @doc """
  The file's first lines read in `page`, for a person to judge the page
  by. A byte the page does not define shows as U+FFFD.
  """
  @spec preview(binary(), code_page()) :: [String.t()]
  def preview(binary, page) when is_binary(binary) and page in @code_pages do
    binary
    |> binary_part(0, min(byte_size(binary), @preview_lines * @preview_line_chars * 2))
    |> decode(page)
    |> String.split(["\r\n", "\n", "\r"])
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.take(@preview_lines)
    |> Enum.map(&String.slice(&1, 0, @preview_line_chars))
  end

  @doc """
  The code page the file is most likely in.

  Each page is scored on what the file's first bytes read as in it:
  Cyrillic and Estonian letters count for a page, other accented Latin
  letters count less, and undefined bytes, unusual symbols and words
  mixing Latin with Cyrillic letters count against it. Pages that score
  the same — Estonian text without š or ž reads identically in
  Windows-1252 and -1257 — fall to the one the viewer's `locale` suggests,
  then to the order of `code_pages/0`.
  """
  @spec guess(binary(), String.t() | nil) :: code_page()
  def guess(binary, locale \\ nil) when is_binary(binary) do
    sample = binary_part(binary, 0, min(byte_size(binary), @guess_sample_bytes))
    preferred = locale_page(locale)

    # `Enum.max_by/2` keeps the first of equal elements.
    [preferred | List.delete(@code_pages, preferred)]
    |> Enum.max_by(&score(sample, &1))
  end

  defp locale_page(locale) when is_binary(locale) do
    case locale |> String.downcase() |> String.slice(0, 2) do
      "et" -> :windows_1257
      lang when lang in ["ru", "uk"] -> :windows_1251
      _ -> :windows_1252
    end
  end

  defp locale_page(_locale), do: :windows_1252

  # ── Decoding ──────────────────────────────────────────────────

  # A NUL is valid UTF-8 and never text: PostgreSQL refuses it in a text
  # value, so a file carrying one is a binary file under a text name.
  defp validate(binary) do
    if String.valid?(binary) and not String.contains?(binary, <<0>>),
      do: {:ok, binary},
      else: {:error, :not_utf8}
  end

  defp from_utf16(binary, endianness) do
    case :unicode.characters_to_binary(binary, {:utf16, endianness}, :utf8) do
      utf8 when is_binary(utf8) -> validate(utf8)
      _incomplete_or_error -> {:error, :not_utf8}
    end
  end

  defp decode(binary, page) do
    utf8 = @pages[page].utf8
    for <<byte <- binary>>, into: "", do: elem(utf8, byte)
  end

  # ── Scoring ───────────────────────────────────────────────────

  defp score(sample, page) do
    code_points = @pages[page].code_points

    sample
    |> :binary.bin_to_list()
    |> Enum.map(&(code_points |> elem(&1) |> classify()))
    |> Enum.chunk_by(&(&1 in [:ascii_letter, :estonian, :latin, :cyrillic]))
    |> Enum.reduce(0, &(&2 + score_run(&1)))
  end

  defp classify(nil), do: :undefined
  defp classify(cp) when cp in ?a..?z or cp in ?A..?Z, do: :ascii_letter
  defp classify(cp) when cp < 0x80, do: :ascii
  defp classify(cp) when cp in @estonian, do: :estonian
  defp classify(cp) when cp in @plain_symbols, do: :plain_symbol
  defp classify(cp) when cp in 0x00C0..0x024F, do: :latin
  defp classify(cp) when cp in 0x0400..0x04FF, do: :cyrillic
  defp classify(_cp), do: :symbol

  # One run is either a word (letters only) or what lies between words.
  defp score_run(run) do
    latin? = Enum.any?(run, &(&1 in [:ascii_letter, :estonian, :latin]))
    cyrillic? = :cyrillic in run

    if latin? and cyrillic? do
      -Enum.count(run, &(&1 != :ascii_letter))
    else
      Enum.reduce(run, 0, &(&2 + points(&1)))
    end
  end

  defp points(:cyrillic), do: 2
  defp points(:estonian), do: 2
  defp points(:latin), do: 1
  defp points(:symbol), do: -2
  defp points(:undefined), do: -20
  defp points(_ascii_or_plain_symbol), do: 0
end
