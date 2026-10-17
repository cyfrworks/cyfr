# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AstraT1bAdoptionSourceReviewTest.ParkRead do
  use Arca.Storage.TestDouble
  @gate {__MODULE__, :gate}
  def arm(parent, path), do: :persistent_term.put(@gate, {parent, path})
  def disarm, do: :persistent_term.erase(@gate)

  def get(actor, path) do
    answer = Arca.Adapters.Local.get(actor, path)

    case :persistent_term.get(@gate, nil) do
      {parent, ^path} ->
        disarm()
        send(parent, {:legacy_read, self(), answer})

        receive do
          :continue -> :ok
        after
          20_000 -> exit(:park_timeout)
        end

      _ ->
        :ok
    end

    answer
  end
end

defmodule Arca.AstraT1bAdoptionSourceReviewTest do
  @moduledoc """
  An adoption paused at its read of the legacy source while a successor
  publishes, releases and is edited. The adoption reads its source under
  the lease it commits under, so the successor is another member's: its
  draft is aged past the lifetime, as a member stalled that long is, and
  the successor runs the public row protocol directly, this node's lock
  being the parked adopter's. The successor's edit is the ordinary facade's.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  alias Arca.AstraT1bAdoptionSourceReviewTest.ParkRead
  alias Arca.Storage.UnitLocator
  alias Arca.StorageProjectionChanges
  alias Arca.StorageUnits

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    base =
      Path.join(System.tmp_dir!(), "astra_adoption_source_#{System.unique_integer([:positive])}")

    actor = Sanctum.Context.actor(Sanctum.TestContext.local())

    previous =
      for key <- [:base_path, :seed_path, :storage_adapter],
          do: {key, Application.fetch_env(:arca, key)}

    on_exit(fn ->
      ParkRead.disarm()

      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:arca, key, value)
          :error -> Application.delete_env(:arca, key)
        end
      end

      Arca.Usage.invalidate(actor)
      File.rm_rf!(base)
    end)

    Application.put_env(:arca, :base_path, Path.join(base, "data"))
    Application.put_env(:arca, :seed_path, Path.join(base, "seed"))
    Application.put_env(:arca, :storage_adapter, ParkRead)
    File.mkdir_p!(Path.join(base, "seed"))
    {:ok, actor: actor}
  end

  test "a legacy adoption paused at its source read cannot replace a completed successor", %{
    actor: actor
  } do
    unit = ["components", "reagents", "local", "astra-adoption-source", "1.0.0"]
    manifest = unit ++ ["cyfr-manifest.json"]

    files = fn version ->
      [{["body.wasm"], "wasm-" <> version}, {["cyfr-manifest.json"], "manifest-" <> version}]
    end

    assert {:ok, _} = Arca.Overlay.commit_unit(actor, unit, {:files, files.("V1")}, cap: :exempt)
    {root, key} = UnitLocator.unit_key(unit)
    assert {:ok, %{current_revision: one}} = Arca.StorageUnits.current(actor, root, key)
    prefix = UnitLocator.revision_prefix(unit, one)
    assert {:ok, leaves} = Arca.Adapters.Local.list_recursive(actor, prefix)

    for leaf <- leaves, List.last(leaf) != UnitLocator.marker_name() do
      assert {:ok, bytes} = Arca.Adapters.Local.get(actor, leaf)
      assert :ok = Arca.Adapters.Local.put(actor, unit ++ Enum.drop(leaf, length(prefix)), bytes)
    end

    assert :ok = Arca.Adapters.Local.delete_tree(actor, prefix)
    assert {:ok, "manifest-V1"} = Arca.get(actor, manifest)

    # The public repair takes its draft, then reads the old manifest under
    # it. Pause at that actual read, so a successor can fully commit,
    # release and acknowledge its edit before repair resumes.
    ParkRead.arm(self(), manifest)
    parent = self()

    {old, monitor} =
      spawn_monitor(fn ->
        send(parent, {:repair, self(), Arca.Overlay.repair_unit(actor, unit)})
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

    assert_receive {:legacy_read, ^old, {:ok, "manifest-V1"}}, 5_000

    # The parked adopter holds the draft; a member stalled this long has
    # outlived it, and a successor takes it over.
    long_ago = DateTime.add(DateTime.utc_now(), -2 * StorageUnits.draft_ttl_ms(), :millisecond)

    assert {1, _} =
             Arca.Repo.update_all(
               from(u in Arca.Schemas.StorageUnit,
                 where:
                   u.athanor_id == ^actor.athanor_id and u.root == ^root and u.unit_key == ^key
               ),
               set: [updated_at: long_ago]
             )

    two = publish_on_other_member(actor, unit, one, files.("V2"))
    refute two == one
    assert :ok = Arca.put(actor, manifest, "manifest-V2-edited")
    assert {:ok, "manifest-V2-edited"} = Arca.get(actor, manifest)

    assert {:ok, %{current_revision: ^two, draft_writer_token: nil}} =
             Arca.StorageUnits.current(actor, root, key)

    send(old, :continue)
    assert_receive {:repair, ^old, {:error, :stale_revision}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^old, :normal}, 5_000

    assert {:ok, "manifest-V2-edited"} = Arca.get(actor, manifest)

    assert {:ok, %{current_revision: ^two, draft_writer_token: nil}} =
             Arca.StorageUnits.current(actor, root, key)

    assert {:ok, "wasm-V2"} = Arca.get(actor, unit ++ ["body.wasm"])
  end

  # A publication on another member, through the public row protocol: the
  # draft taken over, the files staged under a fresh prefix with its
  # marker, the row committed against `prior`, released and marked
  # ready, and the unit's own path cleared as a release with no pin
  # clears it.
  defp publish_on_other_member(actor, unit, prior, files) do
    {root, key} = UnitLocator.unit_key(unit)
    token = StorageUnits.new_writer_token()
    assert {:ok, draft} = StorageUnits.register_draft(actor, root, key, token)
    successor = StorageUnits.new_revision()

    internal = %{
      Prima.Actor.system()
      | athanor_id: actor.athanor_id,
        scope: :athanor,
        user_id: "_overlay"
    }

    manifest =
      Arca.Overlay.with_internal_writes(fn ->
        marker =
          Jason.encode!(%{
            "revision" => successor,
            "prior_revision" => prior,
            "started_at" => DateTime.to_iso8601(DateTime.utc_now())
          })

        assert :ok = Arca.put(internal, UnitLocator.marker_path(unit, successor), marker)

        for {rel, bytes} <- Enum.sort_by(files, &(elem(&1, 0) == ["cyfr-manifest.json"])) do
          assert :ok = Arca.put(internal, UnitLocator.staged_object(unit, successor, rel), bytes)
          {rel, Prima.Digest.sha256(bytes), byte_size(bytes)}
        end
      end)

    assert {:ok, held} = StorageUnits.held(actor, root, key, token)
    assert held.current_revision == prior

    assert {:committed, generation} =
             StorageUnits.stamped_commit(
               actor,
               draft,
               prior,
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
    assert :ok = Arca.Adapters.Local.delete_tree(actor, unit)
    successor
  end
end
