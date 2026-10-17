defmodule PhoenixKitCatalogue.API.DeleteProducts do
  @moduledoc false
  # Tool `catalogue.delete_products`: trash, never delete.

  alias PhoenixKitCatalogue.API
  alias PhoenixKitCatalogue.API.Common
  alias PhoenixKitCatalogue.Catalogue

  @tool "catalogue.delete_products"

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with {:ok, catalogue} <- API.resolve_catalogue(input["catalogue_id"], writable: true) do
      resolutions = API.resolve_refs(input["refs"], kind: :item, catalogue_uuid: catalogue.uuid)
      plan = plan(resolutions, catalogue)

      if ctx.dry_run?, do: preview(plan), else: execute(plan, catalogue, ctx)
    end
  end

  # --- planning (reads only) ---------------------------------------------------------

  defp plan(resolutions, catalogue), do: Common.removal_plan(resolutions, catalogue, :item)

  # --- dry run -------------------------------------------------------------------------

  defp preview(plan) do
    plan
    |> Enum.map(fn
      {:remove, ref, item} ->
        Common.row_ok(ref, "removed", item.uuid, %{
          "name" => item.name,
          "changes" => %{"status" => %{"from" => item.status, "to" => "deleted"}}
        })

      other ->
        Common.removal_row(other)
    end)
    |> Common.preview(%{"requires_confirmation" => true})
  end

  # --- execution -------------------------------------------------------------------------

  defp execute(plan, catalogue, ctx) do
    opts = Common.write_opts(ctx, @tool, broadcast: false)

    rows =
      Enum.map(plan, fn
        {:remove, ref, item} -> trash(ref, item, opts)
        other -> Common.removal_row(other)
      end)

    removed = for %{"action" => "removed", "id" => id} <- rows, do: id
    Catalogue.broadcast_item_batch_change(catalogue.uuid, :trashed, removed)

    Common.batch_result(rows)
  end

  defp trash(ref, item, opts) do
    case Catalogue.trash_item_outcome(item, opts) do
      {:ok, :trashed, _trashed} ->
        Common.row_ok(ref, "removed", item.uuid)

      # Someone else trashed it after the request was planned.
      {:ok, :already_trashed, _trashed} ->
        Common.row_ok(ref, "unchanged", item.uuid)

      {:error, :not_found} ->
        Common.row_error(ref, :not_found, "The item no longer exists.")

      {:error, _reason} ->
        Common.row_error(ref, :internal_error, "The item could not be moved to the trash.")
    end
  end
end
