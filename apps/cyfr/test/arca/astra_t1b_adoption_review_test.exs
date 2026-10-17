# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AstraT1bAdoptionReviewTest do
  @moduledoc """
  Two adopters of the same legacy revision. The old adopter is the public
  repair operation, parked after reading its final legacy object and before
  putting those bytes in the revision prefix. Another member's independent
  local lock is simulated only by executing the public row/copy/release
  protocol directly. Its subsequent edit uses the ordinary facade.
  """
  use ExUnit.Case,
    async: false,
    parameterize: [
      %{adapter: Arca.PublicationContract.Double},
      %{adapter: Arca.Adapters.Local}
    ]

  import Ecto.Query, only: [from: 2]
  alias Arca.PublicationContract.Faults
  alias Arca.Storage.UnitLocator
  alias Arca.StorageUnits
  alias Arca.StorageProjectionChanges

  @unit ["components", "catalysts", "local", "astra-adoption", "1.0.0"]
  @manifest @unit ++ ["cyfr-manifest.json"]
  @one ~s({"type":"catalyst","v":1})
  @two ~s({"type":"catalyst","v":2})

  setup %{adapter: adapter} = tags do
    Cyfr.Test.Sandbox.setup!(tags)
    base = Path.join(System.tmp_dir!(), "astra_adoption_#{System.unique_integer([:positive])}")

    previous =
      for key <- [:base_path, :seed_path, :storage_adapter],
          do: {key, Application.fetch_env(:arca, key)}

    on_exit(fn ->
      Faults.unwrap()

      for {key, prior} <- previous do
        case prior do
          {:ok, value} -> Application.put_env(:arca, key, value)
          :error -> Application.delete_env(:arca, key)
        end
      end

      File.rm_rf!(base)
    end)

    File.mkdir_p!(Path.join(base, "seed"))
    Application.put_env(:arca, :base_path, Path.join(base, "data"))
    Application.put_env(:arca, :seed_path, Path.join(base, "seed"))
    Faults.wrap(adapter)
    Application.put_env(:arca, :storage_adapter, Faults)
    {:ok, actor: Sanctum.Context.actor(Sanctum.TestContext.local())}
  end

  test "a resumed stale legacy adopter preserves the completed successor adopter's edit", %{
    actor: actor,
    adapter: adapter
  } do
    assert {:ok, _} =
             Arca.Overlay.commit_unit(
               actor,
               @unit,
               {:files, [{["catalyst.wasm"], "WASM"}, {["cyfr-manifest.json"], @one}]},
               cap: :exempt
             )

    {root, key} = UnitLocator.unit_key(@unit)
    assert {:ok, %{current_revision: revision}} = StorageUnits.current(actor, root, key)
    prefix = UnitLocator.revision_prefix(@unit, revision)

    # Recreate exactly T1's completed representation: committed row, own-path
    # objects, no revision prefix. Direct adapter writes are fixture setup only.
    assert {:ok, leaves} = adapter.list_recursive(actor, prefix)

    for leaf <- leaves, List.last(leaf) != UnitLocator.marker_name() do
      assert {:ok, bytes} = adapter.get(actor, leaf)
      assert :ok = adapter.put(actor, @unit ++ Enum.drop(leaf, length(prefix)), bytes)
    end

    assert :ok = adapter.delete_tree(actor, prefix)
    assert {:ok, @one} = Arca.get(actor, @manifest)

    parent = self()

    {old, monitor} =
      spawn_monitor(fn ->
        receive do
          :start -> send(parent, {:answer, self(), Arca.Overlay.repair_unit(actor, @unit)})
        end
      end)

    on_exit(fn ->
      ref = Process.monitor(old)
      Process.exit(old, :kill)

      receive do
        {:DOWN, ^ref, :process, ^old, _} -> :ok
      after
        5_000 -> raise "old adopter did not stop"
      end
    end)

    # The adoption stages the legacy objects under a prefix of its own; the
    # old adopter parks at its put of the manifest there, its last.
    Faults.inject(fn op, path ->
      if self() == old and op == :put and UnitLocator.staging?(path) and
           List.last(path) == "cyfr-manifest.json" do
        send(parent, {:parked, self()})

        receive do
          :proceed -> :pass
        after
          30_000 -> raise "old adopter was not resumed"
        end
      else
        :pass
      end
    end)

    send(old, :start)
    assert_receive {:parked, ^old}, 10_000
    Faults.clear()

    long_ago = DateTime.add(DateTime.utc_now(), -2 * StorageUnits.draft_ttl_ms(), :millisecond)

    assert {1, _} =
             Arca.Repo.update_all(
               from(u in Arca.Schemas.StorageUnit,
                 where:
                   u.athanor_id == ^actor.athanor_id and u.root == ^root and u.unit_key == ^key
               ),
               set: [updated_at: long_ago]
             )

    successor = adopt_on_other_member(actor, adapter, revision)
    refute successor == revision
    assert :ok = Arca.put(actor, @manifest, @two)
    assert {:ok, @two} = Arca.get(actor, @manifest)

    assert {:ok, %{current_revision: ^successor, draft_writer_token: nil}} =
             StorageUnits.current(actor, root, key)

    send(old, :proceed)
    assert_receive {:answer, ^old, {:error, :stale_revision}}, 10_000
    assert_receive {:DOWN, ^monitor, :process, ^old, :normal}, 5_000

    assert {:ok, %{current_revision: ^successor, draft_writer_token: nil}} =
             StorageUnits.current(actor, root, key)

    assert {:ok, :nothing_pending} = Arca.Overlay.repair_unit(actor, @unit)
    assert {:ok, @two} = Arca.get(actor, @manifest)
  end

  defp adopt_on_other_member(actor, adapter, revision) do
    {root, key} = UnitLocator.unit_key(@unit)
    token = StorageUnits.new_writer_token()
    assert {:ok, draft} = StorageUnits.register_draft(actor, root, key, token)
    successor = StorageUnits.new_revision()

    internal = %{
      Prima.Actor.system()
      | athanor_id: actor.athanor_id,
        scope: :athanor,
        user_id: "_overlay"
    }

    assert {:ok, leaves} = adapter.list_recursive(actor, @unit)

    manifest =
      Arca.Overlay.with_internal_writes(fn ->
        marker =
          Jason.encode!(%{
            "revision" => successor,
            "prior_revision" => revision,
            "started_at" => DateTime.to_iso8601(DateTime.utc_now())
          })

        assert :ok = Arca.put(internal, UnitLocator.marker_path(@unit, successor), marker)

        for leaf <- Enum.sort_by(leaves, &(&1 == @manifest)) do
          assert {:ok, bytes} = adapter.get(actor, leaf)
          rel = Enum.drop(leaf, length(@unit))
          assert :ok = Arca.put(internal, UnitLocator.staged_object(@unit, successor, rel), bytes)
          {rel, Prima.Digest.sha256(bytes), byte_size(bytes)}
        end
      end)

    assert {:ok, held} = StorageUnits.held(actor, root, key, token)
    assert held.current_revision == revision

    assert {:committed, generation} =
             StorageUnits.stamped_commit(
               actor,
               draft,
               revision,
               token,
               %{
                 new_revision: successor,
                 content_identity: Arca.Overlay.content_identity(manifest),
                 commit_identity: actor.user_id
               },
               []
             )

    assert :ok = StorageUnits.release_served(actor, held, token, successor)
    assert :ok = StorageProjectionChanges.mark_ready(actor, root, key, generation, successor)
    assert :ok = adapter.delete_tree(actor, @unit)
    successor
  end
end
