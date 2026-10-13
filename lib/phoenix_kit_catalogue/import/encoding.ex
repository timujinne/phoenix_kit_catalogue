defmodule PhoenixKitCatalogue.Import.Encoding do
  @moduledoc """
  Normalises the bytes of an uploaded text file to UTF-8 before parsing.

  Everything downstream of a text parser — header matching, the mapping
  preview the socket serialises as JSON, the database — assumes valid
  UTF-8, so a file in any other encoding is settled here, at the parse
  entry, rather than wherever its first non-ASCII byte happens to land.

  A byte-order mark names the encoding exactly, so UTF-8 and UTF-16 files
  that carry one are decoded. A file with no mark that is not valid UTF-8
  is in some single-byte code page, and which one cannot be told from the
  bytes: Windows-1252, -1257 and -1251 give the same byte different
  letters. Guessing would import wrong letters without a word, so the file
  is refused and the operator is asked to save it as UTF-8.
  """

  @utf8_bom <<0xEF, 0xBB, 0xBF>>
  @utf16_le_bom <<0xFF, 0xFE>>
  @utf16_be_bom <<0xFE, 0xFF>>

  @doc """
  Returns the file's text as UTF-8 with any byte-order mark removed, or
  `{:error, :not_utf8}` when the bytes are not text in a known encoding
  (a NUL byte included — no text file holds one, and the database refuses
  it).
  """
  @spec to_utf8(binary()) :: {:ok, String.t()} | {:error, :not_utf8}
  def to_utf8(<<@utf8_bom, rest::binary>>), do: validate(rest)
  def to_utf8(<<@utf16_le_bom, rest::binary>>), do: from_utf16(rest, :little)
  def to_utf8(<<@utf16_be_bom, rest::binary>>), do: from_utf16(rest, :big)
  def to_utf8(binary) when is_binary(binary), do: validate(binary)

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
end
