defmodule PhoenixKitCatalogue.MediaReorganizer do
  @moduledoc """
  Catalogue's media-reorganizer plan source: the `catalogue-<uuid>`,
  `catalogue-category-<uuid>` and `catalogue-item-<uuid>` folders, planned by
  core's `PhoenixKit.Modules.Storage.Reorganizer.ResourceSource`, which
  applies the `Reorganizer.Source` contract.

  What is catalogue's own: a record is live until deleted (its folder is
  then an orphan); each stores its folder pointer in
  `data["files_folder_uuid"]`, so moves back-fill it and a taken target is
  renamed `"name (N)"`; the parent and name hooks receive the record
  itself; catalogues move before their categories, categories before their
  items; uploads for an unsaved record wait in
  `catalogue-attachment-pending-*` folders; and one report of its own — PDFs
  still at the storage root while the host names a library folder (`:pdf`
  hook). PDFs are files, not folders, so they are only reported.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Storage.Reorganizer.ResourceSource
  alias PhoenixKit.Modules.Storage.ResourceFolders
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item, Pdf}

  @pointer {:data, "files_folder_uuid"}

  @doc "The plan (`Reorganizer.Source.plan/2`); `opts` takes `:pending_days`."
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []), do: ResourceSource.plan(spec(), actor_uuid, opts)

  defp spec do
    %{
      source: "catalogue",
      app: :phoenix_kit_catalogue,
      pending_prefix: "catalogue-attachment-pending-",
      kinds: [
        kind(:catalogue, Catalogue, "catalogue-", []),
        kind(:category, Category, "catalogue-category-", [:catalogue_uuid]),
        kind(:item, Item, "catalogue-item-", [:catalogue_uuid, :category_uuid])
      ],
      extra: &pdf_report/2
    }
  end

  defp kind(kind, schema, prefix, fields),
    do: %{
      kind: kind,
      schema: schema,
      prefix: prefix,
      pointer: @pointer,
      fields: fields,
      live: &live/1
    }

  defp live(query), do: where(query, [r], r.status != "deleted")

  # Live PDFs still at the storage root while the host names a library
  # folder: one report, so a person can file them. The `:pdf` hook is only
  # asked when there is a PDF to report; a hook that is not configured or
  # not callable is already the plan's own `:hook_error`.
  defp pdf_report(actor_uuid, _opts) do
    case root_pdf_count() do
      0 ->
        []

      count ->
        pdf_actions(
          ResourceFolders.parent_hook(:phoenix_kit_catalogue, :pdf, actor_uuid, :pdf),
          count
        )
    end
  end

  defp pdf_actions({:ok, folder_uuid}, count) when is_binary(folder_uuid) do
    [
      %{
        source: "catalogue",
        kind: :pdf,
        label: "PDF library",
        op: :report,
        counts: {count, 0},
        reason: "#{count} PDF(s) at the storage root; library folder #{folder_uuid}"
      }
    ]
  end

  defp pdf_actions({:error, {:not_exported, _}}, _count), do: []
  defp pdf_actions({:error, {:bad_config, _}}, _count), do: []

  defp pdf_actions({:error, _reason}, count) do
    [
      %{
        source: "catalogue",
        kind: :hook_error,
        op: :report,
        label: "attachments :pdf hook",
        counts: nil,
        reason:
          "the configured :pdf attachments hook raised, exited, or is not callable — " <>
            "#{count} PDF(s) at the storage root not reported"
      }
    ]
  end

  defp pdf_actions(_root_or_unconfigured, _count), do: []

  defp root_pdf_count do
    Pdf
    |> join(:inner, [p], f in PhoenixKit.Modules.Storage.File, on: f.uuid == p.file_uuid)
    |> where([p, f], p.status == "active" and f.status != "trashed" and is_nil(f.folder_uuid))
    |> PhoenixKit.RepoHelper.repo().aggregate(:count)
  end
end
