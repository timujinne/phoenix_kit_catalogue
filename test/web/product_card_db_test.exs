defmodule PhoenixKitCatalogue.Web.Components.ProductCardDBTest do
  @moduledoc """
  DB-backed tests for `ProductCard.resolve_images/1`: the folder image
  listing (exercising the real `Storage.list_files_in_scope/2` signature so a
  rescue can't silently mask a wrong call) and the broken/trashed featured
  filtering.
  """
  use PhoenixKitCatalogue.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Web.Components.ProductCard

  defp create_folder(user_uuid) do
    {:ok, folder} =
      Storage.create_folder(%{
        name: "pc-folder-#{System.unique_integer([:positive])}",
        user_uuid: user_uuid
      })

    folder.uuid
  end

  setup do
    # Files carry a CHECK (user_uuid OR parent_file_uuid); give them an owner.
    user_uuid = UUIDv7.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO phoenix_kit_users
        (uuid, email, hashed_password, account_type, is_active, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'person', true, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(user_uuid),
        "pc-db-#{System.unique_integer([:positive])}@example.com",
        "$2b$12$0000000000000000000000000000000000000000000000000000."
      ]
    )

    {:ok, user_uuid: user_uuid}
  end

  defp insert_image(user_uuid, folder_uuid, name, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    uuid = UUIDv7.generate()

    Repo.insert!(%StorageFile{
      uuid: uuid,
      original_file_name: name,
      file_name: name,
      mime_type: Keyword.get(opts, :mime_type, "image/jpeg"),
      file_type: Keyword.get(opts, :file_type, "image"),
      ext: Keyword.get(opts, :ext, "jpg"),
      file_checksum: "chk-#{uuid}",
      user_file_checksum: "uchk-#{uuid}",
      size: 1,
      status: Keyword.get(opts, :status, "active"),
      system_managed: Keyword.get(opts, :system_managed, false),
      user_uuid: user_uuid,
      folder_uuid: folder_uuid,
      inserted_at: now,
      updated_at: now
    })

    uuid
  end

  test "lists the folder's live images, featured first, excluding trashed + non-image", %{
    user_uuid: user
  } do
    folder = create_folder(user)
    featured = insert_image(user, folder, "main.jpg", [])
    other = insert_image(user, folder, "other.jpg", [])
    _trashed = insert_image(user, folder, "gone.jpg", status: "trashed")
    _document = insert_image(user, folder, "doc.pdf", file_type: "document")

    item = %Item{data: %{"featured_image_uuid" => featured, "files_folder_uuid" => folder}}

    images = ProductCard.resolve_images(item)
    uuids = Enum.map(images, & &1.uuid)

    # Featured comes first; the other live image is present; trashed + the
    # non-image are excluded; featured is not duplicated.
    assert hd(uuids) == featured
    assert other in uuids
    assert length(images) == 2
  end

  test "drops a featured pointer whose file no longer exists (no broken image)" do
    item = %Item{data: %{"featured_image_uuid" => UUIDv7.generate()}}

    assert ProductCard.resolve_images(item) == []
  end

  test "drops a trashed featured image", %{user_uuid: user} do
    folder = create_folder(user)
    featured = insert_image(user, folder, "trashed.jpg", status: "trashed")

    item = %Item{data: %{"featured_image_uuid" => featured}}

    assert ProductCard.resolve_images(item) == []
  end

  test "resolve_files lists live non-image files with the pdf flag", %{user_uuid: user} do
    folder = create_folder(user)
    _image = insert_image(user, folder, "photo.jpg", [])
    pdf = insert_image(user, folder, "spec.pdf", file_type: "document", ext: "pdf")
    doc = insert_image(user, folder, "notes.txt", file_type: "document", ext: "txt")
    _trashed = insert_image(user, folder, "old.pdf", file_type: "document", status: "trashed")

    item = %Item{data: %{"files_folder_uuid" => folder}}

    files = ProductCard.resolve_files(item)
    by_uuid = Map.new(files, &{&1.uuid, &1})

    assert map_size(by_uuid) == 2
    assert by_uuid[pdf].pdf?
    refute by_uuid[doc].pdf?
  end

  test "attached_file_counts batches per-resource document counts", %{user_uuid: user} do
    alias PhoenixKitCatalogue.Catalogue

    folder_a = create_folder(user)
    folder_b = create_folder(user)
    _pdf1 = insert_image(user, folder_a, "a1.pdf", file_type: "document", ext: "pdf")
    _pdf2 = insert_image(user, folder_a, "a2.pdf", file_type: "document", ext: "pdf")
    # Images and trashed files must not count as attached documents.
    _image = insert_image(user, folder_b, "b.jpg", [])
    _gone = insert_image(user, folder_b, "b.pdf", file_type: "document", status: "trashed")

    item_a = %Item{uuid: UUIDv7.generate(), data: %{"files_folder_uuid" => folder_a}}
    item_b = %Item{uuid: UUIDv7.generate(), data: %{"files_folder_uuid" => folder_b}}
    item_c = %Item{uuid: UUIDv7.generate(), data: %{}}

    counts = Catalogue.attached_file_counts([item_a, item_b, item_c])

    assert counts[item_a.uuid] == 2
    refute Map.has_key?(counts, item_b.uuid)
    refute Map.has_key?(counts, item_c.uuid)

    # Row maps (the catalogues index shape) work the same way.
    row = %{uuid: item_a.uuid, data: %{"files_folder_uuid" => folder_a}}
    assert Catalogue.attached_file_counts([row])[item_a.uuid] == 2

    assert Catalogue.attached_file_counts([]) == %{}
  end

  describe "folder-linked files (the content-duplicate upload shape, 2026-09-12)" do
    # Storage de-duplicates uploads per user by content: a second upload
    # of a byte-identical file returns the record the first created, and
    # Attachments links it into the new folder via FolderLink instead of
    # moving it. The item form always listed home + linked files; the
    # card and the paperclip count read the home folder only, so a file
    # the editor showed was missing everywhere else (client: "uploaded
    # three PDFs, two show, one does not").
    alias PhoenixKit.Modules.Storage.FolderLink
    alias PhoenixKitCatalogue.Attachments
    alias PhoenixKitCatalogue.Catalogue

    defp link!(file_uuid, folder_uuid) do
      Repo.insert!(
        FolderLink.changeset(%FolderLink{}, %{folder_uuid: folder_uuid, file_uuid: file_uuid})
      )
    end

    test "a linked PDF is listed by the form, the card and the paperclip count alike", %{
      user_uuid: user
    } do
      home = create_folder(user)
      other = create_folder(user)
      own = insert_image(user, home, "own.pdf", file_type: "document", ext: "pdf")
      linked = insert_image(user, other, "shared.pdf", file_type: "document", ext: "pdf")
      link!(linked, home)

      item = %Item{uuid: UUIDv7.generate(), data: %{"files_folder_uuid" => home}}

      form = home |> Attachments.list_folder_files() |> Enum.map(& &1.uuid) |> Enum.sort()
      card = item |> ProductCard.resolve_files() |> Enum.map(& &1.uuid) |> Enum.sort()

      assert form == Enum.sort([own, linked])
      assert card == form
      assert Catalogue.attached_file_counts([item])[item.uuid] == 2
    end

    test "a link row naming the file's own home folder counts it once", %{user_uuid: user} do
      # A file linked into a folder and later re-homed there (the media
      # manager moves the row, the link stays) is read once by the
      # listing's `home OR linked`; the paperclip must agree, not say 2.
      home = create_folder(user)
      pdf = insert_image(user, home, "spec.pdf", file_type: "document", ext: "pdf")
      link!(pdf, home)

      item = %Item{uuid: UUIDv7.generate(), data: %{"files_folder_uuid" => home}}

      assert item |> ProductCard.resolve_files() |> Enum.map(& &1.uuid) == [pdf]
      assert Catalogue.attached_file_counts([item])[item.uuid] == 1
    end

    test "the card's documents survive the grid cap: the type filter runs in SQL", %{
      user_uuid: user
    } do
      # Codex, 2026-09-12: 200 images then one PDF — filtering images
      # after the 200-row cap dropped the PDF while the paperclip said 1.
      home = create_folder(user)
      for n <- 1..201, do: insert_image(user, home, "img#{n}.jpg", [])
      pdf = insert_image(user, home, "late.pdf", file_type: "document", ext: "pdf")
      item = %Item{uuid: UUIDv7.generate(), data: %{"files_folder_uuid" => home}}

      assert item |> ProductCard.resolve_files() |> Enum.map(& &1.uuid) == [pdf]
      assert Catalogue.attached_file_counts([item])[item.uuid] == 1
    end

    test "a linked image joins the card's gallery; trashed and system-managed links do not", %{
      user_uuid: user
    } do
      home = create_folder(user)
      other = create_folder(user)
      linked_image = insert_image(user, other, "shared.jpg", [])
      trashed = insert_image(user, other, "gone.jpg", status: "trashed")
      managed = insert_image(user, other, "thumb.jpg", system_managed: true)
      link!(linked_image, home)
      link!(trashed, home)
      link!(managed, home)

      item = %Item{uuid: UUIDv7.generate(), data: %{"files_folder_uuid" => home}}

      assert item |> ProductCard.resolve_images() |> Enum.map(& &1.uuid) == [linked_image]
    end
  end

  describe "build_fields/2 attribute rows" do
    defp item_with_group do
      {:ok, cat} =
        Catalogue.create_catalogue(%{name: "Cat #{System.unique_integer([:positive])}"})

      {:ok, item} = Catalogue.create_item(%{name: "Door", catalogue_uuid: cat.uuid})
      {:ok, group} = Catalogue.create_attribute_group(%{name: "Idea doors"})
      {:ok, attribute} = Catalogue.create_attribute(group, %{"name" => "Color"})
      {:ok, _} = Catalogue.create_attribute_value(attribute, %{"value" => "White"})
      {:ok, _} = Catalogue.create_attribute_value(attribute, %{"value" => "Oak"})
      {item, group, attribute}
    end

    test "appends one row per attribute with comma-joined values" do
      {item, group, _attribute} = item_with_group()
      {:ok, :assigned} = Catalogue.set_item_attribute_group(item, group.uuid)

      fields = ProductCard.build_fields(item, "en")
      assert {"Color", "White, Oak"} in fields
    end

    test "a selected value archived after being picked is marked archived" do
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

      {:ok, cat} =
        Catalogue.create_catalogue(%{name: "Cat #{System.unique_integer([:positive])}"})

      {:ok, item} = Catalogue.create_item(%{name: "Door", catalogue_uuid: cat.uuid})

      {:ok, set} =
        Catalogue.create_attribute_set(%{name: "Finish #{System.unique_integer([:positive])}"})

      {:ok, gold} = Catalogue.create_attribute_set_value(set, %{label: "Gold"})
      {:ok, silver} = Catalogue.create_attribute_set_value(set, %{label: "Silver"})
      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)

      :ok =
        AttributeSets.set_attachment_selection(
          item.uuid,
          set.uuid,
          [gold.slug, silver.slug]
        )

      {:ok, _} =
        PhoenixKitEntities.EntityData.update(gold, %{status: "archived"}, activity_log: false)

      {_label, value} =
        item
        |> ProductCard.build_fields("en")
        |> Enum.find(fn {_label, value} -> is_binary(value) and value =~ "Gold" end)

      assert value |> String.split(", ") |> Enum.sort() == ["Gold (archived)", "Silver"]
    end

    test "no assignment, no attribute rows" do
      {item, _group, _attribute} = item_with_group()
      fields = ProductCard.build_fields(item, "en")
      refute Enum.any?(fields, fn {label, _} -> label == "Color" end)
    end

    test "rows come back translated for the card's locale" do
      {item, group, attribute} = item_with_group()
      {:ok, :assigned} = Catalogue.set_item_attribute_group(item, group.uuid)

      {:ok, _} =
        Catalogue.set_translation(
          attribute,
          "ru",
          %{"_name" => "Цвет"},
          &Catalogue.update_attribute/2
        )

      fields = ProductCard.build_fields(item, "ru")
      assert Enum.any?(fields, fn {label, _} -> label == "Цвет" end)
    end
  end
end
