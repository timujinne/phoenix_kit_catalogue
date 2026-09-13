defmodule PhoenixKitCatalogue.Catalogue.SlugsTest do
  @moduledoc """
  Unit tests for `PhoenixKitCatalogue.Catalogue.Slugs` (Block 1, Task 2):
  the `from_title/3` generation rule and `maybe_generate/3`'s per-language
  fill, including its language-key filter (namespaces like `"meta"` and
  an extension's `data["ecommerce"]` must never be treated as languages).
  """
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Catalogue.Slugs
  alias PhoenixKitCatalogue.Schemas.Item

  describe "from_title/3" do
    test "uses the head segment before a pipe" do
      assert Slugs.from_title("Étagère Murale | Étagères Imprimées", "fr-FR") ==
               "etagere-murale"
    end

    test "uses the head segment before a spaced dash" do
      assert Slugs.from_title("Vase en Bois - Édition Limitée", "fr-FR") == "vase-en-bois"
    end

    test "caps at 60 characters on a word boundary" do
      title = Enum.map_join(1..10, " ", &"wordword#{&1}")
      slug = Slugs.from_title(title, "en-US")

      # Pinned to the exact expected cut (not just "<= 60"): the 60-char
      # hard cut lands mid-word inside "wordword7", so the word boundary
      # rule drops it, leaving 6 whole words. A weaker `@max_len` (or one
      # that stopped enforcing the cap) would produce a different exact
      # string here without necessarily violating a looser assertion.
      assert slug == "wordword1-wordword2-wordword3-wordword4-wordword5-wordword6"
      assert String.length(slug) == 59
      refute String.ends_with?(slug, "-")
    end

    test "an unromanizable title falls back to a stable item-<hash> slug" do
      assert Slugs.from_title("測試", "fr-FR") == "item-" <> hash("測試")
    end

    test "the identity tail is NOT carried when the title falls back to the hash" do
      slug = Slugs.from_title("測試", "fr-FR", default_slug: "wooden-vase-22153")

      refute slug =~ "22153"
      assert slug == "item-" <> hash("測試")
    end

    test "a numeric identity tail is carried from the default slug" do
      assert Slugs.from_title("Vase en Bois", "fr-FR", default_slug: "wooden-vase-22153") ==
               "vase-en-bois-22153"
    end

    test "the tail is not duplicated when the derived slug already ends with it" do
      assert Slugs.from_title("Vase en Bois 22153", "fr-FR", default_slug: "wooden-vase-22153") ==
               "vase-en-bois-22153"
    end

    test "no tail is carried when the default slug has none" do
      assert Slugs.from_title("Vase en Bois", "fr-FR", default_slug: "wooden-vase") ==
               "vase-en-bois"
    end

    defp hash(text) do
      :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    end
  end

  describe "unique/3" do
    test "returns the base when free, else the first free numbered suffix" do
      assert Slugs.unique("vase", "en-US", fn _, _ -> false end) == "vase"

      taken = MapSet.new(["vase", "vase-2"])
      assert Slugs.unique("vase", "en-US", fn c, _ -> MapSet.member?(taken, c) end) == "vase-3"
    end

    test "probes in the language it generates for" do
      assert Slugs.unique("vase", "fr-FR", fn
               "vase", "fr-FR" -> true
               _, _ -> false
             end) == "vase-2"
    end
  end

  describe "maybe_generate/3" do
    test "suffixes a generated slug the probe reports taken, leaving typed ones alone" do
      changeset =
        %Item{}
        |> Ecto.Changeset.change(%{
          name: "Wooden Vase",
          slug: %{"en-US" => "wooden-vase"},
          data: %{
            "_primary_language" => "en-US",
            "en-US" => %{"_name" => "Wooden Vase"},
            "fr-FR" => %{"_name" => "Vase en Bois"}
          }
        })

      taken? = fn candidate, _lang -> candidate in ["wooden-vase", "vase-en-bois"] end
      updated = Slugs.maybe_generate(changeset, :slug, from: :name, taken?: taken?)
      slug = Ecto.Changeset.get_field(updated, :slug)

      # The existing en-US slug is the record's own — write-once, not probed.
      assert slug["en-US"] == "wooden-vase"
      assert slug["fr-FR"] == "vase-en-bois-2"
    end

    test "fills a missing language from the multilang name and keeps an existing one" do
      changeset =
        %Item{}
        |> Ecto.Changeset.change(%{
          name: "Wooden Vase",
          slug: %{"en-US" => "wooden-vase"},
          data: %{
            "_primary_language" => "en-US",
            "en-US" => %{"_name" => "Wooden Vase"},
            "fr-FR" => %{"_name" => "Vase en Bois"}
          }
        })

      updated = Slugs.maybe_generate(changeset, :slug, from: :name)
      slug = Ecto.Changeset.get_field(updated, :slug)

      assert slug["en-US"] == "wooden-vase"
      assert slug["fr-FR"] == "vase-en-bois"
    end

    test "carries the primary language's identity tail onto a generated secondary slug" do
      changeset =
        %Item{}
        |> Ecto.Changeset.change(%{
          name: "Wooden Vase",
          slug: %{"en-US" => "wooden-vase-22153"},
          data: %{
            "_primary_language" => "en-US",
            "en-US" => %{"_name" => "Wooden Vase"},
            "fr-FR" => %{"_name" => "Vase en Bois"}
          }
        })

      updated = Slugs.maybe_generate(changeset, :slug, from: :name)
      slug = Ecto.Changeset.get_field(updated, :slug)

      assert slug["fr-FR"] == "vase-en-bois-22153"
    end

    test "does nothing when every present language already has a slug" do
      changeset =
        %Item{}
        |> Ecto.Changeset.change(%{
          name: "Wooden Vase",
          slug: %{"en-US" => "wooden-vase"},
          data: %{"_primary_language" => "en-US", "en-US" => %{"_name" => "Wooden Vase"}}
        })

      updated = Slugs.maybe_generate(changeset, :slug, from: :name)

      assert updated == changeset
    end

    test "does nothing when the derivable title is blank" do
      changeset =
        %Item{}
        |> Ecto.Changeset.change(%{
          name: nil,
          slug: %{},
          data: %{"_primary_language" => "en-US", "en-US" => %{}}
        })

      updated = Slugs.maybe_generate(changeset, :slug, from: :name)

      assert Ecto.Changeset.get_field(updated, :slug) == %{}
    end

    test "fills only the two real languages, ignoring the meta and ecommerce data namespaces" do
      changeset =
        %Item{}
        |> Ecto.Changeset.change(%{
          name: "Wooden Vase",
          slug: %{},
          data: %{
            "_primary_language" => "en-US",
            "en-US" => %{"_name" => "Wooden Vase"},
            "fr-FR" => %{"_name" => "Vase en Bois"},
            "meta" => %{"brand" => "Acme"},
            "ecommerce" => %{"shop_status" => "active"}
          }
        })

      updated = Slugs.maybe_generate(changeset, :slug, from: :name)
      slug = Ecto.Changeset.get_field(updated, :slug)

      assert Map.keys(slug) |> Enum.sort() == ["en-US", "fr-FR"]
      assert slug["en-US"] == "wooden-vase"
      assert slug["fr-FR"] == "vase-en-bois"
    end

    test "fills the primary language from the plain name on non-multilang (flat) data" do
      changeset =
        %Item{}
        |> Ecto.Changeset.change(%{
          name: "Wooden Vase",
          slug: %{},
          data: %{"legacy_key" => "unrelated"}
        })

      updated = Slugs.maybe_generate(changeset, :slug, from: :name)
      slug = Ecto.Changeset.get_field(updated, :slug)

      assert slug == %{"en-US" => "wooden-vase"}
    end
  end
end
