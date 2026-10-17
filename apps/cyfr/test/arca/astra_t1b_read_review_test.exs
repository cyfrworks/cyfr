# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AstraT1bReadReviewTest.ParkRead do
  use Arca.Storage.TestDouble
  @gate {__MODULE__, :gate}
  def arm(parent, prefix), do: :persistent_term.put(@gate, {parent, prefix})
  def disarm, do: :persistent_term.erase(@gate)

  def get(actor, path) do
    answer = Arca.Adapters.Local.get(actor, path)

    case :persistent_term.get(@gate, nil) do
      {parent, prefix} ->
        if List.starts_with?(path, prefix) do
          disarm()
          send(parent, {:read_first, self(), path, answer})

          receive do
            :continue -> :ok
          after
            20_000 -> exit(:park_timeout)
          end
        end

      nil ->
        :ok
    end

    answer
  end
end

defmodule Arca.AstraT1bReadReviewTest do
  use ExUnit.Case, async: false
  alias Arca.AstraT1bReadReviewTest.ParkRead
  alias Arca.Storage.UnitLocator

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    base = Path.join(System.tmp_dir!(), "astra_t1b_read_#{System.unique_integer([:positive])}")
    actor = Sanctum.Context.actor(Sanctum.TestContext.local())

    previous =
      for key <- [:base_path, :seed_path, :storage_adapter, :read_subtree_concurrency],
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
    Application.put_env(:arca, :read_subtree_concurrency, 1)
    File.mkdir_p!(Path.join(base, "seed"))
    {:ok, actor: actor}
  end

  test "a subtree read keeps the revision it resolved across a whole-unit commit", %{actor: actor} do
    unit = ["components", "reagents", "local", "astra-read-revision", "1.0.0"]

    files = fn version ->
      for name <- ["a.txt", "b.txt", "cyfr-manifest.json"], do: {[name], version}
    end

    assert {:ok, _} = Arca.Overlay.commit_unit(actor, unit, {:files, files.("V1")}, cap: :exempt)
    {root, key} = UnitLocator.unit_key(unit)
    assert {:ok, %{current_revision: one}} = Arca.StorageUnits.current(actor, root, key)
    ParkRead.arm(self(), UnitLocator.revision_prefix(unit, one))
    reader = Task.async(fn -> Arca.read_subtree(actor, unit) end)
    on_exit(fn -> if Process.alive?(reader.pid), do: Process.exit(reader.pid, :kill) end)
    assert_receive {:read_first, leaf, _path, {:ok, "V1"}}, 5_000
    assert {:ok, _} = Arca.Overlay.commit_unit(actor, unit, {:files, files.("V2")}, cap: :exempt)
    send(leaf, :continue)
    assert {:ok, pairs} = Task.await(reader, 5_000)
    assert Map.new(pairs) == Map.new(files.("V1"))
  end
end
