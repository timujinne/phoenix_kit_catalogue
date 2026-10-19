defmodule PhoenixKitCatalogue.Catalogue.AiNotes do
  @moduledoc """
  The "Notes for AI" an item carries, gathered with its surroundings'.

  `ai_notes` is free text on catalogues, categories and items for an AI
  that later reads or analyses the products — one language, never shown
  in the pop-ups, never machine-translated. An AI looking at one item
  usually needs what was said about its catalogue and categories too, so
  `ai_notes_for_item/1` returns them all as structured entries rather than
  one joined string; the caller decides how to format or trim them.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Item

  @typedoc "One level's notes: where they come from and the text."
  @type entry :: %{
          level: :catalogue | :category | :item,
          uuid: Ecto.UUID.t(),
          name: String.t() | nil,
          notes: String.t()
        }

  @doc """
  An item's notes with its catalogue's and every category's above it, from
  the general to the specific: the catalogue, the categories root first,
  then the item. Levels with no notes (nil or blank) are left out, so an
  item with nothing written anywhere returns `[]`. Reads its catalogue and
  categories from the database (soft-deleted ones included — the notes are
  still what was written for them).
  """
  @spec ai_notes_for_item(Item.t()) :: [entry()]
  def ai_notes_for_item(%Item{} = item) do
    catalogue = item.catalogue_uuid && Catalogue.get_catalogue(item.catalogue_uuid)

    categories =
      case item.category_uuid && Catalogue.get_category(item.category_uuid) do
        nil -> []
        category -> Catalogue.list_category_ancestors(category.uuid) ++ [category]
      end

    [entry(:catalogue, catalogue) | Enum.map(categories, &entry(:category, &1))]
    |> Kernel.++([entry(:item, item)])
    |> Enum.reject(&is_nil/1)
  end

  defp entry(_level, nil), do: nil

  defp entry(level, record) do
    case record.ai_notes && String.trim(record.ai_notes) do
      text when is_binary(text) and text != "" ->
        %{level: level, uuid: record.uuid, name: record.name, notes: text}

      _ ->
        nil
    end
  end
end
