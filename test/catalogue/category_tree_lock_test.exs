defmodule PhoenixKitCatalogue.Catalogue.CategoryTreeLockTest do
  @moduledoc """
  A category re-parent holds the lock of the catalogue the category is in
  now — read from the row, not the caller's copy — through its cycle
  check. The sandbox runs every test on one connection and cannot race,
  so this holds that lock from a second, real connection and watches the
  re-parent wait.
  """
  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase, only: [fixture_catalogue: 1, fixture_category: 2]

  import Ecto.Query

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Category
  alias PhoenixKitCatalogue.Test.Repo

  # `Catalogue.lock_catalogue!/1`'s key.
  @lock "SELECT pg_advisory_lock(727401120, hashtext($1::text))"
  @unlock "SELECT pg_advisory_unlock(727401120, hashtext($1::text))"

  defp holder do
    opts = Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database])
    # Linked: it ends with the test, releasing whatever it still holds.
    {:ok, conn} = Postgrex.start_link(opts)
    conn
  end

  test "a re-parent through a stale copy waits on the catalogue the category is in now" do
    [old_home, new_home] = [fixture_catalogue(%{name: "Old"}), fixture_catalogue(%{name: "New"})]
    stale = fixture_category(old_home, %{name: "Wanderer"})

    # Moved since `stale` was read. Written directly: a real move's own
    # catalogue locks would be held by this test's sandbox transaction
    # until it ends, and the holder below could never take one.
    Repo.update_all(from(c in Category, where: c.uuid == ^stale.uuid),
      set: [catalogue_uuid: new_home.uuid]
    )

    parent = fixture_category(new_home, %{name: "Parent"})

    conn = holder()
    Postgrex.query!(conn, @lock, [new_home.uuid])

    move = Task.async(fn -> Catalogue.update_category(stale, %{parent_uuid: parent.uuid}) end)
    assert Task.yield(move, 300) == nil

    Postgrex.query!(conn, @unlock, [new_home.uuid])
    assert {:ok, moved} = Task.await(move)
    assert moved.parent_uuid == parent.uuid
    assert moved.catalogue_uuid == new_home.uuid
  end
end
