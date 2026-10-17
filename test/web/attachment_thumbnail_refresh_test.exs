defmodule PhoenixKitCatalogue.Web.AttachmentThumbnailRefreshTest do
  @moduledoc """
  A just-uploaded image is asked for as a thumbnail before core's
  `ProcessFileJob` has written the `thumbnail` instance, so the browser is
  answered the grey placeholder — and, the `src` never changing, never asks
  again. The forms listen for `{:phoenix_kit_file_processed, uuid}` and, once
  the instance exists, re-render the thumbnail with its content version
  (`?v=`), a different URL, so the browser fetches the real image.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Test.Repo

  @base "/en/admin/catalogues"
  @checksum "0123456789abcdef0123456789abcdef"

  setup %{scope: scope} do
    catalogue = fixture_catalogue(%{name: "Thumb Range"})
    item = fixture_item(%{name: "Thumb Item", catalogue_uuid: catalogue.uuid})
    %{catalogue: catalogue, item: item, user_uuid: scope.user.uuid}
  end

  defp insert_file!(user_uuid, name) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    uuid = UUIDv7.generate()

    Repo.insert!(%StorageFile{
      uuid: uuid,
      original_file_name: name,
      file_name: name,
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

  defp make_thumbnail!(file_uuid, checksum \\ @checksum) do
    {:ok, instance} =
      Storage.create_file_instance(%{
        file_uuid: file_uuid,
        variant_name: "thumbnail",
        file_name: "thumb-#{file_uuid}.jpg",
        mime_type: "image/jpeg",
        ext: "jpg",
        checksum: checksum,
        size: 10
      })

    instance
  end

  defp open(conn, scope, item),
    do: conn |> with_scope(scope) |> live("#{@base}/items/#{item.uuid}/edit")

  # Every distinct `src` the page renders for `uuid`'s thumbnail. The
  # first attached image is also the featured one, so the card and the
  # grid both show it: one entry means they agree.
  defp thumb_srcs(html, uuid) do
    ~r|src="([^"]*/file/#{uuid}/thumbnail/[^"]*)"|
    |> Regex.scan(html)
    |> Enum.map(fn [_, src] -> src end)
    |> Enum.uniq()
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # `:sys.get_state/1` returns only after the view has handled every message
  # already in its mailbox, so the broadcast is known delivered before we look.
  defp settle(view), do: _ = :sys.get_state(view.pid)

  test "an image without a thumbnail instance renders the unversioned URL", ctx do
    %{conn: conn, scope: scope, item: item, user_uuid: user} = ctx
    file = insert_file!(user, "a.jpg")
    {:ok, item} = Attachments.attach_files(item, [file])

    {:ok, view, html} = open(conn, scope, item)

    assert [src] = thumb_srcs(html, file)
    refute src =~ "v="
    assert assigns(view).thumb_versions == %{}
  end

  test "the processed event versions the thumbnail URL", ctx do
    %{conn: conn, scope: scope, item: item, user_uuid: user} = ctx
    file = insert_file!(user, "a.jpg")
    {:ok, item} = Attachments.attach_files(item, [file])
    {:ok, view, _} = open(conn, scope, item)

    instance = make_thumbnail!(file)
    Storage.broadcast_file_processed(file)
    settle(view)

    version = URLSigner.version(instance)
    assert [src] = thumb_srcs(render(view), file)
    assert src =~ "?v=#{version}"
    assert assigns(view).thumb_versions == %{file => version}
  end

  test "the version is the thumbnail's checksum, not the original's", ctx do
    %{conn: conn, scope: scope, item: item, user_uuid: user} = ctx
    file = insert_file!(user, "a.jpg")
    {:ok, item} = Attachments.attach_files(item, [file])
    {:ok, view, _} = open(conn, scope, item)

    make_thumbnail!(file, "fedcba9876543210fedcba9876543210")
    Storage.broadcast_file_processed(file)
    settle(view)

    assert [src] = thumb_srcs(render(view), file)
    assert src =~ "?v=fedcba9876543210"
    refute src =~ "chk-"
  end

  test "the featured-image card is versioned too", ctx do
    %{conn: conn, scope: scope, item: item, user_uuid: user} = ctx
    file = insert_file!(user, "f.jpg")
    {:ok, _} = Catalogue.update_item(item, %{data: %{"featured_image_uuid" => file}})
    item = Catalogue.get_item!(item.uuid)

    {:ok, view, html} = open(conn, scope, item)
    refute Enum.any?(thumb_srcs(html, file), &(&1 =~ "v="))
    assert assigns(view).featured_thumb_version == nil

    instance = make_thumbnail!(file)
    Storage.broadcast_file_processed(file)
    settle(view)

    version = URLSigner.version(instance)
    srcs = thumb_srcs(render(view), file)
    assert srcs != []
    assert Enum.all?(srcs, &(&1 =~ "?v=#{version}"))
    assert assigns(view).featured_thumb_version == version
  end

  test "a file that already has its thumbnail renders versioned at mount", ctx do
    %{conn: conn, scope: scope, item: item, user_uuid: user} = ctx
    file = insert_file!(user, "a.jpg")
    other = insert_file!(user, "b.jpg")
    {:ok, item} = Attachments.attach_files(item, [file, other])
    instance = make_thumbnail!(file)

    {:ok, view, html} = open(conn, scope, item)

    assert [src] = thumb_srcs(html, file)
    assert src =~ "?v=#{URLSigner.version(instance)}"
    # One query result for the whole grid; the file without one stays out.
    assert assigns(view).thumb_versions == %{file => URLSigner.version(instance)}
    refute Enum.any?(thumb_srcs(html, other), &(&1 =~ "v="))
  end

  test "a reorder and a grid refresh keep the versions", ctx do
    %{conn: conn, scope: scope, item: item, user_uuid: user, catalogue: cat} = ctx
    a = insert_file!(user, "a.jpg")
    b = insert_file!(user, "b.jpg")
    {:ok, item} = Attachments.attach_files(item, [a, b])
    instance = make_thumbnail!(a)
    {:ok, view, _} = open(conn, scope, item)

    render_hook(view, "reorder_files", %{"ordered_ids" => [b, a]})
    send(view.pid, {:catalogue_data_changed, :item, item.uuid, cat.uuid})
    settle(view)

    assert [src] = thumb_srcs(render(view), a)
    assert src =~ "?v=#{URLSigner.version(instance)}"
  end

  test "an upload landing later is picked up by the rebuilt grid", ctx do
    %{conn: conn, scope: scope, item: item, user_uuid: user, catalogue: cat} = ctx
    {:ok, view, _} = open(conn, scope, item)

    # A file attached elsewhere, its thumbnail already made, then the form
    # told the resource changed: the rebuild re-reads the instances.
    file = insert_file!(user, "late.jpg")
    {:ok, _} = Attachments.attach_files(item, [file])
    instance = make_thumbnail!(file)
    send(view.pid, {:catalogue_data_changed, :item, item.uuid, cat.uuid})
    settle(view)

    assert [src] = thumb_srcs(render(view), file)
    assert src =~ "?v=#{URLSigner.version(instance)}"
  end

  test "events for an unrelated uuid, or of other shapes, change nothing", ctx do
    %{conn: conn, scope: scope, item: item, user_uuid: user} = ctx
    file = insert_file!(user, "a.jpg")
    {:ok, item} = Attachments.attach_files(item, [file])
    {:ok, view, _} = open(conn, scope, item)
    before = assigns(view).thumb_versions

    # A thumbnail exists for the shown file, but only an event for
    # *another* uuid arrives: nothing re-read, nothing changed.
    make_thumbnail!(file)
    Storage.broadcast_file_processed(Ecto.UUID.generate())
    settle(view)

    for msg <- [
          {:phoenix_kit_file_thumbnail_updated, file},
          {:phoenix_kit_file_trashed, file},
          {:phoenix_kit_file_restored, file},
          {:phoenix_kit_file_deleted, file},
          {:phoenix_kit_files_trashed, [file, Ecto.UUID.generate()]},
          {:phoenix_kit_files_restored, [file]},
          {:phoenix_kit_files_deleted, [file]},
          {:phoenix_kit_file_processed, :not_a_uuid},
          :something_else
        ] do
      send(view.pid, msg)
    end

    settle(view)

    html = render(view)
    assert Process.alive?(view.pid)
    assert assigns(view).thumb_versions == before
    refute Enum.any?(thumb_srcs(html, file), &(&1 =~ "v="))
  end

  test "the catalogue and category forms mount, render, and take the event", ctx do
    %{conn: conn, scope: scope, catalogue: cat, user_uuid: user} = ctx
    category = fixture_category(cat, %{name: "Thumb Cat"})
    file = insert_file!(user, "f.jpg")

    {:ok, _} = Catalogue.update_catalogue(cat, %{data: %{"featured_image_uuid" => file}})

    {:ok, _} =
      Catalogue.update_category(category, %{data: %{"featured_image_uuid" => file}})

    instance = make_thumbnail!(file)
    version = URLSigner.version(instance)

    for path <- ["#{@base}/#{cat.uuid}/edit", "#{@base}/categories/#{category.uuid}/edit"] do
      {:ok, view, html} = conn |> with_scope(scope) |> live(path)
      assert [src | _] = thumb_srcs(html, file)
      assert src =~ "?v=#{version}"

      Storage.broadcast_file_processed(file)
      settle(view)
      assert render(view) =~ "/thumbnail/"
      assert Process.alive?(view.pid)
    end
  end

  test "the category form (no files grid) learns the featured version from the event", ctx do
    %{conn: conn, scope: scope, catalogue: cat, user_uuid: user} = ctx
    category = fixture_category(cat, %{name: "Thumb Cat 2"})
    file = insert_file!(user, "f.jpg")
    {:ok, _} = Catalogue.update_category(category, %{data: %{"featured_image_uuid" => file}})

    {:ok, view, html} =
      conn |> with_scope(scope) |> live("#{@base}/categories/#{category.uuid}/edit")

    refute Enum.any?(thumb_srcs(html, file), &(&1 =~ "v="))

    instance = make_thumbnail!(file)
    Storage.broadcast_file_processed(file)
    settle(view)

    assert [src] = thumb_srcs(render(view), file)
    assert src =~ "?v=#{URLSigner.version(instance)}"
  end

  test "the hook is attached and subscribed once per process", ctx do
    %{conn: conn, scope: scope, item: item} = ctx
    {:ok, view, _} = open(conn, scope, item)
    assert assigns(view).attachments_file_events_attached == true
  end
end
