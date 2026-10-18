# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.UnitSuccessorMembersTest.ParkIO do
  @moduledoc false
  # Like S3, this double cannot swap a tree. It parks the armed writer
  # once: at its delete of a tree — a removal's delete of the retired
  # revision's prefix — or at its put of a staged manifest — the last
  # object a publication stages.
  use Arca.Storage.TestDouble
  @gate {__MODULE__, :gate}

  def arm(test, writer, operation), do: :persistent_term.put(@gate, {test, writer, operation})
  def disarm, do: :persistent_term.erase(@gate)

  def replace_tree(_actor, _path, _files), do: {:error, :atomic_replace_unsupported}

  def put(actor, path, bytes) do
    if Arca.Storage.UnitLocator.staging?(path) and List.last(path) == "cyfr-manifest.json",
      do: park(:staged_manifest)

    Arca.Adapters.Local.put(actor, path, bytes)
  end

  def delete_tree(actor, path) do
    park(:delete)
    Arca.Adapters.Local.delete_tree(actor, path)
  end

  defp park(operation) do
    case :persistent_term.get(@gate, nil) do
      {test, writer, ^operation} when writer == self() ->
        disarm()
        send(test, {:at_storage, self(), operation})

        receive do
          :proceed -> :ok
        after
          20_000 -> exit(:park_timeout)
        end

      _ ->
        :ok
    end
  end
end

defmodule Arca.UnitSuccessorMembersTest do
  @moduledoc """
  A deterministic simulation of another member's independent lock, over
  units served from their revision prefixes. The old writer or remover runs the actual
  public overlay operation and is parked where it last touches the store
  or the rows before its release; the successor runs its public row and
  prefix protocol, omitting only the node-local overlay lock, which
  another member would hold on its own node, and writes nothing at the
  unit's own path, since nothing does. The adapter emulates an object
  store's lack of a tree swap over Local-backed objects. This is not an
  actual two-member or S3 integration test.
  """
  use ExUnit.Case, async: false
  import Ecto.Query, only: [from: 2]
  alias Arca.UnitSuccessorMembersTest.ParkIO
  alias Arca.Schemas.StorageUnit
  alias Arca.Storage.UnitLocator
  alias Arca.StorageUnits

  @unit ["components", "catalysts", "local", "astra-crossmember", "1.0.0"]
  @wasm @unit ++ ["catalyst.wasm"]

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    base = Path.join(System.tmp_dir!(), "astra_crossmember_#{System.unique_integer([:positive])}")

    previous =
      for key <- [:base_path, :seed_path, :storage_adapter],
          do: {key, Application.fetch_env(:arca, key)}

    on_exit(fn ->
      ParkIO.disarm()

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
    Application.put_env(:arca, :storage_adapter, ParkIO)
    {:ok, actor: Sanctum.Context.actor(Sanctum.TestContext.local())}
  end

  defp files(version),
    do: [
      {["catalyst.wasm"], "V#{version}"},
      {["cyfr-manifest.json"], ~s({"type":"catalyst","v":#{version}})}
    ]

  defp commit(actor, version) do
    Arca.Overlay.commit_unit(actor, @unit, {:files, files(version)}, cap: :exempt)
  end

  defp pointer(actor) do
    {root, key} = UnitLocator.unit_key(@unit)
    StorageUnits.current(actor, root, key)
  end

  defp expire(actor) do
    {root, key} = UnitLocator.unit_key(@unit)
    then_time = DateTime.add(DateTime.utc_now(), -2 * StorageUnits.draft_ttl_ms(), :millisecond)

    {1, _} =
      Arca.Repo.update_all(
        from(u in StorageUnit,
          where: u.athanor_id == ^actor.athanor_id and u.root == ^root and u.unit_key == ^key
        ),
        set: [updated_at: then_time]
      )
  end

  # The revisions with objects under the unit's staging area.
  defp staged(actor) do
    prefix = UnitLocator.staging_prefix(@unit)
    {:ok, leaves} = Arca.list_recursive(actor, prefix)
    leaves |> Enum.map(&Enum.at(&1, length(prefix))) |> Enum.uniq() |> Enum.sort()
  end

  defp worker(fun) do
    test = self()

    pid =
      spawn(fn ->
        receive do
          :start -> send(test, {:answer, self(), fun.()})
        end
      end)

    ref = Process.monitor(pid)

    on_exit(fn ->
      watched = Process.monitor(pid)
      if Process.alive?(pid), do: Process.exit(pid, :kill)

      receive do
        {:DOWN, ^watched, :process, ^pid, _} -> :ok
      after
        5_000 -> raise "test worker did not stop"
      end
    end)

    send(pid, :start)
    {pid, ref}
  end

  defp answer({pid, ref}) do
    assert_receive {:answer, ^pid, result}, 20_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    result
  end

  # A publication parked between its commit and its release: the commit's
  # announcement runs in the writer's process, after the pointer moved
  # and before the draft is given back.
  defp park_after_commit(actor, version) do
    test = self()
    handler = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(handler) end)
    {root, key} = UnitLocator.unit_key(@unit)

    :ok =
      :telemetry.attach(
        handler,
        Arca.StorageProjectionChanges.event(),
        fn _event, _measurements, metadata, _config ->
          if metadata.athanor_id == actor.athanor_id and metadata.root == root and
               not metadata.ready and self() != test and
               match?({:ok, _committed}, StorageUnits.current(actor, root, key)) do
            :telemetry.detach(handler)
            send(test, {:at_commit, self()})

            receive do
              :proceed -> :ok
            after
              20_000 -> exit(:park_timeout)
            end
          end
        end,
        nil
      )

    task = worker(fn -> commit(actor, version) end)
    {pid, _ref} = task
    assert_receive {:at_commit, ^pid}, 5_000
    task
  end

  # A publication parked at its last staged write, the sentinel, before
  # validation and the commit.
  defp park_at_last_staged_write(actor, version) do
    test = self()

    task =
      worker(fn ->
        ParkIO.arm(test, self(), :staged_manifest)
        commit(actor, version)
      end)

    {pid, _ref} = task
    assert_receive {:at_storage, ^pid, :staged_manifest}, 5_000
    task
  end

  # A removal parked at its delete of the retired revision's prefix.
  defp park_delete(_actor, fun) do
    test = self()

    task =
      worker(fn ->
        ParkIO.arm(test, self(), :delete)
        fun.()
      end)

    {pid, _ref} = task
    assert_receive {:at_storage, ^pid, :delete}, 5_000
    task
  end

  defp finish({pid, _ref} = task) do
    send(pid, :proceed)
    answer(task)
  end

  # Same stage/commit/release/mark as a successful overlay publisher on a
  # second member, through the public row and prefix protocol alone; no
  # object is written at the unit's own path, since nothing does.
  defp publish_on_other_member(actor, version) do
    {root, key} = UnitLocator.unit_key(@unit)
    token = StorageUnits.new_writer_token()
    revision = StorageUnits.new_revision()

    internal = %{
      Prima.Actor.system()
      | athanor_id: actor.athanor_id,
        scope: :athanor,
        user_id: "_overlay"
    }

    objects = files(version)
    assert {:ok, draft} = StorageUnits.register_draft(actor, root, key, token)

    Arca.Overlay.with_internal_writes(fn ->
      marker =
        Jason.encode!(%{
          "revision" => revision,
          "prior_revision" => draft.current_revision,
          "started_at" => DateTime.to_iso8601(DateTime.utc_now())
        })

      assert :ok = Arca.put(internal, UnitLocator.marker_path(@unit, revision), marker)

      for {rel, bytes} <- objects do
        path = UnitLocator.staged_object(@unit, revision, rel)
        assert :ok = Arca.put(internal, path, bytes)
        assert {:ok, ^bytes} = Arca.get(internal, path)
      end

      identity = %{
        new_revision: revision,
        content_identity:
          Arca.Overlay.content_identity(
            for {rel, bytes} <- objects, do: {rel, Prima.Digest.sha256(bytes), byte_size(bytes)}
          ),
        commit_identity: actor.user_id || "system"
      }

      assert {:committed, generation} =
               StorageUnits.stamped_commit(actor, draft, draft.current_revision, token, identity)

      assert {:ok, held} = StorageUnits.held(actor, root, key, token)
      assert held.current_revision == revision
      assert :ok = StorageUnits.release_served(actor, held, token, revision)

      assert :ok =
               Arca.StorageProjectionChanges.mark_ready(actor, root, key, generation, revision)
    end)

    assert {:ok, "V#{version}"} == Arca.get(actor, @wasm)

    assert {:ok, %{current_revision: ^revision, draft_writer_token: nil}} =
             StorageUnits.current(actor, root, key)

    revision
  end

  test "a resumed old finisher preserves a successor fully served by another member", %{
    actor: actor
  } do
    old = park_after_commit(actor, 1)
    {:ok, %{current_revision: first}} = pointer(actor)
    expire(actor)
    successor = publish_on_other_member(actor, 2)

    assert {:error, :stale_writer} = finish(old)
    {root, key} = UnitLocator.unit_key(@unit)

    assert {:ok, %{current_revision: ^successor, draft_writer_token: nil}} =
             StorageUnits.current(actor, root, key)

    assert {:ok, "V2"} = Arca.get(actor, @wasm)
    assert {:ok, :nothing_pending} = Arca.Overlay.repair_unit(actor, @unit)
    # The stalled writer's revision stays for the collector, beside the successor's.
    assert first in staged(actor)
    assert successor in staged(actor)
  end

  test "a stale commit after a successor's publication refuses, and serves nothing", %{
    actor: actor
  } do
    old = park_at_last_staged_write(actor, 1)
    expire(actor)
    successor = publish_on_other_member(actor, 2)

    assert finish(old) in [{:error, :stale_revision}, {:error, :stale_writer}]
    assert {:ok, %{current_revision: ^successor}} = pointer(actor)
    assert {:ok, "V2"} = Arca.get(actor, @wasm)
    assert {:ok, :nothing_pending} = Arca.Overlay.repair_unit(actor, @unit)
    # The refused revision's objects were discarded with it.
    assert staged(actor) == [successor]
  end

  test "a resumed old remover preserves a successor fully served by another member", %{
    actor: actor
  } do
    assert {:ok, _} = commit(actor, 1)
    {:ok, %{current_revision: first}} = pointer(actor)
    old = park_delete(actor, fn -> Arca.delete_tree(actor, @unit) end)
    expire(actor)
    successor = publish_on_other_member(actor, 2)

    assert {:error, :stale_writer} = finish(old)
    {root, key} = UnitLocator.unit_key(@unit)
    assert {:ok, %{current_revision: ^successor}} = StorageUnits.current(actor, root, key)
    assert {:ok, "V2"} = Arca.get(actor, @wasm)
    assert {:ok, :nothing_pending} = Arca.Overlay.repair_unit(actor, @unit)
    # The resumed removal deleted the revision it retired and nothing else.
    refute first in staged(actor)
    assert successor in staged(actor)
  end
end
