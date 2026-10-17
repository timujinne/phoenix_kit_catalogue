defmodule PhoenixKitCatalogue.API.UpsertCategoriesTest do
  @moduledoc "`catalogue.upsert_categories`."

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase, only: [fixture_catalogue: 1, fixture_category: 2]

  alias PhoenixKitCatalogue.API.Refs
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Test.ApiCase

  @tool "catalogue.upsert_categories"

  setup do
    %{catalogue: fixture_catalogue(%{name: "Upsert Cat"})}
  end

  defp upsert(catalogue, items, overrides \\ %{}),
    do: ApiCase.call(@tool, %{"catalogue_id" => catalogue.uuid, "items" => items}, overrides)

  defp rows({:ok, %{"results" => rows}}), do: rows
  defp category(id), do: Catalogue.get_category(id)

  # The same request, previewed and then executed against the same data: the
  # rows must answer alike (action and error code, and the id when it exists).
  defp shapes(rows),
    do: Enum.map(rows, &{&1["action"], get_in(&1, ["error", "code"])})

  defp preview_then_execute(catalogue, items) do
    assert {:preview, %{"rows" => preview_rows}, _} =
             upsert(catalogue, items, %{dry_run?: true})

    {preview_rows, rows(upsert(catalogue, items))}
  end

  test "creates categories by external_id, a child naming its parent from the same request",
       %{catalogue: catalogue} do
    result =
      upsert(catalogue, [
        %{"external_id" => "C-1", "name" => "Shelves", "position" => 3},
        %{
          "external_id" => "C-2",
          "name" => "Glass shelves",
          "parent" => %{"external_id" => "C-1"}
        }
      ])

    assert {:ok, %{"summary" => %{"created" => 2}}} = result
    assert [%{"id" => parent_id}, %{"id" => child_id}] = rows(result)

    parent = category(parent_id)
    child = category(child_id)

    assert {parent.name, parent.position, parent.parent_uuid, Refs.external_id(parent)} ==
             {"Shelves", 3, nil, "C-1"}

    assert {child.name, child.parent_uuid, Refs.external_id(child)} ==
             {"Glass shelves", parent_id, "C-2"}

    assert child.catalogue_uuid == catalogue.uuid

    log =
      assert_activity_logged("category.created",
        resource_uuid: child_id,
        actor_uuid: ApiCase.user_uuid()
      )

    assert log.mode == "auto"
    assert log.metadata["via"] == "api"
    assert log.metadata["tool"] == "catalogue.upsert_categories"
  end

  test "updates what differs, leaves what is not given, and is unchanged when nothing differs",
       %{catalogue: catalogue} do
    other = fixture_category(catalogue, %{name: "Other", data: %{"meta" => %{"k" => "v"}}})

    {:ok, shelves} =
      Catalogue.create_category(%{
        name: "Shelves",
        catalogue_uuid: catalogue.uuid,
        position: 1,
        data: %{"api" => %{"external_id" => "C-1"}, "meta" => %{"k" => "v"}}
      })

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             upsert(catalogue, [
               %{"external_id" => "C-1", "name" => "Racks", "parent" => %{"id" => other.uuid}}
             ])

    reread = category(shelves.uuid)
    assert {reread.name, reread.parent_uuid, reread.position} == {"Racks", other.uuid, 1}
    assert reread.data == %{"api" => %{"external_id" => "C-1"}, "meta" => %{"k" => "v"}}

    log = assert_activity_logged("category.updated", resource_uuid: shelves.uuid)
    assert log.metadata["changes"]["name"] == %{"from" => "Shelves", "to" => "Racks"}
    # The field that moved is in the diff, not only the actor and `via`.
    assert log.metadata["changes"]["parent_uuid"] == %{"from" => "", "to" => other.uuid}

    assert {:ok, %{"summary" => %{"unchanged" => 1}}} =
             upsert(catalogue, [%{"external_id" => "C-1", "name" => "Racks", "position" => 1}])
  end

  test "id plus external_id sets the external id of an existing category and keeps its other data",
       %{catalogue: catalogue} do
    c = fixture_category(catalogue, %{name: "Plain", data: %{"meta" => %{"k" => "v"}}})

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             upsert(catalogue, [%{"id" => c.uuid, "external_id" => "C-9"}])

    reread = category(c.uuid)
    assert Refs.external_id(reread) == "C-9"
    assert reread.data["meta"] == %{"k" => "v"}

    log = assert_activity_logged("category.updated", resource_uuid: c.uuid)
    assert log.metadata["changes"]["data.api.external_id"] == %{"from" => "", "to" => "C-9"}
  end

  test "id plus external_id: null clears the external id and keeps the other data",
       %{catalogue: catalogue} do
    {:ok, c} =
      Catalogue.create_category(%{
        name: "Linked",
        catalogue_uuid: catalogue.uuid,
        data: %{"api" => %{"external_id" => "C-1"}, "meta" => %{"k" => "v"}}
      })

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             upsert(catalogue, [%{"id" => c.uuid, "external_id" => nil}])

    reread = category(c.uuid)
    assert Refs.external_id(reread) == nil
    assert reread.data == %{"meta" => %{"k" => "v"}}

    log = assert_activity_logged("category.updated", resource_uuid: c.uuid)
    assert log.metadata["changes"]["data.api.external_id"] == %{"from" => "C-1", "to" => ""}

    # a retry finds nothing to clear
    assert [%{"action" => "unchanged"}] =
             rows(upsert(catalogue, [%{"id" => c.uuid, "external_id" => nil}]))
  end

  test "external_id: null without an id has nothing to find the category by", %{
    catalogue: catalogue
  } do
    assert [%{"action" => "error", "error" => %{"code" => "validation_failed"}}] =
             rows(upsert(catalogue, [%{"external_id" => nil, "name" => "Nameless link"}]))
  end

  test "parent: null moves to the top level; a cycle and a foreign parent are row errors",
       %{catalogue: catalogue} do
    top = fixture_category(catalogue, %{name: "Top"})
    mid = fixture_category(catalogue, %{name: "Mid", parent_uuid: top.uuid})
    foreign = fixture_category(fixture_catalogue(%{name: "Elsewhere"}), %{name: "Foreign"})

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             upsert(catalogue, [%{"id" => mid.uuid, "parent" => nil}])

    assert category(mid.uuid).parent_uuid == nil

    # a parent change is a diff entry, not only an actor
    log = assert_activity_logged("category.updated", resource_uuid: mid.uuid)
    assert log.metadata["changes"]["parent_uuid"] == %{"from" => top.uuid, "to" => ""}

    assert [row] = rows(upsert(catalogue, [%{"id" => top.uuid, "parent" => %{"id" => top.uuid}}]))
    assert row["action"] == "error"
    assert category(top.uuid).parent_uuid == nil

    {:ok, _} = Catalogue.update_category(category(mid.uuid), %{parent_uuid: top.uuid})

    assert [cycle] =
             rows(upsert(catalogue, [%{"id" => top.uuid, "parent" => %{"id" => mid.uuid}}]))

    assert cycle["action"] == "error"
    assert cycle["error"]["code"] == "validation_failed"

    assert [far] =
             rows(upsert(catalogue, [%{"id" => mid.uuid, "parent" => %{"id" => foreign.uuid}}]))

    assert far["action"] == "error"
    assert far["error"]["code"] == "not_found"
  end

  test "an unknown id is not found and creates nothing; a row needs a reference and, to create, a name",
       %{catalogue: catalogue} do
    before = length(Catalogue.list_categories_metadata_for_catalogue(catalogue.uuid))

    rows =
      rows(
        upsert(catalogue, [
          %{"id" => Ecto.UUID.generate(), "name" => "Ghost"},
          %{"name" => "No reference"},
          %{"external_id" => "NEW-1"},
          %{"external_id" => "NEW-2", "name" => "   "},
          %{"external_id" => "NEW-3", "name" => "Fine"}
        ])
      )

    assert Enum.map(rows, & &1["action"]) == ["error", "error", "error", "error", "created"]

    assert Enum.map(rows, &get_in(&1, ["error", "code"])) == [
             "not_found",
             "validation_failed",
             "validation_failed",
             "validation_failed",
             nil
           ]

    assert length(Catalogue.list_categories_metadata_for_catalogue(catalogue.uuid)) == before + 1
  end

  test "a malformed id, a malformed parent id and a blank external_id fail their own row only",
       %{catalogue: catalogue} do
    # Row-level fields have no length floor in the schema: none of these is a whole-request 422.
    rows =
      rows(
        upsert(catalogue, [
          %{"external_id" => "M-1", "name" => "Fine one"},
          %{"id" => "short", "name" => "Malformed id"},
          %{"external_id" => "M-2", "name" => "Malformed parent", "parent" => %{"id" => "short"}},
          %{"external_id" => "", "name" => "Blank external id"},
          %{"external_id" => "M-3", "name" => "Fine two"}
        ])
      )

    assert Enum.map(rows, & &1["action"]) == ["created", "error", "error", "error", "created"]

    assert Enum.map(rows, &get_in(&1, ["error", "code"])) == [
             nil,
             "not_found",
             "not_found",
             "validation_failed",
             nil
           ]
  end

  test "a blank external_id next to an id is a row error and writes nothing", %{
    catalogue: catalogue
  } do
    c = fixture_category(catalogue, %{name: "Plain", data: %{"meta" => %{"k" => "v"}}})

    assert [row] =
             rows(
               upsert(catalogue, [%{"id" => c.uuid, "external_id" => "", "name" => "Renamed"}])
             )

    assert row["action"] == "error"
    assert row["error"]["code"] == "validation_failed"

    reread = category(c.uuid)
    assert reread.name == "Plain"
    assert reread.data == %{"meta" => %{"k" => "v"}}
  end

  test "a trashed category frees its external_id", %{catalogue: catalogue} do
    {:ok, old} =
      Catalogue.create_category(%{
        name: "Old",
        catalogue_uuid: catalogue.uuid,
        data: %{"api" => %{"external_id" => "C-5"}}
      })

    {:ok, _} = Catalogue.trash_category(old)

    assert [%{"action" => "created", "id" => id}] =
             rows(upsert(catalogue, [%{"external_id" => "C-5", "name" => "New"}]))

    assert id != old.uuid
  end

  test "an external_id another category holds is a row error on update", %{catalogue: catalogue} do
    {:ok, holder} =
      Catalogue.create_category(%{
        name: "Holder",
        catalogue_uuid: catalogue.uuid,
        data: %{"api" => %{"external_id" => "TAKEN"}}
      })

    c = fixture_category(catalogue, %{name: "Plain"})

    assert [row] = rows(upsert(catalogue, [%{"id" => c.uuid, "external_id" => "TAKEN"}]))
    assert row["action"] == "error"
    assert row["error"]["code"] == "already_exists"
    assert row["error"]["context"]["existing_id"] == holder.uuid
  end

  test "a position beyond the column fails its own row and the batch carries on",
       %{catalogue: catalogue} do
    c = fixture_category(catalogue, %{name: "Plain", position: 2})

    items = [
      %{"external_id" => "P-1", "name" => "First"},
      %{"external_id" => "P-2", "name" => "Epoch", "position" => 99_999_999_999},
      %{"id" => c.uuid, "position" => 99_999_999_999},
      %{"external_id" => "P-3", "name" => "Last"}
    ]

    assert {:preview, %{"rows" => preview_rows}, _} = upsert(catalogue, items, %{dry_run?: true})
    executed = rows(upsert(catalogue, items))

    for result <- [preview_rows, executed] do
      assert Enum.map(result, & &1["action"]) == ["created", "error", "error", "created"]

      assert Enum.map(result, &get_in(&1, ["error", "code"])) == [
               nil,
               "validation_failed",
               "validation_failed",
               nil
             ]

      assert [%{"path" => "position"}] = Enum.at(result, 1)["error"]["context"]["errors"]
    end

    assert category(c.uuid).position == 2
    assert Enum.map(executed, & &1["id"]) |> Enum.map(&is_binary/1) == [true, false, false, true]

    # the column's own limit is refused too: the next automatic position would overflow it
    assert [%{"action" => "error"}] =
             rows(
               upsert(catalogue, [
                 %{"external_id" => "P-5", "name" => "Edge", "position" => 2_147_483_647}
               ])
             )
  end

  test "the largest accepted position leaves automatic positions working", %{
    catalogue: catalogue
  } do
    max = Catalogue.max_category_position()

    assert [%{"action" => "created", "id" => top}] =
             rows(
               upsert(catalogue, [%{"external_id" => "P-4", "name" => "Max", "position" => max}])
             )

    assert category(top).position == max

    assert [%{"action" => "created", "id" => next}] =
             rows(upsert(catalogue, [%{"external_id" => "P-6", "name" => "Next"}]))

    assert category(next).position == max
    assert {:ok, _} = Catalogue.create_category(%{name: "Admin", catalogue_uuid: catalogue.uuid})
  end

  test "a position stored beyond the cap does not break automatic positions", %{
    catalogue: catalogue
  } do
    fixture_category(catalogue, %{name: "Huge", position: 2_147_483_647})

    assert Catalogue.next_category_position(catalogue.uuid, nil) ==
             Catalogue.max_category_position()

    assert [%{"action" => "created"}] =
             rows(upsert(catalogue, [%{"external_id" => "P-7", "name" => "After"}]))
  end

  test "a name is stored trimmed on create and on update, so a retry is unchanged",
       %{catalogue: catalogue} do
    padded = %{"external_id" => "N-1", "name" => "  Padded  "}

    assert [%{"action" => "created", "id" => id}] = rows(upsert(catalogue, [padded]))
    assert category(id).name == "Padded"

    assert [%{"action" => "unchanged"}] = rows(upsert(catalogue, [padded]))
    assert category(id).name == "Padded"

    assert [%{"action" => "unchanged"}] =
             rows(upsert(catalogue, [%{"id" => id, "name" => "   Padded"}]))

    assert [%{"action" => "updated"}] =
             rows(upsert(catalogue, [%{"id" => id, "name" => "  Renamed  "}]))

    assert category(id).name == "Renamed"
  end

  test "a name of only blanks on an existing id is a validation error at the name",
       %{catalogue: catalogue} do
    c = fixture_category(catalogue, %{name: "Plain"})

    items = [%{"id" => c.uuid, "name" => "   "}]

    {preview_rows, executed} = preview_then_execute(catalogue, items)

    for [row] <- [preview_rows, executed] do
      assert row["error"]["code"] == "validation_failed"
      assert [%{"path" => "name"}] = row["error"]["context"]["errors"]
    end

    assert category(c.uuid).name == "Plain"
  end

  test "a row with a bad parent writes nothing, whatever else it carries", %{
    catalogue: catalogue
  } do
    c = fixture_category(catalogue, %{name: "Plain", position: 1})
    foreign = fixture_category(fixture_catalogue(%{name: "Elsewhere"}), %{name: "Foreign"})
    before = length(Catalogue.list_categories_metadata_for_catalogue(catalogue.uuid))

    rows =
      rows(
        upsert(catalogue, [
          %{
            "id" => c.uuid,
            "name" => "Renamed",
            "position" => 9,
            "parent" => %{"id" => foreign.uuid}
          },
          %{"external_id" => "B-1", "name" => "Orphan", "parent" => %{"external_id" => "NOPE"}},
          %{
            "external_id" => "B-2",
            "name" => "Foreign child",
            "parent" => %{"id" => foreign.uuid}
          }
        ])
      )

    assert Enum.map(rows, &get_in(&1, ["error", "code"])) == [
             "not_found",
             "not_found",
             "not_found"
           ]

    reread = category(c.uuid)
    assert {reread.name, reread.position, reread.parent_uuid} == {"Plain", 1, nil}
    assert length(Catalogue.list_categories_metadata_for_catalogue(catalogue.uuid)) == before
  end

  test "an empty or two-key parent reference is a validation error on its row only", %{
    catalogue: catalogue
  } do
    c = fixture_category(catalogue, %{name: "Plain"})

    rows =
      rows(
        upsert(catalogue, [
          %{"id" => c.uuid, "name" => "A", "parent" => %{}},
          %{"id" => c.uuid, "name" => "B", "parent" => %{"id" => c.uuid, "external_id" => "X"}},
          %{"external_id" => "R-1", "name" => "Fine"}
        ])
      )

    assert Enum.map(rows, & &1["action"]) == ["error", "error", "created"]

    assert Enum.map(Enum.take(rows, 2), &get_in(&1, ["error", "code"])) ==
             ["validation_failed", "validation_failed"]

    assert category(c.uuid).name == "Plain"
  end

  test "the schema refuses unknown fields and bad values", %{catalogue: catalogue} do
    for {extra, path} <- [
          {%{"data" => %{}}, "items[0].data"},
          {%{"base_price" => 1}, "items[0].base_price"},
          {%{"position" => -1}, "items[0].position"},
          {%{"parent" => %{"name" => "x"}}, "items[0].parent.name"},
          {%{"parent" => "Shelves"}, "items[0].parent"}
        ] do
      assert {:error, :validation_failed, _, %{errors: errors}} =
               upsert(catalogue, [Map.merge(%{"external_id" => "C-1", "name" => "N"}, extra)])

      assert Enum.any?(errors, &(&1.path == path)), "#{inspect(extra)}: #{inspect(errors)}"
    end

    assert {:error, :validation_failed, _, _} = upsert(catalogue, [])
    items = for n <- 1..501, do: %{"external_id" => "C#{n}", "name" => "N#{n}"}
    assert {:error, :validation_failed, _, %{errors: [%{limit: 500}]}} = upsert(catalogue, items)
  end

  describe "dry run" do
    test "walks the batch without writing, accepting a parent the request would create", %{
      catalogue: catalogue
    } do
      c = fixture_category(catalogue, %{name: "Plain"})

      items = [
        %{"external_id" => "C-1", "name" => "Shelves"},
        %{"external_id" => "C-2", "name" => "Glass", "parent" => %{"external_id" => "C-1"}},
        %{"id" => c.uuid, "name" => "Renamed"},
        %{"id" => c.uuid, "name" => "Renamed"}
      ]

      before = length(Catalogue.list_categories_metadata_for_catalogue(catalogue.uuid))

      assert {:preview, %{"rows" => [one, two, three, four], "summary" => summary}, fingerprint} =
               upsert(catalogue, items, %{dry_run?: true})

      assert one["action"] == "created"
      assert one["fields"]["name"] == "Shelves"
      assert two["action"] == "created"
      assert three["action"] == "updated"
      assert three["changes"]["name"] == %{"from" => "Plain", "to" => "Renamed"}
      assert four["action"] == "unchanged"
      assert summary == %{"created" => 2, "updated" => 1, "unchanged" => 1}

      assert length(Catalogue.list_categories_metadata_for_catalogue(catalogue.uuid)) == before
      assert category(c.uuid).name == "Plain"

      assert {:preview, _, ^fingerprint} = upsert(catalogue, items, %{dry_run?: true})

      {:ok, _} = Catalogue.update_category(category(c.uuid), %{name: "Changed meanwhile"})
      assert {:preview, _, other} = upsert(catalogue, items, %{dry_run?: true})
      assert other != fingerprint
    end

    test "answers the rows the write answers: a held external_id, a self-parent and a cycle", %{
      catalogue: catalogue
    } do
      {:ok, holder} =
        Catalogue.create_category(%{
          name: "Holder",
          catalogue_uuid: catalogue.uuid,
          data: %{"api" => %{"external_id" => "TAKEN"}}
        })

      plain = fixture_category(catalogue, %{name: "Plain"})
      top = fixture_category(catalogue, %{name: "Top"})
      mid = fixture_category(catalogue, %{name: "Mid", parent_uuid: top.uuid})
      leaf = fixture_category(catalogue, %{name: "Leaf"})

      items = [
        %{"id" => plain.uuid, "external_id" => "TAKEN"},
        %{"id" => top.uuid, "parent" => %{"id" => top.uuid}},
        %{"id" => top.uuid, "parent" => %{"id" => mid.uuid}},
        # two rows of one request: the first re-parents Leaf under Top, the second would close the loop
        %{"id" => leaf.uuid, "parent" => %{"id" => top.uuid}},
        %{"id" => top.uuid, "parent" => %{"id" => leaf.uuid}}
      ]

      assert {:preview, %{"rows" => preview_rows}, _} =
               upsert(catalogue, items, %{dry_run?: true})

      assert Enum.map(preview_rows, & &1["action"]) == [
               "error",
               "error",
               "error",
               "updated",
               "error"
             ]

      assert Enum.map(preview_rows, &get_in(&1, ["error", "code"])) == [
               "already_exists",
               "validation_failed",
               "validation_failed",
               nil,
               "validation_failed"
             ]

      assert hd(preview_rows)["error"]["context"]["existing_id"] == holder.uuid

      # nothing was written by the preview, and the write gives the same answers
      assert category(leaf.uuid).parent_uuid == nil
      executed = rows(upsert(catalogue, items))

      assert Enum.map(executed, &{&1["action"], get_in(&1, ["error", "code"])}) ==
               Enum.map(preview_rows, &{&1["action"], get_in(&1, ["error", "code"])})
    end

    test "a clear and the reuse of the freed external_id in one request answer like the write", %{
      catalogue: catalogue
    } do
      {:ok, linked} =
        Catalogue.create_category(%{
          name: "Linked",
          catalogue_uuid: catalogue.uuid,
          data: %{"api" => %{"external_id" => "C-1"}}
        })

      other = fixture_category(catalogue, %{name: "Other"})

      items = [
        %{"id" => linked.uuid, "external_id" => nil},
        %{"id" => other.uuid, "external_id" => "C-1"}
      ]

      {preview_rows, executed} = preview_then_execute(catalogue, items)

      assert shapes(preview_rows) == shapes(executed)
      assert shapes(executed) == [{"updated", nil}, {"updated", nil}]
      assert Refs.external_id(category(linked.uuid)) == nil
      assert Refs.external_id(category(other.uuid)) == "C-1"
    end

    test "a parent that nothing creates is still an error in the preview", %{catalogue: catalogue} do
      assert {:preview, %{"rows" => [row]}, _} =
               upsert(
                 catalogue,
                 [
                   %{
                     "external_id" => "C-2",
                     "name" => "Orphan",
                     "parent" => %{"external_id" => "NOPE"}
                   }
                 ],
                 %{dry_run?: true}
               )

      assert row["action"] == "error"
      assert row["error"]["code"] == "not_found"
    end

    test "a later row meets what an earlier row of the request created" do
      for {second, expected} <- [
            {%{"external_id" => "N-1", "name" => "Second"}, {"updated", nil}},
            {%{"external_id" => "N-1", "name" => "First"}, {"unchanged", nil}},
            {%{"external_id" => "N-1"}, {"unchanged", nil}}
          ] do
        catalogue = fixture_catalogue(%{name: "Dup #{System.unique_integer([:positive])}"})
        items = [%{"external_id" => "N-1", "name" => "First"}, second]

        {preview_rows, executed} = preview_then_execute(catalogue, items)

        assert shapes(preview_rows) == shapes(executed)
        assert shapes(executed) == [{"created", nil}, expected]
      end
    end

    test "two rows giving one new external_id to two categories: the second is refused",
         %{catalogue: catalogue} do
      a = fixture_category(catalogue, %{name: "A"})
      b = fixture_category(catalogue, %{name: "B"})

      {preview_rows, executed} =
        preview_then_execute(catalogue, [
          %{"id" => a.uuid, "external_id" => "Z"},
          %{"id" => b.uuid, "external_id" => "Z"}
        ])

      assert shapes(preview_rows) == shapes(executed)
      assert shapes(executed) == [{"updated", nil}, {"error", "already_exists"}]
      assert Enum.at(preview_rows, 1)["error"]["context"]["existing_id"] == a.uuid
      assert Enum.at(executed, 1)["error"]["context"]["existing_id"] == a.uuid
    end

    test "an external_id one row frees can be taken by the next, and found by it", %{
      catalogue: catalogue
    } do
      {:ok, a} =
        Catalogue.create_category(%{
          name: "A",
          catalogue_uuid: catalogue.uuid,
          data: %{"api" => %{"external_id" => "X"}}
        })

      b = fixture_category(catalogue, %{name: "B"})

      items = [
        %{"id" => a.uuid, "external_id" => "Z"},
        %{"id" => b.uuid, "external_id" => "X"},
        # Z now names A, and X names B
        %{"external_id" => "Z", "name" => "A renamed"},
        %{"external_id" => "X", "name" => "B renamed", "parent" => %{"external_id" => "Z"}}
      ]

      {preview_rows, executed} = preview_then_execute(catalogue, items)

      assert shapes(preview_rows) == shapes(executed)

      assert shapes(executed) == [
               {"updated", nil},
               {"updated", nil},
               {"updated", nil},
               {"updated", nil}
             ]

      assert Enum.map(Enum.drop(preview_rows, 2), & &1["id"]) == [a.uuid, b.uuid]
      assert category(b.uuid).parent_uuid == a.uuid
    end

    test "a row meets the values an earlier row of the request gave the same category", %{
      catalogue: catalogue
    } do
      c = fixture_category(catalogue, %{name: "Plain"})

      {preview_rows, executed} =
        preview_then_execute(catalogue, [
          %{"id" => c.uuid, "name" => "Renamed"},
          %{"id" => c.uuid, "name" => "Plain"},
          %{"id" => c.uuid, "name" => "Plain"}
        ])

      assert shapes(preview_rows) == shapes(executed)
      assert shapes(executed) == [{"updated", nil}, {"updated", nil}, {"unchanged", nil}]
    end

    test "a category the request creates can be re-parented and used as a parent in the preview",
         %{catalogue: catalogue} do
      items = [
        %{"external_id" => "T-1", "name" => "Top"},
        %{"external_id" => "T-2", "name" => "Mid", "parent" => %{"external_id" => "T-1"}},
        # closes a loop through two categories the request created
        %{"external_id" => "T-1", "parent" => %{"external_id" => "T-2"}}
      ]

      {preview_rows, executed} = preview_then_execute(catalogue, items)

      assert shapes(preview_rows) == shapes(executed)

      assert shapes(executed) == [
               {"created", nil},
               {"created", nil},
               {"error", "validation_failed"}
             ]
    end
  end
end
