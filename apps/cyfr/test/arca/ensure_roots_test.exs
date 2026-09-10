# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.EnsureRootsTest do
  # The folder structure of an athanor exists from the first day: every
  # tenant root is a directory, laid without a byte, behind the same
  # roster and seed gates as any path.
  use ExUnit.Case, async: false

  setup do
    base = Path.join(System.tmp_dir!(), "ensure_roots_#{System.unique_integer([:positive])}")
    prev_base = Application.fetch_env!(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, base)

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      File.rm_rf!(base)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "ensure_roots/1 lays every tenant root, idempotently, and counts nothing", %{ctx: ctx} do
    assert {:ok, []} = Arca.list_typed(ctx, [])
    assert :ok = Arca.ensure_roots(ctx)
    assert :ok = Arca.ensure_roots(ctx)

    {:ok, entries} = Arca.list_typed(ctx, [])

    assert Enum.sort(entries) ==
             Enum.sort(for root <- Arca.Storage.tenant_roots(), do: {root, :dir})

    assert {:ok, %{files: 0, bytes: 0}} = Arca.usage(ctx, [])
  end

  test "ensure_dir/2 refuses what the roster refuses", %{ctx: ctx} do
    assert :ok = Arca.ensure_dir(ctx, ["guest", "reports", "2026"])
    assert {:ok, [{"2026", :dir}]} = Arca.list_typed(ctx, ["guest", "reports"])

    assert {:error, :forbidden} = Arca.ensure_dir(ctx, ["scratch"])
    assert {:error, :forbidden} = Arca.ensure_dir(ctx, ["seed", "components", "x"])
    assert {:error, :forbidden} = Arca.ensure_dir(ctx, ["cache", "oci"])
    assert {:error, :invalid_path} = Arca.ensure_dir(ctx, [])
  end
end
