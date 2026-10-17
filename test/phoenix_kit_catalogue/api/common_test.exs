defmodule PhoenixKitCatalogue.API.CommonTest do
  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKit.API.Actor
  alias PhoenixKitCatalogue.API.Common
  alias PhoenixKitCatalogue.Schemas.Item

  defp ctx(extra \\ %{}) do
    actor = %Actor{
      kind: :key,
      key_uuid: Ecto.UUID.generate(),
      key_prefix: "abcd1234",
      user_uuid: "00000000-0000-7000-8000-000000000009",
      scopes: []
    }

    Map.merge(%{actor: actor, request_id: "req-1"}, extra)
  end

  test "write_opts/3 names the actor, the mode and the metadata" do
    opts = Common.write_opts(ctx(), "catalogue.create_products")

    assert opts[:actor_uuid] == "00000000-0000-7000-8000-000000000009"
    assert opts[:mode] == "auto"

    assert opts[:log_metadata] == %{
             "via" => "api",
             "key_prefix" => "abcd1234",
             "request_id" => "req-1",
             "tool" => "catalogue.create_products"
           }
  end

  test "write_opts/3 adds the approver when core passes one, and takes extras" do
    opts =
      Common.write_opts(ctx(%{approved_by_uuid: "u-1"}), "catalogue.delete_products",
        broadcast: false
      )

    assert opts[:log_metadata]["approved_by_uuid"] == "u-1"
    assert opts[:broadcast] == false
  end

  test "invalid/3 builds the handler error with a path" do
    assert {:error, :validation_failed, "bad", %{errors: [error]}} =
             Common.invalid("limit", "bad", [1, 2])

    assert error == %{path: "limit", message: "bad", limit: nil, allowed: [1, 2]}
  end

  test "parse_uuid/2" do
    uuid = Ecto.UUID.generate()
    assert {:ok, nil} = Common.parse_uuid(nil, "x")
    assert {:ok, ^uuid} = Common.parse_uuid(String.upcase(uuid), "x")

    assert {:error, :validation_failed, _, %{errors: [%{path: "x"}]}} =
             Common.parse_uuid("nope", "x")

    assert {:error, :validation_failed, _, _} = Common.parse_uuid(5, "x")

    # 16 bytes are a valid raw UUID to Ecto.UUID.cast/1, but not a UUID as text
    assert {:error, :validation_failed, _, _} = Common.parse_uuid("abcdefghijklmnop", "x")
  end

  test "category_verdict/3 answers a malformed id with a message and caches it" do
    # Row-level ids are free strings in the schemas; the verdict is a per-row message.
    assert {{:error, "must be a UUID"}, cache} =
             Common.category_verdict("short", %{uuid: Ecto.UUID.generate()}, %{})

    assert %{"short" => {:error, "must be a UUID"}} = cache

    assert {{:error, "must be a UUID"}, _} =
             Common.category_verdict(5, %{uuid: Ecto.UUID.generate()}, %{})
  end

  test "ensure_schema/1 refuses a chain below V5 and passes V5 and above" do
    assert :ok = Common.ensure_schema(5)
    assert :ok = Common.ensure_schema(6)

    assert {:error, :internal_error, message, %{required: 5, applied: 4}} =
             Common.ensure_schema(4)

    assert message =~ "version 4"

    assert {:error, :internal_error, unconfirmed, %{applied: 0}} = Common.ensure_schema(0)
    assert unconfirmed =~ "Could not confirm"

    # the default reads the database marker; the test database is at the current chain version
    assert :ok = Common.ensure_schema()
  end

  test "blank?/1" do
    assert Common.blank?(nil) and Common.blank?("") and Common.blank?("  \n")
    refute Common.blank?("a")
    refute Common.blank?(0)
  end

  test "row builders and the summary" do
    ok = Common.row_ok(%{"sku" => "A"}, "created", "id-1", %{"extra" => 1})
    err = Common.row_error(%{"sku" => "B"}, :not_found, "gone", %{"k" => "v"})

    skipped =
      Common.row_skipped(%{"sku" => "C"}, :already_exists, "dup", %{"existing_id" => "id-9"})

    assert ok == %{"ref" => %{"sku" => "A"}, "action" => "created", "id" => "id-1", "extra" => 1}
    assert err["action"] == "error"

    assert err["error"] == %{
             "code" => "not_found",
             "message" => "gone",
             "context" => %{"k" => "v"}
           }

    assert skipped["action"] == "skipped"
    assert skipped["error"]["code"] == "already_exists"

    assert Common.summary([ok, err, skipped, ok]) == %{
             "created" => 2,
             "error" => 1,
             "skipped" => 1
           }

    assert {:ok, %{"results" => [^ok, ^err], "summary" => %{"created" => 1, "error" => 1}}} =
             Common.batch_result([ok, err])
  end

  test "preview/1 pairs the rows with a fingerprint that follows their content" do
    rows = [
      Common.row_ok(%{"sku" => "A"}, "updated", "id-1", %{
        "changes" => %{"name" => %{"from" => "a", "to" => "b"}}
      })
    ]

    changed = [
      Common.row_ok(%{"sku" => "A"}, "updated", "id-1", %{
        "changes" => %{"name" => %{"from" => "a", "to" => "c"}}
      })
    ]

    assert {:preview, %{"rows" => ^rows, "summary" => %{"updated" => 1}}, fingerprint} =
             Common.preview(rows)

    assert is_binary(fingerprint) and byte_size(fingerprint) == 64
    assert {:preview, _, ^fingerprint} = Common.preview(rows)
    assert {:preview, _, other} = Common.preview(changed)
    assert other != fingerprint
  end

  test "resolution_error/2 for each failure" do
    assert %{"action" => "error", "error" => %{"code" => "not_found"}} =
             Common.resolution_error(%{"sku" => "x"}, :not_found)

    assert %{"error" => %{"code" => "validation_failed"}} =
             Common.resolution_error(%{}, :invalid_ref)

    assert %{"error" => %{"code" => "ambiguous_ref", "context" => %{"candidates" => ["a", "b"]}}} =
             Common.resolution_error(%{"sku" => "x"}, {:ambiguous_ref, ["a", "b"]})
  end

  test "changeset_errors/1 flattens messages, interpolating their options" do
    changeset = Item.changeset(%Item{}, %{name: String.duplicate("x", 300)})
    errors = Common.changeset_errors(changeset)

    assert %{"path" => "name", "message" => "should be at most 255 character(s)"} in errors
    assert %{"path" => "catalogue_uuid", "message" => "can't be blank"} in errors
  end

  test "external_id_conflict?/1 recognises the changeset of a duplicate external_id on the V5 index" do
    catalogue = PhoenixKitCatalogue.LiveCase.fixture_catalogue(%{name: "Conflict Cat"})

    attrs = %{
      name: "A",
      catalogue_uuid: catalogue.uuid,
      data: %{"api" => %{"external_id" => "E"}}
    }

    assert {:ok, _} = PhoenixKitCatalogue.Catalogue.create_item(attrs)
    assert {:error, taken} = PhoenixKitCatalogue.Catalogue.create_item(attrs)

    assert Common.external_id_conflict?(taken)
  end

  test "external_id_conflict?/1 is false for other failures, even one worded alike" do
    other =
      %Item{} |> Ecto.Changeset.change() |> Ecto.Changeset.add_error(:name, "can't be blank")

    elsewhere =
      %Item{}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.add_error(:name, "external_id is already taken in this catalogue")

    other_data =
      %Item{} |> Ecto.Changeset.change() |> Ecto.Changeset.add_error(:data, "is invalid")

    worded_alike =
      %Item{}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.add_error(:data, "external_id is already taken in this catalogue")

    refute Common.external_id_conflict?(other)
    refute Common.external_id_conflict?(elsewhere)
    refute Common.external_id_conflict?(other_data)
    # decided by the constraint, not by the sentence
    refute Common.external_id_conflict?(worded_alike)
  end

  test "with_warnings/2" do
    assert Common.with_warnings(%{"a" => 1}, []) == %{"a" => 1}

    assert Common.with_warnings(%{"a" => 1}, [%{"code" => "w"}]) == %{
             "a" => 1,
             "warnings" => [%{"code" => "w"}]
           }
  end

  test "category_verdict/3 accepts an active category of the catalogue and caches the verdict" do
    catalogue = PhoenixKitCatalogue.LiveCase.fixture_catalogue(%{name: "Verdict Cat"})
    other = PhoenixKitCatalogue.LiveCase.fixture_catalogue(%{name: "Verdict Other"})
    own = PhoenixKitCatalogue.LiveCase.fixture_category(catalogue, %{name: "Own"})
    foreign = PhoenixKitCatalogue.LiveCase.fixture_category(other, %{name: "Foreign"})

    {:ok, trashed} =
      PhoenixKitCatalogue.Catalogue.create_category(%{
        name: "Trashed",
        catalogue_uuid: catalogue.uuid
      })

    {:ok, _} = PhoenixKitCatalogue.Catalogue.trash_category(trashed)

    assert {{:ok, own_uuid}, cache} = Common.category_verdict(own.uuid, catalogue, %{})
    assert own_uuid == own.uuid
    assert cache == %{own.uuid => {:ok, own.uuid}}

    # the upper-case form is the same category: canonical answer, same cache entry
    assert {{:ok, ^own_uuid}, ^cache} =
             Common.category_verdict(String.upcase(own.uuid), catalogue, cache)

    assert {{:error, "is not an active category of this catalogue"}, _} =
             Common.category_verdict(foreign.uuid, catalogue, %{})

    assert {{:error, "is not an active category of this catalogue"}, _} =
             Common.category_verdict(trashed.uuid, catalogue, %{})

    assert {{:error, "no category has this id"}, _} =
             Common.category_verdict(Ecto.UUID.generate(), catalogue, %{})
  end
end
