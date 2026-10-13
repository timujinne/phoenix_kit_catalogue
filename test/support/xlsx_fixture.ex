defmodule PhoenixKitCatalogue.XlsxFixture do
  @moduledoc """
  Builds the smallest workbook XlsxReader opens, in memory, around whatever
  worksheet XML a test hands it — so a test can upload a file that is a real
  XLSX archive with a sheet the reader was never meant to see.
  """

  @content_types """
  <?xml version="1.0" encoding="UTF-8"?>
  <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
    <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
  </Types>
  """

  @workbook """
  <?xml version="1.0" encoding="UTF-8"?>
  <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
    <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
  </workbook>
  """

  @workbook_rels """
  <?xml version="1.0" encoding="UTF-8"?>
  <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
  </Relationships>
  """

  @doc "An XLSX binary whose only sheet holds `rows_xml` inside `<sheetData>`."
  @spec workbook(String.t()) :: binary()
  def workbook(rows_xml) do
    sheet = """
    <?xml version="1.0" encoding="UTF-8"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <sheetData>#{rows_xml}</sheetData>
    </worksheet>
    """

    files = [
      {~c"[Content_Types].xml", @content_types},
      {~c"xl/workbook.xml", @workbook},
      {~c"xl/_rels/workbook.xml.rels", @workbook_rels},
      {~c"xl/worksheets/sheet1.xml", sheet}
    ]

    {:ok, {_name, binary}} = :zip.create(~c"fixture.xlsx", files, [:memory])
    binary
  end

  @doc "A row of inline-string cells, numbered `r`."
  @spec row(term(), [String.t()]) :: String.t()
  def row(r, cells) do
    cells_xml =
      Enum.map_join(cells, fn text -> ~s(<c t="inlineStr"><is><t>#{text}</t></is></c>) end)

    ~s(<row r="#{r}">#{cells_xml}</row>)
  end
end
