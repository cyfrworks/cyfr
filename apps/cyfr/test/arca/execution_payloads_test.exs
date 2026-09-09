# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionPayloadsTest do
  use ExUnit.Case, async: false

  alias Arca.ExecutionPayloads

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "payloads_#{:rand.uniform(1_000_000)}")
    original = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:cyfr, :base_path, original),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    Sanctum.TestContext.athanor!()
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "a payload is kept once per execution and kind, by digest, and read back", %{ctx: ctx} do
    exec = "exec_pay_#{System.unique_integer([:positive])}"

    assert {:ok, row} = ExecutionPayloads.put(ctx, exec, "result", ~s({"ok":true}), "api")
    assert row.athanor_id == ctx.athanor_id
    assert row.digest == Cyfr.Digest.sha256(~s({"ok":true}))
    assert row.bytes == 11
    assert row.blob_ref == "payloads/#{exec}/result"

    assert {:ok, ^row, ~s({"ok":true})} = ExecutionPayloads.get(ctx, exec, "result")
    assert {:error, :not_found} = ExecutionPayloads.get(ctx, exec, "input")

    # Once: a second result for the same execution is refused.
    assert {:error, %Ecto.Changeset{}} =
             ExecutionPayloads.put(ctx, exec, "result", "again", "api")
  end

  test "a payload is the athanor's: another estate reads nothing", %{ctx: ctx} do
    exec = "exec_pay_#{System.unique_integer([:positive])}"
    {:ok, _} = ExecutionPayloads.put(ctx, exec, "result", "mine", "api")

    assert {:error, :not_found} =
             ExecutionPayloads.get(%{ctx | athanor_id: "ath_elsewhere"}, exec, "result")
  end

  test "payloads older than the retention window go, bytes and rows", %{ctx: ctx} do
    exec = "exec_pay_#{System.unique_integer([:positive])}"
    {:ok, row} = ExecutionPayloads.put(ctx, exec, "result", "old", "api")

    old = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
    {1, _} = Arca.Repo.update_all(Arca.Schemas.ExecutionPayload, set: [inserted_at: old])
    _ = row

    assert {:ok, 1} = ExecutionPayloads.count_older_than_days(ctx, 30)
    assert {:ok, 0} = ExecutionPayloads.count_older_than_days(ctx, 60)
    assert {:ok, 1} = ExecutionPayloads.delete_older_than_days(ctx, 30)
    assert {:error, :not_found} = ExecutionPayloads.get(ctx, exec, "result")
    assert {:error, :not_found} = Arca.get(ctx, ["payloads", exec, "result"])
  end
end
