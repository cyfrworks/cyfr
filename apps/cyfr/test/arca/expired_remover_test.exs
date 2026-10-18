# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExpiredRemoverTest.ParkDelete do
  @moduledoc false
  use Arca.Storage.TestDouble
  @gate {__MODULE__, :gate}
  def arm(test, writer, path), do: :persistent_term.put(@gate, {test, writer, path})
  def disarm, do: :persistent_term.erase(@gate)

  def delete_tree(actor, path) do
    case :persistent_term.get(@gate, nil) do
      {test, writer, ^path} when writer == self() ->
        disarm()
        send(test, {:deleting, self()})

        receive do
          :proceed -> :ok
        after
          20_000 -> exit(:park_timeout)
        end

      _ ->
        :ok
    end

    Arca.Adapters.Local.delete_tree(actor, path)
  end
end

defmodule Arca.ExpiredRemoverTest do
  use ExUnit.Case, async: false
  import Ecto.Query, only: [from: 2]
  alias Arca.ExpiredRemoverTest.ParkDelete
  alias Arca.Schemas.StorageUnit
  alias Arca.Storage.UnitLocator
  alias Arca.StorageUnits

  @unit ["components", "catalysts", "local", "expired-remover", "1.0.0"]
  @wasm @unit ++ ["catalyst.wasm"]

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    base = Path.join(System.tmp_dir!(), "expired_remover_#{System.unique_integer([:positive])}")

    previous =
      for key <- [:base_path, :seed_path, :storage_adapter],
          do: {key, Application.get_env(:arca, key)}

    on_exit(fn ->
      ParkDelete.disarm()
      for {key, value} <- previous, do: Application.put_env(:arca, key, value)
      File.rm_rf!(base)
    end)

    File.mkdir_p!(Path.join(base, "seed"))
    Application.put_env(:arca, :base_path, Path.join(base, "data"))
    Application.put_env(:arca, :seed_path, Path.join(base, "seed"))
    Application.put_env(:arca, :storage_adapter, ParkDelete)
    {:ok, actor: Sanctum.Context.actor(Sanctum.TestContext.local())}
  end

  defp commit(actor, version, opts \\ []) do
    Arca.Overlay.commit_unit(
      actor,
      @unit,
      {:files,
       [
         {["cyfr-manifest.json"], ~s({"type":"catalyst","v":#{version}})},
         {["catalyst.wasm"], "V#{version}"}
       ]},
      [cap: :exempt] ++ opts
    )
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

  # A removal of the unit, parked at the tenant's delete of `path`.
  defp park_delete(actor, path) do
    test = self()

    task =
      worker(fn ->
        ParkDelete.arm(test, self(), path)
        Arca.delete_tree(actor, @unit)
      end)

    assert_receive {:deleting, pid}, 5_000
    {task, pid}
  end

  defp until(fun, tries \\ 100)
  defp until(_fun, 0), do: false

  defp until(fun, tries) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          until(fun, tries - 1)
        )
  end

  test "an expired remover cannot delete a successor's committed staging", %{actor: actor} do
    assert {:ok, _} = commit(actor, 1)
    {:ok, %{current_revision: before}} = pointer(actor)
    {removal, remover} = park_delete(actor, UnitLocator.revision_prefix(@unit, before))
    expire(actor)
    publication = worker(fn -> commit(actor, 2) end)

    advanced =
      until(fn ->
        match?({:ok, %{current_revision: revision}} when revision != before, pointer(actor))
      end)

    send(remover, :proceed)
    dropped = answer(removal)
    published = answer(publication)
    # Refusing or blocking a takeover until deletion ends is also safe.
    published = if published == {:error, :stale_writer}, do: commit(actor, 2), else: published
    served = Arca.get(actor, @wasm)
    staged = Arca.list_recursive(actor, UnitLocator.staging_prefix(@unit))
    observed = %{advanced: advanced, drop: dropped, publish: published, staging: staged}

    assert {:ok, _} = published, inspect(observed)
    assert {:ok, "V2"} = served, inspect(observed)
    assert {:ok, %{current_revision: successor}} = pointer(actor)
    assert successor != before
  end
end
