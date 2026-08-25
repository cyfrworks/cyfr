# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CopyTreeTest.RecordingAdapter do
  @moduledoc false
  # Delegates to the Local adapter but records every put — stands in for an
  # object store so the bundle→storage seeding seam is exercised with a
  # non-default adapter configured.
  @behaviour Arca.Storage

  defdelegate get(ctx, path), to: Arca.Adapters.Local
  defdelegate append(ctx, path, content), to: Arca.Adapters.Local
  defdelegate delete(ctx, path), to: Arca.Adapters.Local
  defdelegate list(ctx, path), to: Arca.Adapters.Local
  defdelegate list_typed(ctx, path), to: Arca.Adapters.Local
  defdelegate exists?(ctx, path), to: Arca.Adapters.Local
  defdelegate delete_tree(ctx, path), to: Arca.Adapters.Local
  defdelegate list_recursive(ctx, path), to: Arca.Adapters.Local
  defdelegate read_subtree(ctx, path), to: Arca.Adapters.Local
  defdelegate usage(ctx, path), to: Arca.Adapters.Local
  defdelegate serve_to_conn(conn, ctx, path, opts), to: Arca.Adapters.Local

  def put(ctx, path, content) do
    if pid = Process.whereis(:copy_tree_recorder), do: send(pid, {:adapter_put, path})
    Arca.Adapters.Local.put(ctx, path, content)
  end
end

defmodule Arca.CopyTreeTest do
  @moduledoc """
  `Arca.copy_tree/3` is the seeding seam: the source is read per-path (the
  seed bundle stays pinned to local disk), the destination is written
  per-path through the configured adapter.
  """

  use ExUnit.Case, async: false

  setup do
    base = Path.join(System.tmp_dir!(), "copy_tree_#{System.unique_integer([:positive])}")
    bundle = Path.join(base, "bundle")
    File.mkdir_p!(bundle)

    prev_base = Application.fetch_env!(:cyfr, :base_path)
    prev_bundle = Application.fetch_env!(:cyfr, :bundle_path)
    Application.put_env(:cyfr, :base_path, Path.join(base, "data"))
    Application.put_env(:cyfr, :bundle_path, bundle)

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      Application.put_env(:cyfr, :bundle_path, prev_bundle)
      File.rm_rf!(base)
    end)

    {:ok, bundle: bundle}
  end

  test "copies a subtree preserving relative layout, source untouched" do
    ctx = Sanctum.TestContext.local()
    :ok = Arca.put(ctx, ["seed", "src", "a.txt"], "A")
    :ok = Arca.put(ctx, ["seed", "src", "sub", "b.txt"], "B")

    assert :ok = Arca.copy_tree(ctx, ["seed", "src"], ["seed", "dest"])

    assert {:ok, "A"} = Arca.get(ctx, ["seed", "dest", "a.txt"])
    assert {:ok, "B"} = Arca.get(ctx, ["seed", "dest", "sub", "b.txt"])
    assert {:ok, "A"} = Arca.get(ctx, ["seed", "src", "a.txt"])
  end

  test "exclude: skips matching files before their content is read" do
    ctx = Sanctum.TestContext.local()
    :ok = Arca.put(ctx, ["seed", "src", "a.txt"], "A")
    :ok = Arca.put(ctx, ["seed", "src", "target", "debug", "junk.o"], "JUNK")

    exclude = fn relative -> "target" in relative end
    assert :ok = Arca.copy_tree(ctx, ["seed", "src"], ["seed", "dest"], exclude: exclude)

    assert {:ok, "A"} = Arca.get(ctx, ["seed", "dest", "a.txt"])
    assert {:error, :not_found} = Arca.get(ctx, ["seed", "dest", "target", "debug", "junk.o"])
  end

  test "seeds the bundle through the configured adapter, reading it in place", %{bundle: bundle} do
    # The AthanorSeeder contract on an object-store deployment: the bundle
    # is read from local disk and only the copies reach the adapter.
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

    seed = Sanctum.internal_context(user_id: "_seed", athanor_id: "ath_seeded", scope: :athanor)

    src = Compendium.Bundle.bundle_prefix() ++ ["catalysts", "local"]
    dest = ["components", "ath_seeded", "catalysts", "local"]

    assert :ok = Arca.copy_tree(seed, src, dest)

    dest_leaf = dest ++ ["x", "1.0.0", "cyfr-manifest.json"]
    assert_received {:adapter_put, ^dest_leaf}
    assert {:ok, "{}"} = Arca.get(seed, dest_leaf)
  end
end
