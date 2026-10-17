defmodule PhoenixKitCatalogue.API.GetProducts do
  @moduledoc false
  # Tool `catalogue.get_products` (admin API): up to 50 references, one result each.

  alias PhoenixKitCatalogue.API
  alias PhoenixKitCatalogue.API.{Common, Presenter}

  @spec call(map(), map()) :: {:ok, map()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with {:ok, catalogue} <- API.resolve_catalogue(input["catalogue_id"]) do
      fields = input["fields"] || Presenter.default_get_fields()

      resolutions =
        API.resolve_refs(input["refs"],
          kind: :item,
          catalogue_uuid: catalogue.uuid,
          preload: [:category]
        )

      items = for {_ref, {:ok, item}} <- resolutions, do: item
      extras = Presenter.extras(items, fields, ctx)

      rows =
        Enum.map(resolutions, fn
          {ref, {:ok, item}} ->
            Common.row_ok(ref, "found", item.uuid, %{
              "item" => Presenter.item(item, fields, extras)
            })

          {ref, {:error, error}} ->
            Common.resolution_error(ref, error)
        end)

      body = %{"results" => rows, "summary" => Common.summary(rows)}

      {:ok,
       Common.with_warnings(body, Presenter.warnings(fields, extras, is_list(input["fields"])))}
    end
  end
end
