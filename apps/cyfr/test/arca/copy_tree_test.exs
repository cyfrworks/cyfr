# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CopyTreeTest.RecordingAdapter do
  @moduledoc false
  # Delegates to the Local adapter but records every put — stands in for an
  # object store so the bundle→storage seeding seam is exercised with a
  # non-default adapter configured.
  use Arca.Storage.TestDouble

  def put(ctx, path, content) do
    if pid = Process.whereis(:copy_tree_recorder), do: send(pid, {:adapter_put, path})
    Arca.Adapters.Local.put(ctx, path, content)
  end
end

defmodule Arca.CopyTreeTest.VanishingAdapter do
  @moduledoc false
  # Lists one leaf more than exists, so the copy meets a file that vanished
  # between the walk and its read.
  use Arca.Storage.TestDouble

  def list_recursive(ctx, path) do
    with {:ok, leaves} <- Arca.Adapters.Local.list_recursive(ctx, path) do
      {:ok, leaves ++ [path ++ ["ghost.txt"]]}
    end
  end
end

defmodule Arca.CopyTreeTest do
  @moduledoc """
  `Arca.copy_tree/3` is the tree-copy primitive under overlay
  materialization and fork: the source is read per-path (the seed bundle
  stays pinned to local disk), the destination is written per-path through
  the configured adapter.
  """

  use ExUnit.Case, async: false

  setup do
    base = Path.join(System.tmp_dir!(), "copy_tree_#{System.unique_integer([:positive])}")
    seed = Path.join(base, "seed")
    bundle = Path.join(seed, "components")
    File.mkdir_p!(bundle)

    prev_base = Application.fetch_env!(:cyfr, :base_path)
    prev_seed = Application.fetch_env!(:cyfr, :seed_path)
    Application.put_env(:cyfr, :base_path, Path.join(base, "data"))
    Application.put_env(:cyfr, :seed_path, seed)

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      Application.put_env(:cyfr, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    {:ok, bundle: bundle}
  end

  test "copies a subtree preserving relative layout, source untouched" do
    ctx = Sanctum.TestContext.local()
    :ok = Arca.put(ctx, ["guest", "src", "a.txt"], "A")
    :ok = Arca.put(ctx, ["guest", "src", "sub", "b.txt"], "B")

    assert {:ok, _} = Arca.copy_tree(ctx, ["guest", "src"], ["guest", "dest"])

    assert {:ok, "A"} = Arca.get(ctx, ["guest", "dest", "a.txt"])
    assert {:ok, "B"} = Arca.get(ctx, ["guest", "dest", "sub", "b.txt"])
    assert {:ok, "A"} = Arca.get(ctx, ["guest", "src", "a.txt"])
  end

  test "exclude: skips matching files before their content is read" do
    ctx = Sanctum.TestContext.local()
    :ok = Arca.put(ctx, ["guest", "src", "a.txt"], "A")
    :ok = Arca.put(ctx, ["guest", "src", "target", "debug", "junk.o"], "JUNK")

    exclude = fn relative -> "target" in relative end
    assert {:ok, _} = Arca.copy_tree(ctx, ["guest", "src"], ["guest", "dest"], exclude: exclude)

    assert {:ok, "A"} = Arca.get(ctx, ["guest", "dest", "a.txt"])
    assert {:error, :not_found} = Arca.get(ctx, ["guest", "dest", "target", "debug", "junk.o"])
  end

  test "a file that vanishes between the walk and its read is skipped, not fatal" do
    prev_adapter = Application.get_env(:cyfr, :storage_adapter)
    Application.put_env(:cyfr, :storage_adapter, Arca.CopyTreeTest.VanishingAdapter)

    on_exit(fn ->
      if prev_adapter,
        do: Application.put_env(:cyfr, :storage_adapter, prev_adapter),
        else: Application.delete_env(:cyfr, :storage_adapter)
    end)

    ctx = Sanctum.TestContext.local()
    :ok = Arca.put(ctx, ["guest", "src", "a.txt"], "A")

    assert {:ok, _} = Arca.copy_tree(ctx, ["guest", "src"], ["guest", "dest"])
    assert {:ok, "A"} = Arca.get(ctx, ["guest", "dest", "a.txt"])
    assert {:error, :not_found} = Arca.get(ctx, ["guest", "dest", "ghost.txt"])
  end

  test "materializes bundle bytes through the configured adapter, reading seed in place", %{
    bundle: bundle
  } do
    # The overlay-materialization contract on an object-store deployment:
    # the bundle is read from local disk and only the copies reach the
    # adapter.
    version_dir = Path.join([bundle, "catalysts", "local", "x", "1.0.0"])
    File.mkdir_p!(version_dir)
    File.write!(Path.join(version_dir, "cyfr-manifest.json"), "{}")

    prev_adapter = Application.get_env(:cyfr, :storage_adapter)
    Application.put_env(:cyfr, :storage_adapter, Arca.CopyTreeTest.RecordingAdapter)

    on_exit(fn ->
      if prev_adapter,
        do: Application.put_env(:cyfr, :storage_adapter, prev_adapter),
        else: Application.delete_env(:cyfr, :storage_adapter)
    end)

    Process.register(self(), :copy_tree_recorder)

    internal =
      Sanctum.internal_context(user_id: "_overlay", athanor_id: "ath_seeded", scope: :athanor)

    src = Arca.Storage.seed_prefix("components") ++ ["catalysts", "local"]
    dest = ["components", "catalysts", "local"]

    assert {:ok, _} = Arca.copy_tree(internal, src, dest)

    dest_leaf = dest ++ ["x", "1.0.0", "cyfr-manifest.json"]
    assert_received {:adapter_put, ^dest_leaf}
    assert {:ok, "{}"} = Arca.get(internal, dest_leaf)
  end
end
