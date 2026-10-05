defmodule PhoenixKitCatalogue.PathsTest do
  @moduledoc """
  Pure-function tests for `PhoenixKitCatalogue.Paths` PDF helpers.

  Only the PDF subset is covered here (`pdfs/0`, `pdf_detail/1,2`,
  `pdf_file/1`, `pdf_viewer/1,2`) — added by the 2026-05-06 Phase 2
  sweep. The other path helpers in the module (catalogues, items,
  manufacturers, etc.) predate this test file and aren't covered.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Paths

  setup do
    # Force the URL prefix to "/" so paths are predictable in this
    # standalone test (matches `test_helper.exs`'s persistent_term).
    :persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")
    :ok
  end

  describe "pdfs/0" do
    test "returns the admin PDF library index path" do
      assert Paths.pdfs() =~ "/admin/catalogues/pdfs"
    end
  end

  describe "pdf_detail/1" do
    test "appends the pdf uuid" do
      uuid = "019df9d5-1b2d-70e0-9776-b94e6341c8d1"
      assert Paths.pdf_detail(uuid) =~ "/admin/catalogues/pdfs/#{uuid}"
    end

    test "does not include any query string" do
      uuid = UUIDv7.generate()
      refute Paths.pdf_detail(uuid) =~ "?"
    end
  end

  describe "pdf_detail/2 (with page)" do
    test "appends the page query param" do
      uuid = UUIDv7.generate()
      assert Paths.pdf_detail(uuid, 5) =~ "page=5"
    end

    test "rejects page < 1 via FunctionClauseError" do
      uuid = UUIDv7.generate()
      assert_raise FunctionClauseError, fn -> Paths.pdf_detail(uuid, 0) end
      assert_raise FunctionClauseError, fn -> Paths.pdf_detail(uuid, -1) end
    end
  end

  describe "pdf_file/1" do
    test "delegates to Storage.URLSigner with the file_uuid + 'original' variant" do
      uuid = UUIDv7.generate()
      url = Paths.pdf_file(%{file_uuid: uuid})
      # Format from URLSigner: "/file/<uuid>/<variant>/<token>"
      assert url =~ "/file/#{uuid}/original/"
    end

    test "produces a stable URL for the same file_uuid" do
      uuid = UUIDv7.generate()
      assert Paths.pdf_file(%{file_uuid: uuid}) == Paths.pdf_file(%{file_uuid: uuid})
    end
  end

  describe "pdf_viewer/1" do
    test "wraps the signed file URL with `URI.encode_www_form`" do
      uuid = UUIDv7.generate()
      url = Paths.pdf_viewer(%{file_uuid: uuid})
      # `?` and `&` from the signed URL get %-escaped — none should be
      # present unescaped inside the file= param.
      assert url =~ "/_pdfjs/web/viewer.html?file="
    end

    test "encoded file URL does not contain an unescaped `#`" do
      # If `URI.encode/1` were used (instead of `encode_www_form/1`),
      # a `#` in the signed URL would corrupt PDF.js's `#page=N` fragment.
      # The signed URL doesn't currently emit `#`, but pin the encoder
      # behavior so a future change to URLSigner can't silently break it.
      uuid = UUIDv7.generate()
      url = Paths.pdf_viewer(%{file_uuid: uuid})

      # Strip the optional `#page=...` we add ourselves; what's left
      # should have no `#`.
      [base, _] = String.split(url <> "#sentinel", "#", parts: 2)
      refute base =~ ~r/[?&]file=[^&]*#/
    end
  end

  describe "pdf_viewer/2 (with page)" do
    test "appends `#page=N` fragment" do
      uuid = UUIDv7.generate()
      assert Paths.pdf_viewer(%{file_uuid: uuid}, 7) =~ "#page=7"
    end

    test "page=N comes AFTER the encoded file param (not inside it)" do
      uuid = UUIDv7.generate()
      url = Paths.pdf_viewer(%{file_uuid: uuid}, 12)
      # The file= param ends before `#`, and #page=12 follows.
      [_, fragment] = String.split(url, "#", parts: 2)
      assert fragment == "page=12"
    end

    test "rejects page < 1 via FunctionClauseError" do
      uuid = UUIDv7.generate()
      assert_raise FunctionClauseError, fn -> Paths.pdf_viewer(%{file_uuid: uuid}, 0) end
    end
  end
end
