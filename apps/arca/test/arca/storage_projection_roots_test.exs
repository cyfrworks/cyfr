# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StorageProjectionRootsTest do
  @moduledoc """
  A seeded root's epoch: raised by one in the transaction of every change
  of a unit under it, the generation that change takes, never lowered,
  per athanor and root. A replacement made against an epoch the root has
  moved past writes nothing — even when the unit that moved it is one the
  replacement never named.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{StorageProjectionChange, StorageProjectionRoot}
  alias Arca.{StorageProjectionChanges, StorageProjectionRoots}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    athanor = "ath_roots_#{System.unique_integer([:positive])}"
    {:ok, actor: %Prima.Actor{athanor_id: athanor, user_id: "usr_roots"}, athanor: athanor}
  end

  defp change(key, attrs \\ %{}),
    do: Map.merge(%{unit_key: key, ready: false, tombstone: false, source_revision: nil}, attrs)

  defp advance(actor, root, change) do
    {:ok, generation} =
      Arca.Repo.locking_transaction(fn -> StorageProjectionRoots.advance!(actor, root, change) end)

    generation
  end

  describe "advance!/3" do
    test "raises the root's epoch by one and stamps the unit's change at it", %{actor: actor} do
      assert {:ok, %{epoch: 0, acknowledged_epoch: 0}} =
               StorageProjectionRoots.epoch(actor, "components")

      first = advance(actor, "components", change("catalysts/local/a/1.0.0"))
      second = advance(actor, "components", change("catalysts/local/b/1.0.0", %{ready: true}))

      assert second == first + 1
      assert {:ok, %{epoch: ^second, acknowledged_epoch: 0}} =
               StorageProjectionRoots.epoch(actor, "components")

      assert {:ok, %{epoch: ^second, units: units}} =
               StorageProjectionChanges.snapshot(actor, "components")

      assert [
               %{unit_key: "catalysts/local/a/1.0.0", generation: ^first, ready: false},
               %{unit_key: "catalysts/local/b/1.0.0", generation: ^second, ready: true}
             ] = units
    end

    test "counts each athanor and each root on its own", %{actor: actor} do
      other = %{actor | athanor_id: actor.athanor_id <> "_other"}

      a = advance(actor, "components", change("catalysts/local/a/1.0.0"))
      aqua = advance(actor, "aqua", change("roles/a.md"))
      theirs = advance(other, "components", change("catalysts/local/a/1.0.0"))

      assert aqua == a
      assert theirs == a
      assert {:ok, %{epoch: ^a}} = StorageProjectionRoots.epoch(actor, "components")
      assert {:ok, %{epoch: ^a}} = StorageProjectionRoots.epoch(other, "components")
    end

    test "a later change of a unit takes a newer generation and keeps what was acknowledged",
         %{actor: actor, athanor: athanor} do
      key = "catalysts/local/a/1.0.0"
      first = advance(actor, "components", change(key, %{ready: true}))

      {:ok, token} = StorageProjectionChanges.snapshot(actor, "components")
      {:ok, :done} = StorageProjectionChanges.replace(actor, "components", token, fn -> :done end)

      second = advance(actor, "components", change(key, %{tombstone: true}))
      assert second > first

      assert %{generation: ^second, acknowledged_generation: ^first, tombstone: true} =
               Arca.Repo.one(
                 from(c in StorageProjectionChange,
                   where: c.athanor_id == ^athanor and c.unit_key == ^key
                 )
               )
    end

    test "runs only inside a transaction, and only for an actor with an athanor", %{actor: actor} do
      assert_raise ArgumentError, ~r/inside the transaction/, fn ->
        StorageProjectionRoots.advance!(actor, "components", change("catalysts/local/a/1.0.0"))
      end

      nobody = %Prima.Actor{athanor_id: nil}

      assert_raise ArgumentError, ~r/resolved athanor/, fn ->
        Arca.Repo.locking_transaction(fn ->
          StorageProjectionRoots.advance!(nobody, "components", change("catalysts/local/a/1.0.0"))
        end)
      end

      assert {:error, :no_athanor} = StorageProjectionRoots.epoch(nobody, "components")
      assert {:error, :no_athanor} = StorageProjectionRoots.epoch(%{nobody | athanor_id: ""}, "aqua")
    end

    test "a change that rolls back takes its epoch back with it", %{actor: actor} do
      before = advance(actor, "components", change("catalysts/local/a/1.0.0"))

      assert {:error, :refused} =
               Arca.Repo.locking_transaction(fn ->
                 StorageProjectionRoots.advance!(actor, "components", change("catalysts/local/b/1.0.0"))
                 Arca.Repo.rollback(:refused)
               end)

      assert {:ok, %{epoch: ^before}} = StorageProjectionRoots.epoch(actor, "components")
      assert {:ok, %{units: [%{unit_key: "catalysts/local/a/1.0.0"}]}} =
               StorageProjectionChanges.snapshot(actor, "components")
    end
  end

  describe "a phantom insert" do
    test "a unit created after the snapshot invalidates the replacement it never named", %{
      actor: actor
    } do
      key = "roles/scribe.md"
      advance(actor, "aqua", change(key, %{ready: true}))
      {:ok, token} = StorageProjectionChanges.snapshot(actor, "aqua")
      assert Enum.map(token.units, & &1.unit_key) == [key]

      # A new unit, after the snapshot and absent from it.
      created = advance(actor, "aqua", change("roles/latecomer.md", %{ready: true}))

      assert {:error, :generation_conflict} =
               StorageProjectionChanges.replace(actor, "aqua", token, fn -> :written end)

      # Nothing was acknowledged: the unit the token did name stays pending
      # too, and the root is behind.
      assert {:ok, %{epoch: ^created, acknowledged_epoch: 0}} =
               StorageProjectionRoots.epoch(actor, "aqua")

      assert {:ok, %{units: units}} = StorageProjectionChanges.snapshot(actor, "aqua")
      assert Enum.all?(units, &(&1.pending and &1.acknowledged_generation == 0))
    end

    test "so does the first unit of a root no change had touched", %{actor: actor} do
      {:ok, token} = StorageProjectionChanges.snapshot(actor, "aqua")
      assert %{epoch: 0, units: []} = token

      advance(actor, "aqua", change("roles/first.md", %{ready: true}))

      assert {:error, :generation_conflict} =
               StorageProjectionChanges.replace(actor, "aqua", token, fn -> :written end)
    end
  end

  describe "concurrent writers, on two connections" do
    # Outside the sandbox: inside it one shared connection would serialize
    # the transactions the test is about. Every row is this case's athanor's
    # and goes with it.
    setup %{athanor: athanor} do
      Ecto.Adapters.SQL.Sandbox.checkin(Arca.Repo)

      on_exit(fn ->
        unboxed(fn ->
          for schema <- [StorageProjectionChange, StorageProjectionRoot] do
            Arca.Repo.delete_all(from(r in schema, where: r.athanor_id == ^athanor))
          end
        end)
      end)

      :ok
    end

    defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, fun)

    test "an advance waits for a replacement holding the root, then takes the next epoch", %{
      actor: actor
    } do
      test = self()
      first = unboxed(fn -> advance(actor, "aqua", change("roles/a.md", %{ready: true})) end)
      {:ok, token} = unboxed(fn -> StorageProjectionChanges.snapshot(actor, "aqua") end)

      replacement =
        Task.async(fn ->
          unboxed(fn ->
            StorageProjectionChanges.replace(actor, "aqua", token, fn ->
              send(test, :holding)

              receive do
                :commit -> :replaced
              end
            end)
          end)
        end)

      assert_receive :holding, 5_000

      writer =
        Task.async(fn ->
          unboxed(fn -> advance(actor, "aqua", change("roles/b.md", %{ready: true})) end)
        end)

      refute Task.yield(writer, 300), "the advance landed while the replacement held the root"

      send(replacement.pid, :commit)
      assert {:ok, :replaced} = Task.await(replacement, 25_000)
      assert Task.await(writer, 25_000) == first + 1

      # The replacement acknowledged what it saw, and the advance stands
      # pending beyond it.
      assert {:ok, %{epoch: epoch, acknowledged_epoch: ^first}} =
               unboxed(fn -> StorageProjectionRoots.epoch(actor, "aqua") end)

      assert epoch == first + 1
    end

    test "racing advances of one root each take a generation of their own", %{actor: actor} do
      generations =
        1..6
        |> Enum.map(fn i ->
          Task.async(fn ->
            unboxed(fn -> advance(actor, "components", change("catalysts/local/u#{i}/1.0.0")) end)
          end)
        end)
        |> Task.await_many(30_000)

      assert generations |> Enum.uniq() |> length() == 6

      assert {:ok, %{epoch: epoch}} =
               unboxed(fn -> StorageProjectionRoots.epoch(actor, "components") end)

      assert epoch == Enum.max(generations)
    end
  end
end
