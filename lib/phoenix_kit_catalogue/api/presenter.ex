defmodule PhoenixKitCatalogue.API.Presenter do
  @moduledoc false
  # Items and categories as JSON-ready maps with string keys. The catalogue
  # tools never expose the shop price columns (`base_price`, markup, discount):
  # in the catalogue source `base_price` IS the shop price and is written and
  # read by the e-commerce tools.

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.API.{Attributes, Refs}
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Catalogue.Translations
  alias PhoenixKitCatalogue.Schemas.{Category, Item}

  @item_fields ~w(id catalogue_id category_id category external_id sku name description status unit item_type slug position attributes images translations shop created_at updated_at)
  @list_fields ~w(id external_id sku name status category_id updated_at)
  # Sync bookkeeping inside data["ecommerce"], not product data.
  @hidden_shop_keys ~w(cost_per_item shopify translation_fingerprints)
  @shop_scope "ecommerce.prices:read"
  # The `xx-YY` shape of a language code; the other map-valued keys of `data`
  # are namespaces ("api", "ecommerce", "meta") and must never read as one.
  @language_code ~r/^[a-z]{2}-[A-Z]{2}$/

  def item_fields, do: @item_fields
  def default_list_fields, do: @list_fields
  def default_get_fields, do: @item_fields
  def shop_scope, do: @shop_scope

  @doc """
  What the field builders need beyond the items themselves, fetched in batch
  and only for the fields asked for: attribute cards, images, and whether the
  key may see shop fields.
  """
  @spec extras([Item.t()], [String.t()], map()) :: map()
  def extras(items, fields, ctx) do
    %{
      attributes:
        if("attributes" in fields,
          do: Attributes.for_items(Enum.map(items, & &1.uuid)),
          else: %{}
        ),
      images: if("images" in fields, do: images(items, ctx), else: %{}),
      shop?: @shop_scope in ctx.scopes
    }
  end

  @doc "A warning when `shop` was asked for explicitly and the key may not see it."
  @spec warnings([String.t()], map(), boolean()) :: [map()]
  def warnings(fields, extras, explicit?) do
    if explicit? and "shop" in fields and not extras.shop? do
      [
        %{
          "code" => "fields_not_available",
          "message" => "The shop field needs the scope #{@shop_scope}; it was left out.",
          "fields" => ["shop"]
        }
      ]
    else
      []
    end
  end

  @spec item(Item.t(), [String.t()], map()) :: map()
  def item(%Item{} = item, fields, extras \\ %{}) do
    Enum.reduce(fields, %{}, fn field, acc ->
      case value(field, item, extras) do
        :skip -> acc
        value -> Map.put(acc, field, value)
      end
    end)
  end

  defp value("id", i, _), do: i.uuid
  defp value("catalogue_id", i, _), do: i.catalogue_uuid
  defp value("category_id", i, _), do: i.category_uuid
  defp value("category", %{category: %Category{} = c}, _), do: %{"id" => c.uuid, "name" => c.name}
  defp value("category", _item, _), do: nil
  defp value("external_id", i, _), do: Refs.external_id(i)
  defp value("sku", i, _), do: i.sku
  defp value("name", i, _), do: i.name
  defp value("description", i, _), do: i.description
  defp value("status", i, _), do: i.status
  defp value("unit", i, _), do: i.unit
  defp value("item_type", i, _), do: i.item_type
  defp value("slug", i, _), do: i.slug || %{}
  defp value("position", i, _), do: i.position
  defp value("created_at", i, _), do: iso(i.inserted_at)
  defp value("updated_at", i, _), do: iso(i.updated_at)

  defp value("attributes", i, extras),
    do: extras |> Map.get(:attributes, %{}) |> Map.get(i.uuid, [])

  defp value("images", i, extras), do: extras |> Map.get(:images, %{}) |> Map.get(i.uuid, [])
  defp value("translations", i, _), do: translations(i)
  defp value("shop", i, %{shop?: true}), do: shop(i)
  defp value(_other, _item, _extras), do: :skip

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(%NaiveDateTime{} = at), do: NaiveDateTime.to_iso8601(at) <> "Z"
  defp iso(_other), do: nil

  # data["ecommerce"] without the sync bookkeeping; absent -> %{}.
  defp shop(%Item{data: %{"ecommerce" => %{} = ecommerce}}),
    do: Map.drop(ecommerce, @hidden_shop_keys)

  defp shop(_item), do: %{}

  @doc "The language codes that have a bucket in `data` (`xx-YY` shaped or enabled)."
  @spec bucket_languages(map() | nil) :: [String.t()]
  def bucket_languages(data) when is_map(data) do
    enabled = Multilang.enabled_languages()

    for {key, %{}} <- data, is_binary(key), key in enabled or key =~ @language_code, do: key
  end

  def bucket_languages(_data), do: []

  defp translations(%Item{} = item) do
    data = item.data || %{}
    primary = Map.get(data, "_primary_language") || Multilang.primary_language()
    slugs = item.slug || %{}

    ([primary] ++ bucket_languages(data) ++ Map.keys(slugs))
    |> Enum.uniq()
    |> Map.new(fn lang -> {lang, translation(item, data, lang, primary, slugs)} end)
  end

  defp translation(item, data, lang, primary, slugs) do
    bucket =
      case Map.get(data, lang) do
        %{} = bucket -> bucket
        _other -> %{}
      end

    # The primary language lives in the columns; every other language in its bucket.
    base =
      if lang == primary,
        do: %{"name" => item.name, "description" => item.description},
        else: %{"name" => bucket["_name"], "description" => bucket["_description"]}

    base
    |> Map.merge(%{
      "seo_title" => bucket["_seo_title"],
      "seo_description" => bucket["_seo_description"],
      "slug" => Map.get(slugs, lang)
    })
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc "A category as a map; `names` holds the name per language that has one."
  @spec category(Category.t()) :: map()
  def category(%Category{} = category) do
    data = category.data || %{}
    primary = Map.get(data, "_primary_language") || Multilang.primary_language()

    names =
      ([primary] ++ bucket_languages(data))
      |> Enum.uniq()
      |> Map.new(fn lang -> {lang, Translations.translated_name(category, lang)} end)

    %{
      "id" => category.uuid,
      "catalogue_id" => category.catalogue_uuid,
      "parent_id" => category.parent_uuid,
      "external_id" => Refs.external_id(category),
      "name" => category.name,
      "names" => names,
      "position" => category.position,
      "status" => category.status
    }
  end

  # --- images -----------------------------------------------------------------------

  defp images(items, ctx), do: Map.new(items, &{&1.uuid, item_images(&1, ctx)})

  # The files of the item's media folder, in the editor's order, the featured
  # one first.
  defp item_images(%Item{data: data}, ctx) do
    data = data || %{}

    case data["files_folder_uuid"] do
      folder when is_binary(folder) ->
        featured = data["featured_image_uuid"]

        folder
        |> Attachments.list_folder_files(only: :images)
        |> Attachments.apply_media_order(data["media_order"])
        |> Enum.map(&image(&1, featured, ctx))
        |> Enum.sort_by(&(not &1["featured"]))

      _none ->
        []
    end
  end

  defp image(file, featured, ctx) do
    %{
      "id" => file.uuid,
      "name" => file.original_file_name,
      "featured" => file.uuid == featured,
      "url" => absolute(URLSigner.signed_url(file.uuid, "original"), ctx.base_url)
    }
  end

  defp absolute("/" <> _ = path, base_url) when is_binary(base_url), do: base_url <> path
  defp absolute(url, _base_url), do: url
end
