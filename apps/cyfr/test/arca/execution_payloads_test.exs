# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionPayloadsTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

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
    ctx = Sanctum.TestContext.local()
    {:ok, ctx: ctx, exec: execution!(ctx)}
  end

  # A payload references an execution the database knows.
  defp execution!(ctx, id \\ "exec_pay_#{System.unique_integer([:positive])}") do
    now = DateTime.utc_now()

    {1, _} =
      Arca.Repo.insert_all(Arca.Execution, [
        %{
          id: id,
          athanor_id: ctx.athanor_id,
          user_id: ctx.user_id,
          reference: "reagent:local.pay:0.1.0",
          status: "completed",
          started_at: now
        }
      ])

    id
  end

  # Where the object lives on disk, for a test that makes it undeletable.
  defp physical_dir(ctx, row) do
    segments = Arca.Storage.physical_segments(ctx, String.split(row.blob_ref, "/"))
    Path.join([Arca.Adapters.Local.base_path() | segments]) |> Path.dirname()
  end

  test "a payload is kept once per execution and kind, by digest, and read back", %{
    ctx: ctx,
    exec: exec
  } do
    assert {:ok, row} = ExecutionPayloads.put(ctx, exec, "result", ~s({"ok":true}), "api")
    assert row.athanor_id == ctx.athanor_id
    assert row.digest == Cyfr.Digest.sha256(~s({"ok":true}))
    assert row.bytes == 11
    "sha256:" <> hex = row.digest
    assert row.blob_ref == "payloads/#{exec}/result.#{hex}"

    assert {:ok, ^row, ~s({"ok":true})} = ExecutionPayloads.get(ctx, exec, "result")
    assert {:error, :not_found} = ExecutionPayloads.get(ctx, exec, "input")

    # Once: a second result for the same execution is refused, and the
    # first one's bytes are exactly what they were.
    assert {:error, :exists} = ExecutionPayloads.put(ctx, exec, "result", "again", "api")
    assert {:ok, ^row, ~s({"ok":true})} = ExecutionPayloads.get(ctx, exec, "result")
    assert {:error, :not_found} = Arca.get(ctx, ["payloads", exec, "result.again"])
  end

  test "a payload names an execution the athanor holds", %{ctx: ctx, exec: exec} do
    assert {:error, :no_execution} =
             ExecutionPayloads.put(ctx, "exec_unknown", "result", "orphan", "api")

    elsewhere = %{ctx | athanor_id: "ath_elsewhere"}
    assert {:error, :no_execution} = ExecutionPayloads.put(elsewhere, exec, "result", "x", "api")
  end

  test "bytes that no longer match the row's digest are refused, not served", %{
    ctx: ctx,
    exec: exec
  } do
    {:ok, row} = ExecutionPayloads.put(ctx, exec, "result", "true", "api")

    # The root is reserved: a member's write is refused...
    segments = String.split(row.blob_ref, "/")
    assert {:error, :forbidden} = Arca.put(ctx, segments, "false")
    assert {:ok, _, "true"} = ExecutionPayloads.get(ctx, exec, "result")

    # ...and bytes changed underneath the store are corruption.
    :ok = Arca.Overlay.with_internal_writes(fn -> Arca.put(ctx, segments, "false") end)
    assert {:error, :payload_corrupt} = ExecutionPayloads.get(ctx, exec, "result")
  end

  test "a payload is the athanor's: another estate reads nothing", %{ctx: ctx, exec: exec} do
    {:ok, _} = ExecutionPayloads.put(ctx, exec, "result", "mine", "api")

    assert {:error, :not_found} =
             ExecutionPayloads.get(%{ctx | athanor_id: "ath_elsewhere"}, exec, "result")
  end

  test "payloads older than the retention window go, bytes and rows", %{ctx: ctx, exec: exec} do
    {:ok, row} = ExecutionPayloads.put(ctx, exec, "result", "old", "api")

    old = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
    {1, _} = Arca.Repo.update_all(Arca.Schemas.ExecutionPayload, set: [inserted_at: old])

    assert {:ok, 1} = ExecutionPayloads.count_older_than_days(ctx, 30)
    assert {:ok, 0} = ExecutionPayloads.count_older_than_days(ctx, 60)
    assert {:ok, 1} = ExecutionPayloads.delete_older_than_days(ctx, 30)
    assert {:error, :not_found} = ExecutionPayloads.get(ctx, exec, "result")
    assert {:error, :not_found} = Arca.get(ctx, String.split(row.blob_ref, "/"))
  end

  test "a row whose bytes could not be deleted stays for the next sweep", %{ctx: ctx, exec: exec} do
    {:ok, row} = ExecutionPayloads.put(ctx, exec, "result", "stuck", "api")
    old = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
    {1, _} = Arca.Repo.update_all(Arca.Schemas.ExecutionPayload, set: [inserted_at: old])

    # The object's directory refuses the unlink.
    dir = physical_dir(ctx, row)

    File.chmod!(dir, 0o500)

    try do
      assert {:ok, 0} = ExecutionPayloads.delete_older_than_days(ctx, 30)
      assert {:ok, 1} = ExecutionPayloads.count_older_than_days(ctx, 30)
    after
      File.chmod!(dir, 0o700)
    end

    assert {:ok, 1} = ExecutionPayloads.delete_older_than_days(ctx, 30)
    assert {:ok, 0} = ExecutionPayloads.count_older_than_days(ctx, 30)
  end

  test "releasing executions frees their payloads and names the ones still held", %{ctx: ctx} do
    a = execution!(ctx)
    b = execution!(ctx)
    {:ok, _} = ExecutionPayloads.put(ctx, a, "result", "a", "api")
    {:ok, row_b} = ExecutionPayloads.put(ctx, b, "result", "b", "api")

    dir = physical_dir(ctx, row_b)
    File.chmod!(dir, 0o500)

    try do
      assert {:ok, [^b]} = ExecutionPayloads.release(ctx, [a, b, "exec_none"])
    after
      File.chmod!(dir, 0o700)
    end

    assert {:error, :not_found} = ExecutionPayloads.get(ctx, a, "result")
    assert {:ok, _, "b"} = ExecutionPayloads.get(ctx, b, "result")

    # An execution whose payload is still held cannot be deleted underneath it.
    refused =
      try do
        Arca.Repo.delete_all(from(e in Arca.Execution, where: e.id == ^b))
        :deleted
      rescue
        _ -> :refused
      end

    assert refused == :refused

    assert {:ok, []} = ExecutionPayloads.release(ctx, [b])
    assert {:ok, 1} = Arca.Execution.delete_ids([b], athanor_id: ctx.athanor_id)
  end
end
