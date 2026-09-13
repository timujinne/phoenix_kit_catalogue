defmodule PhoenixKitCatalogue.Web.ItemFormMediaOrderTest do
  @moduledoc """
  Client, 2026-09-12: "I reorder the photos and they come back." Through
  the real item-form LiveView: the SortableGrid hook's `reorder_files`
  event lands, the order is persisted without a Save, and a broadcast
  for this item (which refreshes the grid from the folder) does not
  snap the grid back to folder order.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Test.Repo

  @base "/en/admin/catalogue"

  setup do
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
        "order-#{System.unique_integer([:positive])}@example.com",
        "$2b$12$0000000000000000000000000000000000000000000000000000."
      ]
    )

    {:ok, user_uuid: user_uuid}
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

  defp grid_order(html) do
    ~r/data-id="([0-9a-f-]{36})"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, uuid] -> uuid end)
    |> Enum.uniq()
  end

  test "a reorder persists without Save and survives the grid's refresh", %{
    conn: conn,
    scope: scope,
    user_uuid: user_uuid
  } do
    catalogue = fixture_catalogue(%{name: "Order Range"})
    item = fixture_item(%{name: "Ordered Item", catalogue_uuid: catalogue.uuid})
    a = insert_file!(user_uuid, "a.jpg")
    b = insert_file!(user_uuid, "b.jpg")
    c = insert_file!(user_uuid, "c.jpg")
    {:ok, item} = Attachments.attach_files(item, [a, b, c])

    {:ok, view, _html} = conn |> with_scope(scope) |> live("#{@base}/items/#{item.uuid}/edit")
    assert grid_order(render(view)) == [a, b, c]

    # The SortableGrid hook's event, as the browser sends it after a drop.
    html = render_hook(view, "reorder_files", %{"ordered_ids" => [c, a, b]})
    assert grid_order(html) == [c, a, b]

    # Persisted at once — no Save pressed.
    assert Catalogue.get_item!(item.uuid).data["media_order"] == [c, a, b]

    # A broadcast for this item refreshes the grid from the folder; the
    # editor's order must survive it (it used to snap back to a, b, c).
    send(view.pid, {:catalogue_data_changed, :item, item.uuid, catalogue.uuid})
    assert grid_order(render(view)) == [c, a, b]

    # And a fresh page shows the persisted order.
    {:ok, view2, html2} = conn |> with_scope(scope) |> live("#{@base}/items/#{item.uuid}/edit")
    assert grid_order(html2) == [c, a, b]
    assert Repo.exists?(from(i in PhoenixKitCatalogue.Schemas.Item, where: i.uuid == ^item.uuid))
    _ = view2
  end

  test "a same-place drop writes nothing, and a reorder in another tab reaches an open form", %{
    conn: conn,
    scope: scope,
    user_uuid: user_uuid
  } do
    catalogue = fixture_catalogue(%{name: "Order Range 2"})
    item = fixture_item(%{name: "Ordered Item 2", catalogue_uuid: catalogue.uuid})
    a = insert_file!(user_uuid, "a.jpg")
    b = insert_file!(user_uuid, "b.jpg")
    c = insert_file!(user_uuid, "c.jpg")
    {:ok, item} = Attachments.attach_files(item, [a, b, c])

    {:ok, tab1, _} = conn |> with_scope(scope) |> live("#{@base}/items/#{item.uuid}/edit")
    render_hook(tab1, "reorder_files", %{"ordered_ids" => [c, a, b]})
    updates = fn -> Enum.count(list_activities(), &(&1.action == "item.updated")) end
    n = updates.()

    # The hook fires on every drop, including one that changed nothing.
    render_hook(tab1, "reorder_files", %{"ordered_ids" => [c, a, b]})
    assert updates.() == n
    assert Catalogue.get_item!(item.uuid).data["media_order"] == [c, a, b]

    # A second tab (or another admin) reorders. The first tab's next
    # refresh adopts it instead of re-applying — and later saving — its
    # own stale order.
    {:ok, tab2, html2} = conn |> with_scope(scope) |> live("#{@base}/items/#{item.uuid}/edit")
    assert grid_order(html2) == [c, a, b]
    render_hook(tab2, "reorder_files", %{"ordered_ids" => [b, c, a]})
    assert Catalogue.get_item!(item.uuid).data["media_order"] == [b, c, a]

    send(tab1.pid, {:catalogue_data_changed, :item, item.uuid, catalogue.uuid})
    assert grid_order(render(tab1)) == [b, c, a]
  end

  test "removing the featured photo clears the pointer and trims the order without Save", %{
    conn: conn,
    scope: scope,
    user_uuid: user_uuid
  } do
    catalogue = fixture_catalogue(%{name: "Order Range 4"})
    item = fixture_item(%{name: "Ordered Item 4", catalogue_uuid: catalogue.uuid})
    a = insert_file!(user_uuid, "a.jpg")
    b = insert_file!(user_uuid, "b.jpg")
    {:ok, item} = Attachments.attach_files(item, [a, b])
    assert Catalogue.get_item!(item.uuid).data["featured_image_uuid"] == a

    {:ok, view, _} = conn |> with_scope(scope) |> live("#{@base}/items/#{item.uuid}/edit")
    html = render_click(view, "remove_file", %{"uuid" => a})
    assert grid_order(html) == [b]

    data = Catalogue.get_item!(item.uuid).data
    assert data["media_order"] == [b]
    refute Map.has_key?(data, "featured_image_uuid")

    # A remount does not bring the removed file back.
    {:ok, _view2, html2} = conn |> with_scope(scope) |> live("#{@base}/items/#{item.uuid}/edit")
    assert grid_order(html2) == [b]
  end

  test "a crafted payload cannot crash the form or invent a file", %{
    conn: conn,
    scope: scope,
    user_uuid: user_uuid
  } do
    catalogue = fixture_catalogue(%{name: "Order Range 3"})
    item = fixture_item(%{name: "Ordered Item 3", catalogue_uuid: catalogue.uuid})
    a = insert_file!(user_uuid, "a.jpg")
    b = insert_file!(user_uuid, "b.jpg")
    {:ok, item} = Attachments.attach_files(item, [a, b])
    {:ok, view, _} = conn |> with_scope(scope) |> live("#{@base}/items/#{item.uuid}/edit")

    # Non-string ids, an unknown uuid, a duplicate, and a missing file.
    html =
      render_hook(view, "reorder_files", %{
        "ordered_ids" => [nil, 7, %{"x" => 1}, UUIDv7.generate(), b, b]
      })

    assert grid_order(html) == [b, a]
    assert Catalogue.get_item!(item.uuid).data["media_order"] == [b, a]
    assert render_hook(view, "reorder_files", %{"ordered_ids" => "nope"}) =~ "a.jpg"
  end
end
