# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DataTest do
  @moduledoc """
  What crosses Arca's boundary is plain data: a schema is projected
  wherever it is planted — a list, a tuple, a map value, a nested schema, a
  loaded association, a contract struct's field, a callback's input — and
  anything else that is neither a scalar nor a Prima contract struct fails
  the projection instead of leaking out.
  """

  use ExUnit.Case, async: false

  alias Arca.Schemas.{Athanor, Membership, User}

  defmodule Private do
    @moduledoc false
    defstruct [:secret]
  end

  defp user(overrides \\ %{}) do
    struct(
      %User{
        id: "usr_data",
        email: "person@example.com",
        status: "active",
        prefs: ~s({"theme":"dark"}),
        first_seen_at: ~U[2026-01-02 03:04:05.000000Z]
      },
      overrides
    )
  end

  defp plain?(map), do: is_map(map) and not is_struct(map)

  # No schema, changeset or metadata anywhere inside `term`.
  defp clean?(term) do
    case term do
      %Ecto.Changeset{} -> false
      %Ecto.Schema.Metadata{} -> false
      %Ecto.Association.NotLoaded{} -> false
      %module{} = struct -> not schema?(module) and clean?(Map.from_struct(struct))
      map when is_map(map) -> Enum.all?(map, fn {k, v} -> clean?(k) and clean?(v) end)
      [head | tail] -> clean?(head) and clean?(tail)
      tuple when is_tuple(tuple) -> tuple |> Tuple.to_list() |> clean?()
      _other -> true
    end
  end

  defp schema?(module), do: function_exported?(module, :__schema__, 1)

  describe "a schema struct" do
    test "becomes an atom-keyed plain map of its fields, values in their stored convention" do
      projected = Arca.Data.project(user())

      assert plain?(projected)
      refute Map.has_key?(projected, :__meta__)
      refute Map.has_key?(projected, :__struct__)
      assert projected.id == "usr_data"
      assert projected.email == "person@example.com"
      # An encoded JSON column stays the string it is stored as.
      assert projected.prefs == ~s({"theme":"dark"})
      # A DateTime stays a DateTime.
      assert projected.first_seen_at == ~U[2026-01-02 03:04:05.000000Z]

      assert Map.keys(projected) |> Enum.sort() ==
               (User.__schema__(:fields) ++ User.__schema__(:virtual_fields)) |> Enum.sort()
    end

    test "omits an association never loaded, and projects a loaded one, nil included" do
      unloaded = Arca.Data.project(%Membership{id: "mem_1", athanor_id: "ath_1"})
      refute Map.has_key?(unloaded, :athanor)
      assert unloaded.athanor_id == "ath_1"

      loaded_nil = Arca.Data.project(%Membership{id: "mem_2", athanor: nil})
      assert Map.has_key?(loaded_nil, :athanor)
      assert loaded_nil.athanor == nil

      loaded = Arca.Data.project(%Membership{id: "mem_3", athanor: %Athanor{id: "ath_3"}})
      assert plain?(loaded.athanor)
      assert loaded.athanor.id == "ath_3"
      assert clean?(loaded)
    end
  end

  describe "containers" do
    test "a schema planted in every container shape is projected" do
      term = %{
        "external key" => [user(), {:ok, user()}],
        nested: %{deeper: {:tuple, [%{row: user()}]}},
        loaded: %Membership{id: "mem_4", athanor: %Athanor{id: "ath_4"}}
      }

      projected = Arca.Data.project(term)

      assert clean?(projected)
      # External keys stay as they came: a string key is never atomized.
      assert [%{id: "usr_data"}, {:ok, %{id: "usr_data"}}] = projected["external key"]
      assert {:tuple, [%{row: %{id: "usr_data"}}]} = projected.nested.deeper
      assert %{athanor: %{id: "ath_4"}} = projected.loaded
      refute Map.has_key?(projected, :"external key")
    end

    test "scalar structs pass unchanged" do
      scalars = [
        ~D[2026-01-02],
        ~T[03:04:05],
        ~N[2026-01-02 03:04:05],
        ~U[2026-01-02 03:04:05Z],
        Decimal.new("1.5")
      ]

      assert Arca.Data.project(scalars) == scalars

      assert Arca.Data.project({:ok, %{at: ~U[2026-01-02 03:04:05Z]}}) ==
               {:ok, %{at: ~U[2026-01-02 03:04:05Z]}}
    end

    test "a Prima contract struct stays that struct, and its fields are projected" do
      actor = %Cyfr.Actor{Cyfr.Actor.system() | request_id: user()}
      projected = Arca.Data.project({:ok, actor})

      assert {:ok, %Cyfr.Actor{} = kept} = projected
      assert kept.scope == actor.scope
      assert plain?(kept.request_id)
      assert kept.request_id.id == "usr_data"
      assert clean?(projected)
    end
  end

  describe "what is not data" do
    test "any other struct fails the whole projection, wherever it is" do
      assert {:error, {:unsupported_data_struct, Private}} =
               Arca.Data.project(%Private{secret: "s"})

      assert {:error, {:unsupported_data_struct, Private}} =
               Arca.Data.project({:ok, [%{rows: [user(), %Private{secret: "s"}]}]})

      assert {:error, {:unsupported_data_struct, URI}} =
               Arca.Data.project(%{link: URI.parse("https://example.com")})

      assert {:error, {:unsupported_data_struct, MapSet}} = Arca.Data.project(MapSet.new([1]))

      assert {:error, {:unsupported_data_struct, Ecto.Association.NotLoaded}} =
               Arca.Data.project([%Ecto.Association.NotLoaded{}])
    end

    test "a changeset becomes its field errors, with no raw value and no changeset" do
      changeset =
        {%{}, %{name: :string, count: :integer}}
        |> Ecto.Changeset.cast(%{name: "hunter2-secret", count: 9}, [:name, :count])
        |> Ecto.Changeset.validate_length(:name, max: 3)
        |> Ecto.Changeset.validate_number(:count, less_than: 5)
        |> Ecto.Changeset.add_error(:name, "leaks %{value}", value: "hunter2-secret")

      assert {:error, {:invalid, errors}} = Arca.Data.project({:error, changeset})

      assert %{name: name_errors, count: ["must be less than 5"]} = errors
      assert "should be at most 3 character(s)" in name_errors
      # A placeholder whose option is not a number or an atom stays literal.
      assert "leaks %{value}" in name_errors
      refute inspect(errors) =~ "hunter2"
      assert clean?(errors)
    end
  end

  describe "the facades" do
    setup tags do
      Arca.Test.Sandbox.setup!(tags)
      :ok
    end

    defp server, do: Arca.Test.Actor.platform()

    test "a row read answers a plain map, and a cross-tenant read answers nothing" do
      _ = Arca.Test.Actor.athanor!()
      athanor_id = Arca.Test.Actor.athanor_id()
      {:ok, own} = Arca.Execution.record_start(execution_attrs(athanor_id))

      assert plain?(own)
      refute Map.has_key?(own, :__meta__)
      assert %{id: id} = Arca.Execution.get_tenant(Arca.Test.Actor.local(), own.id)
      assert id == own.id

      elsewhere = Arca.Test.Actor.local(athanor_id: "ath_elsewhere")
      assert Arca.Execution.get_tenant(elsewhere, own.id) == nil

      assert {:error, :no_athanor} =
               Arca.Athanors.current(%Cyfr.Actor{Arca.Test.Actor.local() | athanor_id: nil})

      assert_raise ArgumentError, fn ->
        Arca.Execution.get_tenant(Arca.Test.Actor.local(athanor_id: nil), own.id)
      end
    end

    test "a write the changeset refuses answers field errors, never the changeset" do
      assert {:error, {:invalid, errors}} = Arca.Execution.record_start(%{})
      assert is_map(errors) and Map.has_key?(errors, :id)
      assert clean?(errors)
    end

    test "the mint's in-transaction callback is handed the row as a plain map" do
      n = System.unique_integer([:positive])
      test = self()

      assert {:ok, minted} =
               Arca.Athanors.mint(server(),
                 attrs: fn ->
                   {:ok,
                    %{kind: "group", name: "Data #{n}", slug: "data-#{n}", created_by: "usr_d"}}
                 end,
                 seats: fn athanor ->
                   send(test, {:seated, athanor})
                   :ok
                 end
               )

      assert_received {:seated, handed}
      assert plain?(handed) and clean?(handed)
      assert handed.id == minted.id
      assert plain?(minted) and clean?(minted)
    end

    test "an update is addressed by id and rereads the row; a caller's map is refused" do
      n = System.unique_integer([:positive])

      {:ok, user} =
        Arca.Users.mint(
          server(),
          %{
            id: "usr_data_#{n}",
            email: "d#{n}@example.com",
            provider: "github",
            prefs: "{}",
            first_seen_at: DateTime.utc_now(),
            last_seen_at: DateTime.utc_now(),
            created_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          },
          %{
            key: "github|https://github.com|data#{n}",
            provider: "github",
            issuer: "https://github.com",
            subject: "data#{n}",
            first_seen_at: DateTime.utc_now(),
            last_seen_at: DateTime.utc_now()
          }
        )

      # A stale copy claiming a standing it does not have writes nothing:
      # the map is not an address.
      stale = %{user | status: "denied", display_name: "stale"}

      assert {:error, :not_found} = Arca.Users.update(server(), stale, %{display_name: "renamed"})
      assert {:ok, %{display_name: nil, status: "active"}} = Arca.Users.get(server(), user.id)

      assert {:ok, updated} = Arca.Users.update(server(), user.id, %{display_name: "renamed"})
      assert updated.status == "active"
      assert updated.display_name == "renamed"
      assert {:error, :not_found} = Arca.Users.update(server(), "usr_nobody", %{})
    end

    test "a held claim is read for its identity and fence alone" do
      key = "data-#{System.unique_integer([:positive])}"
      {:ok, held} = Arca.JobClaims.claim("worker_watch", key, "boot_a", 60_000)
      assert plain?(held)

      # A forged lease on the caller's copy decides nothing: the row is
      # reread, and once it has moved on the claim no longer stands.
      :ok = Arca.JobClaims.release(held)
      forged = %{held | lease_until: DateTime.add(DateTime.utc_now(), 3600, :second)}
      refute Arca.JobClaims.live?(forged)

      # A record lands on the row's own columns, whatever else the map says.
      {:ok, again} = Arca.JobClaims.claim("worker_watch", key, "boot_a", 60_000)
      {:ok, recorded} = Arca.JobClaims.record(%{again | detail: "forged"}, "kept")
      assert recorded.detail == "kept"
      assert recorded.fence == again.fence + 1

      assert_raise ArgumentError, fn -> Arca.JobClaims.release(%{kind: "worker_watch"}) end
    end
  end

  defp execution_attrs(athanor_id) do
    %{
      id: "exec_data_#{System.unique_integer([:positive])}",
      reference: "reagent:local.data:1.0.0",
      user_id: "usr_data",
      athanor_id: athanor_id,
      started_at: DateTime.utc_now(),
      status: "running",
      component_type: "reagent"
    }
  end
end
