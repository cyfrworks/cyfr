# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.UsageTest do
  @moduledoc """
  The usage-cache discipline in one place: creates bump, deletes drop,
  reads walk once and cache, invalidate/1 clears an athanor whole. The
  two enforcement surfaces (the byte cap, the public scope quota) read
  through this module, so the discipline holds for both by construction.
  """

  use ExUnit.Case, async: false

  setup do
    base = Path.join(System.tmp_dir!(), "usage_#{System.unique_integer([:positive])}")

    prev_base = Application.fetch_env!(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, base)
    Arca.Cache.init()

    ctx = Sanctum.TestContext.local()
    Arca.Usage.invalidate(ctx.athanor_id)

    on_exit(fn ->
      Arca.Usage.invalidate(ctx.athanor_id)
      Application.put_env(:cyfr, :base_path, prev_base)
      File.rm_rf!(base)
    end)

    {:ok, ctx: ctx}
  end

  test "reads walk once and cache; creates bump; deletes drop", %{ctx: ctx} do
    :ok = Arca.put(ctx, ["guest", "a.txt"], "aaaa")

    assert {:ok, 4} = Arca.Usage.athanor_bytes(ctx)
    assert {:ok, %{files: 1, bytes: 4}} = Arca.Usage.scope_usage(ctx, "guest")

    # A successful create bumps the cached counters in place — no walk.
    :ok = Arca.put(ctx, ["guest", "b.txt"], "bb")
    assert {:ok, 6} = Arca.Usage.athanor_bytes(ctx)
    assert {:ok, %{files: 2, bytes: 6}} = Arca.Usage.scope_usage(ctx, "guest")

    # A delete drops the entries; the next read walks the truth afresh.
    :ok = Arca.delete(ctx, ["guest", "b.txt"])
    assert {:ok, 4} = Arca.Usage.athanor_bytes(ctx)
    assert {:ok, %{files: 1, bytes: 4}} = Arca.Usage.scope_usage(ctx, "guest")
  end

  test "an overwrite over-counts — the safe direction — until invalidated", %{ctx: ctx} do
    :ok = Arca.put(ctx, ["guest", "a.txt"], "aaaa")
    assert {:ok, 4} = Arca.Usage.athanor_bytes(ctx)

    # Overwriting the same 4 bytes bumps again: 8 cached over 4 stored.
    :ok = Arca.put(ctx, ["guest", "a.txt"], "aaaa")
    assert {:ok, 8} = Arca.Usage.athanor_bytes(ctx)

    # invalidate/1 clears the whole athanor — total and scope pairs — and
    # the next read walks the truth.
    Arca.Usage.invalidate(ctx.athanor_id)
    assert {:ok, 4} = Arca.Usage.athanor_bytes(ctx)
    assert {:ok, %{files: 1, bytes: 4}} = Arca.Usage.scope_usage(ctx, "guest")
  end

  test "a failed walk answers raw and is never cached", %{ctx: ctx} do
    # An athanor-less context cannot walk tenant storage: the raising
    # guard downstream is the fail-closed backstop; here only the
    # empty-athanor clause answers.
    assert {:ok, 0} = Arca.Usage.athanor_bytes(%{ctx | athanor_id: nil})
  end
end
