defmodule PhoenixKitCatalogue.Catalogue.SupplierComments do
  @moduledoc """
  Where a supplier's comments about ONE item live.

  A supplier supplies several products, and "he promised a discount on this
  one" is logged as a comment. That note is about the item × supplier
  relation, not about the company — so it is filed under its own
  `phoenix_kit_comments` resource, not the CRM company's thread (the
  company page keeps its own, unrelated comments).

  ## The thread uuid

  A comment thread is addressed by `{resource_type, resource_uuid}`. The
  obvious uuid — the `item_supplier_info` row's — is NOT stable: a price
  revision closes the row and inserts a successor with a new uuid, and
  removing the supplier closes the current row. So each row carries a
  **thread uuid** in `metadata["comment_thread_uuid"]`:

    * minted once, on the pair's first `create/2`;
    * copied to the successor on every `revise_unit_cost/3`;
    * kept when the supplier is removed (the row is closed, not deleted);
    * inherited when the same supplier is attached to the same item again,
      so the discount history resumes rather than starting over.

  The key is server-owned. `create/2` and `update/2` stamp it themselves and
  ignore any value arriving in attrs — an import or a custom-field save can
  neither drop it nor point a row at somebody else's thread. Rows written
  before the key existed use their own uuid as the thread until their first
  write pins it (`thread_uuid/1`).

  ## Back-links

  The central Comments admin and the Activity feed link a comment back to
  its record through a resolver. `PhoenixKitCatalogue.resource_links/0`
  registers this module's (`resolve_resources/1`) for the type, and core
  discovers that callback on its own — no host configuration.
  """

  import Ecto.Query
  require Logger, warn: false

  alias PhoenixKitCatalogue.Catalogue.ItemSupplierInfos
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.ItemSupplierInfo

  @resource_type "catalogue_item_supplier"
  @thread_key "comment_thread_uuid"
  @tab "sourcing"

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "The `phoenix_kit_comments` resource type supplier threads are filed under."
  @spec resource_type() :: String.t()
  def resource_type, do: @resource_type

  @doc "The reserved `metadata` key carrying the thread uuid."
  @spec thread_key() :: String.t()
  def thread_key, do: @thread_key

  @doc """
  The comment thread a supplier row belongs to.

  The stored key when the row carries a valid one; the row's own uuid
  otherwise (rows written before the key existed). Never `nil`.
  """
  @spec thread_uuid(map()) :: Ecto.UUID.t()
  def thread_uuid(%{uuid: uuid} = info) when is_binary(uuid) do
    stored_thread(info) || uuid
  end

  @doc """
  Writes the thread uuid into a metadata map, replacing whatever was there.
  """
  @spec stamp(map() | nil, Ecto.UUID.t()) :: map()
  def stamp(metadata, thread) when is_binary(thread) do
    Map.put(metadata || %{}, @thread_key, thread)
  end

  @doc """
  Stamps the thread onto a changeset's `metadata`, whatever attrs carried.
  """
  @spec stamp_changeset(Ecto.Changeset.t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def stamp_changeset(%Ecto.Changeset{} = changeset, thread) do
    metadata = Ecto.Changeset.get_field(changeset, :metadata)
    Ecto.Changeset.put_change(changeset, :metadata, stamp(metadata, thread))
  end

  @doc """
  The thread an item/supplier pair already has, or `nil` for a pair with no
  history. Newest row first — current, then most recently closed — so the
  thread people last looked at wins; a row without a key stands in with its
  own uuid, the same fallback `thread_uuid/1` applies.
  """
  @spec inherited_thread(Ecto.UUID.t() | nil, Ecto.UUID.t() | nil) :: Ecto.UUID.t() | nil
  def inherited_thread(item_uuid, supplier_uuid)
      when is_binary(item_uuid) and is_binary(supplier_uuid) do
    case ItemSupplierInfos.history_for_pair(item_uuid, supplier_uuid) do
      [] -> nil
      [newest | _] = rows -> Enum.find_value(rows, &stored_thread/1) || newest.uuid
    end
  end

  def inherited_thread(_item_uuid, _supplier_uuid), do: nil

  @doc """
  Back-link resolver for the central Comments admin: thread uuids to
  `%{title, path}` chips. One query; the current row is preferred, a
  closed-only thread (removed supplier) still resolves to its newest row;
  uuids that match nothing are omitted, which the admin renders as a neutral
  chip. Paths are RAW — the comments module applies the URL prefix itself.
  """
  @spec resolve_resources([binary()]) :: %{binary() => %{title: String.t(), path: String.t()}}
  def resolve_resources(uuids) when is_list(uuids) do
    uuids = uuids |> Enum.map(&textual_uuid/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    if uuids == [], do: %{}, else: resolve(uuids)
  rescue
    # The comments admin must render even if this resolver fails; say so
    # in the log instead of silently handing back an empty map.
    error ->
      Logger.warning("catalogue supplier-comment resolver failed: #{inspect(error)}")
      %{}
  end

  defp resolve(uuids) do
    rows =
      from(i in ItemSupplierInfo,
        join: item in assoc(i, :item),
        where:
          i.uuid in ^uuids or
            fragment(
              "(? ->> ?) = ANY(?)",
              i.metadata,
              ^@thread_key,
              type(^uuids, {:array, :string})
            ),
        order_by: [desc_nulls_first: i.valid_to, desc: i.inserted_at, desc: i.uuid],
        select: {i, item.name}
      )
      |> repo().all()

    Enum.reduce(uuids, %{}, fn uuid, acc ->
      case row_for(rows, uuid) do
        nil -> acc
        {info, item_name} -> Map.put(acc, uuid, chip(info, item_name))
      end
    end)
  end

  # Rows arrive current-first, so the first match wins: a thread matching a
  # closed row by uuid (legacy) and the current row by key resolves to the
  # current row.
  defp row_for(rows, uuid) do
    Enum.find(rows, fn {info, _name} -> info.uuid == uuid or thread_uuid(info) == uuid end)
  end

  defp chip(%ItemSupplierInfo{} = info, item_name) do
    supplier = info.supplier_name_snapshot || info.supplier_uuid

    %{
      title: "#{item_name} — #{supplier}",
      path: Paths.item_edit_raw(info.item_uuid, tab: @tab)
    }
  end

  defp stored_thread(%{metadata: %{} = metadata}),
    do: metadata |> Map.get(@thread_key) |> textual_uuid()

  defp stored_thread(_info), do: nil

  # `Ecto.UUID.cast/1` accepts 16-byte binaries as raw uuids, so a stray
  # 16-character string would pass it — insist on the textual form.
  defp textual_uuid(value) when is_binary(value) and byte_size(value) == 36 do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp textual_uuid(_value), do: nil
end
