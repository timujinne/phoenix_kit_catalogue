defmodule PhoenixKitCatalogue.Test.MediaFixtures do
  @moduledoc """
  Media-folder fixtures for the tests that check where a record's folder sits:
  a user and a file to attach, and the readers for an item's folder pointer
  and the folder's path from the root.
  """

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Test.Repo

  @doc "Inserts a user row (a file or a folder needs an owner) and returns its uuid."
  def insert_user!(user_uuid \\ UUIDv7.generate()) do
    SQL.query!(
      Repo,
      """
      INSERT INTO phoenix_kit_users
        (uuid, email, hashed_password, account_type, is_active, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'person', true, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(user_uuid),
        "media-fixtures-#{System.unique_integer([:positive])}@example.com",
        "$2b$12$0000000000000000000000000000000000000000000000000000."
      ]
    )

    user_uuid
  end

  @doc "Inserts a file row owned by `user_uuid` and returns its uuid."
  def insert_file!(user_uuid) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    uuid = UUIDv7.generate()

    Repo.insert!(%StorageFile{
      uuid: uuid,
      original_file_name: "photo.jpg",
      file_name: "photo.jpg",
      mime_type: "image/jpeg",
      file_type: "image",
      ext: "jpg",
      file_checksum: "chk-#{uuid}",
      user_file_checksum: "uchk-#{uuid}",
      size: 1,
      status: "active",
      system_managed: false,
      user_uuid: user_uuid,
      inserted_at: now,
      updated_at: now
    })

    uuid
  end

  @doc "Attaches a file to `record`, which gives it its folder; returns the updated record."
  def with_folder!(record, user_uuid) do
    {:ok, updated} = Attachments.attach_files(record, [insert_file!(user_uuid)])
    updated
  end

  @doc "The uuid of the folder a record points to, or nil."
  def pointer(%{data: data}) when is_map(data), do: data["files_folder_uuid"]
  def pointer(_record), do: nil

  @doc "The folder names from the root down to `folder_uuid`."
  def path(nil), do: nil
  def path(folder_uuid), do: folder_uuid |> ancestry([]) |> Enum.map(& &1.name)

  defp ancestry(nil, acc), do: acc

  # A folder cycle must fail the test, not hang it.
  defp ancestry(_folder_uuid, acc) when length(acc) > 20,
    do: raise("the folder tree loops: #{inspect(Enum.map(acc, & &1.name))}")

  defp ancestry(folder_uuid, acc) do
    folder = Storage.get_folder(folder_uuid)
    ancestry(folder.parent_uuid, [folder | acc])
  end
end
