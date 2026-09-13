defmodule PhoenixKitCatalogue.Web.HelpersTest do
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Web.Helpers

  describe "status_label/1" do
    test "translates known statuses" do
      assert Helpers.status_label("active") == "Active"
      assert Helpers.status_label("inactive") == "Inactive"
      assert Helpers.status_label("archived") == "Archived"
      assert Helpers.status_label("deleted") == "Deleted"
      assert Helpers.status_label("discontinued") == "Discontinued"
    end

    test "returns the raw key for unknown binaries" do
      # Pinning the do-not-ask rule: never `String.capitalize/1` on
      # translated text. Adding a literal clause to `status_label/1`
      # is the right fix when a new status atom is introduced.
      assert Helpers.status_label("mystery") == "mystery"
    end

    test "returns a translated 'Unknown' for nil / non-binary" do
      assert Helpers.status_label(nil) == "Unknown"
      assert Helpers.status_label(:atom) == "Unknown"
    end
  end

  describe "actor_opts/1" do
    test "returns [actor_uuid: uuid] when current_user is set" do
      socket = %Phoenix.LiveView.Socket{assigns: %{phoenix_kit_current_user: %{uuid: "abc"}}}
      assert Helpers.actor_opts(socket) == [actor_uuid: "abc"]
    end

    test "returns [] when current_user is nil" do
      socket = %Phoenix.LiveView.Socket{assigns: %{phoenix_kit_current_user: nil}}
      assert Helpers.actor_opts(socket) == []
    end

    test "returns [] when current_user is missing entirely" do
      socket = %Phoenix.LiveView.Socket{assigns: %{}}
      assert Helpers.actor_opts(socket) == []
    end
  end

  describe "actor_uuid/1" do
    test "returns the UUID string when current_user is set" do
      socket = %Phoenix.LiveView.Socket{assigns: %{phoenix_kit_current_user: %{uuid: "abc"}}}
      assert Helpers.actor_uuid(socket) == "abc"
    end

    test "returns nil when current_user is missing" do
      socket = %Phoenix.LiveView.Socket{assigns: %{}}
      assert Helpers.actor_uuid(socket) == nil
    end
  end

  describe "trim_param/1 (sweep 2026-09-13)" do
    test "trims a string and neutralises anything else" do
      assert Helpers.trim_param("  x ") == "x"
      assert Helpers.trim_param(nil) == ""
      assert Helpers.trim_param(["a"]) == ""
      assert Helpers.trim_param(%{"a" => 1}) == ""
      assert Helpers.trim_param(7) == ""
    end
  end

  describe "narrow_new_data/2 (sweep 2026-09-13)" do
    test "keeps only the owned data keys on a create payload" do
      params = %{"name" => "x", "data" => %{"meta" => %{}, "_translation_fingerprints" => %{}}}

      assert Helpers.narrow_new_data(params, ["meta"]) == %{
               "name" => "x",
               "data" => %{"meta" => %{}}
             }

      assert Helpers.narrow_new_data(%{"name" => "x"}, ["meta"]) == %{"name" => "x"}
      assert Helpers.narrow_new_data(%{"data" => "junk"}, ["meta"]) == %{"data" => "junk"}
    end
  end
end
