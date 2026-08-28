# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AppendParityTest do
  @moduledoc """
  `append/3` behaves the same on both adapters where the guest can reach
  it. The S3 adapter has always refused an append past
  `Sanctum.Limits.default_max_response_size/0` (its read-modify-write must
  bound the object it re-uploads); Local's `O_APPEND` had no ceiling, so
  the same guest program grew a file on a laptop that an object-store
  deployment refused — a divergence that was documented rather than
  closed. Both now refuse `{:error, :object_too_large}` at the same bound.
  """
  use ExUnit.Case, async: false

  setup do
    test_dir = Path.join(System.tmp_dir!(), "append_parity_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(test_dir)
    prev_base = Application.fetch_env!(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_dir)

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      File.rm_rf!(test_dir)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "Local refuses an append past the shared ceiling, like S3 does", %{ctx: ctx} do
    ceiling = Sanctum.Limits.default_max_response_size()
    path = ["guest", "parity.log"]

    # A file already at the ceiling: the cheapest way is to write it whole
    # (cap-exempt — this test measures the append bound, not the quota).
    :ok = Arca.put(ctx, path, :binary.copy(<<0>>, ceiling), cap: :exempt)

    assert {:error, :object_too_large} = Arca.append(ctx, path, "x", cap: :exempt)

    # Under the ceiling still appends.
    :ok = Arca.delete(ctx, path)
    :ok = Arca.put(ctx, path, "hello ", cap: :exempt)
    assert :ok = Arca.append(ctx, path, "world", cap: :exempt)
    assert {:ok, "hello world"} = Arca.get(ctx, path)
  end
end
