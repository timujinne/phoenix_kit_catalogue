defmodule PhoenixKitCatalogue.Web.EventsSummaryTest do
  @moduledoc """
  The Events list renders metadata that now contains MAPS — a from/to diff and
  snapshotted `{uuid, label}` references. Bare interpolation on those raises
  Protocol.UndefinedError and takes the page down, so the summary must go
  through the shared humanizer.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Activity

  test "a map value would raise under bare interpolation" do
    assert_raise Protocol.UndefinedError, fn ->
      "#{%{"from" => "a", "to" => "b"}}"
    end
  end

  test "the humanizer renders every shape the catalogue writes" do
    assert Activity.humanize_metadata_value(%{"from" => "T-21", "to" => "T-22"}) == "T-21 → T-22"
    assert Activity.humanize_metadata_value(%{"uuid" => "x", "label" => "Hardware"}) == "Hardware"
    assert Activity.humanize_metadata_value(%{"changed" => true}) == "changed"

    assert Activity.humanize_metadata_value(%{
             "from" => %{"uuid" => "a", "label" => "Hardware"},
             "to" => %{"uuid" => "b", "label" => "Frames"}
           }) == "Hardware → Frames"
  end
end
