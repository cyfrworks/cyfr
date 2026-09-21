# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.EnsureRootsTest do
  # The folder structure of an athanor exists from the first day: every
  # tenant root is a directory, laid without a byte, behind the same
  # roster and seed gates as any path.
  use ExUnit.Case, async: false

  setup do
    base = Path.join(System.tmp_dir!(), "ensure_roots_#{System.unique_integer([:positive])}")
    prev_base = Application.fetch_env!(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, prev_base)
      File.rm_rf!(base)
    end)

    {:ok, actor: Arca.Test.Actor.local()}
  end

  test "ensure_roots/1 lays every tenant root, idempotently, and counts nothing", %{actor: actor} do
    assert {:ok, []} = Arca.list_typed(actor, [])
    assert :ok = Arca.ensure_roots(actor)
    assert :ok = Arca.ensure_roots(actor)

    {:ok, entries} = Arca.list_typed(actor, [])

    assert Enum.sort(entries) ==
             Enum.sort(for root <- Arca.Storage.tenant_roots(), do: {root, :dir})

    assert {:ok, %{files: 0, bytes: 0}} = Arca.usage(actor, [])
  end

  test "ensure_dir/2 refuses what the roster refuses", %{actor: actor} do
    assert :ok = Arca.ensure_dir(actor, ["data", "reports", "2026"])

    assert {:ok, [{"2026", :dir}]} =
             Arca.list_typed(actor, ["data", "reports"])

    assert {:error, :forbidden} = Arca.ensure_dir(actor, ["scratch"])

    assert {:error, :forbidden} =
             Arca.ensure_dir(actor, ["seed", "components", "x"])

    assert {:error, :forbidden} = Arca.ensure_dir(actor, ["cache", "oci"])
    assert {:error, :invalid_path} = Arca.ensure_dir(actor, [])
  end
end
