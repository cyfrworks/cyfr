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
    original = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    Sanctum.TestContext.athanor!()
    ctx = Sanctum.TestContext.local()
    actor = Sanctum.Context.actor(ctx)
    {:ok, ctx: ctx, actor: actor, exec: execution!(actor)}
  end

  # A payload references an execution the database knows, and its attempt.
  defp execution!(actor, id \\ "exec_pay_#{System.unique_integer([:positive])}") do
    now = DateTime.utc_now()

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.Execution, [
        %{
          id: id,
          athanor_id: actor.athanor_id,
          user_id: actor.user_id,
          reference: "reagent:local.pay:0.1.0",
          status: "completed",
          started_at: now,
          current_attempt: "att_#{id}"
        }
      ])

    id
  end

  defp move_attempt!(exec, attempt) do
    {1, _} =
      Arca.Repo.update_all(from(e in Arca.Schemas.Execution, where: e.id == ^exec),
        set: [current_attempt: attempt]
      )

    :ok
  end

  # Where the object lives on disk, for a test that makes it undeletable.
  defp physical_dir(actor, row) do
    segments = Arca.Storage.physical_segments(actor, String.split(row.blob_ref, "/"))
    Path.join([Arca.Adapters.Local.base_path() | segments]) |> Path.dirname()
  end

  test "a payload is kept once per execution and kind, by digest, and read back", %{
    actor: actor,
    exec: exec
  } do
    assert {:ok, row} =
             ExecutionPayloads.put(
               actor,
               exec,
               "result",
               ~s({"ok":true}),
               "api"
             )

    assert row.athanor_id == actor.athanor_id
    assert row.attempt == "att_#{exec}"
    assert row.digest == Prima.Digest.sha256(~s({"ok":true}))
    assert row.bytes == 11
    "sha256:" <> hex = row.digest
    assert row.blob_ref == "payloads/#{exec}/result.#{hex}"

    assert {:ok, ^row, ~s({"ok":true})} =
             ExecutionPayloads.get(actor, exec, "result")

    assert {:error, :not_found} = ExecutionPayloads.get(actor, exec, "input")

    # Once: a second result for the same execution is refused, and the
    # first one's bytes are exactly what they were.
    assert {:error, :exists} =
             ExecutionPayloads.put(actor, exec, "result", "again", "api")

    assert {:ok, ^row, ~s({"ok":true})} =
             ExecutionPayloads.get(actor, exec, "result")

    assert {:error, :not_found} =
             Arca.get(actor, ["payloads", exec, "result.again"])
  end

  test "a payload is its attempt's: a successor keeps its own, and the current one is read", %{
    actor: actor,
    exec: exec
  } do
    first = "att_#{exec}"
    {:ok, _} = ExecutionPayloads.put(actor, exec, "result", "first", "api")

    # The row moved to a successor attempt: the predecessor's payload is
    # not what the execution answers now, but it is still there by name.
    move_attempt!(exec, "att_second")

    assert {:error, :not_found} =
             ExecutionPayloads.get(actor, exec, "result")

    assert {:ok, %{attempt: ^first}, "first"} =
             ExecutionPayloads.get(actor, exec, "result", attempt: first)

    assert {:ok, row} =
             ExecutionPayloads.put(actor, exec, "result", "second", "api")

    assert row.attempt == "att_second"

    assert {:ok, ^row, "second"} =
             ExecutionPayloads.get(actor, exec, "result")

    assert {:error, :exists} =
             ExecutionPayloads.put(actor, exec, "result", "third", "api")

    # An attempt named outright is written under that attempt.
    assert {:ok, %{attempt: "att_third"}} =
             ExecutionPayloads.put(actor, exec, "input", "given", "api", attempt: "att_third")

    assert {:error, :not_found} = ExecutionPayloads.get(actor, exec, "input")

    assert {:ok, _, "given"} =
             ExecutionPayloads.get(actor, exec, "input", attempt: "att_third")
  end

  test "staged bytes join a transaction: a rollback leaves no row, and discard removes them", %{
    actor: actor,
    exec: exec
  } do
    {:ok, staged} =
      ExecutionPayloads.stage(actor, exec, "input", "given", "api")

    assert {:ok, "given"} = Arca.get(actor, staged.segments)

    assert {:error, :rolled_back} =
             Arca.Repo.transaction(fn ->
               _ = ExecutionPayloads.commit!(staged, "att_#{exec}")
               Arca.Repo.rollback(:rolled_back)
             end)

    assert {:error, :not_found} = ExecutionPayloads.get(actor, exec, "input")
    assert :ok = ExecutionPayloads.discard(staged)
    assert {:error, :not_found} = Arca.get(actor, staged.segments)

    # Committed, the row is the current attempt's and the bytes are read back.
    {:ok, staged} =
      ExecutionPayloads.stage(actor, exec, "input", "given", "api")

    {:ok, row} = Arca.Repo.transaction(fn -> ExecutionPayloads.commit!(staged, "att_#{exec}") end)
    projected = Arca.Data.project(row)
    assert {:ok, ^projected, "given"} = ExecutionPayloads.get(actor, exec, "input")

    # Discarding a stage whose object a row already names keeps the object.
    {:ok, again} =
      ExecutionPayloads.stage(actor, exec, "input", "given", "api")

    assert :ok = ExecutionPayloads.discard(again)
    assert {:ok, ^projected, "given"} = ExecutionPayloads.get(actor, exec, "input")

    # A second commit for the same execution, kind and attempt raises, and
    # its transaction rolls back.
    {:ok, other} =
      ExecutionPayloads.stage(actor, exec, "input", "other", "api")

    assert {:error, %Ecto.InvalidChangesetError{}} =
             Arca.Repo.transaction(fn ->
               try do
                 ExecutionPayloads.commit!(other, "att_#{exec}")
               rescue
                 e -> Arca.Repo.rollback(e)
               end
             end)

    assert :ok = ExecutionPayloads.discard(other)
  end

  test "a payload names an execution the athanor holds", %{actor: actor, exec: exec} do
    assert {:error, :no_execution} =
             ExecutionPayloads.put(
               actor,
               "exec_unknown",
               "result",
               "orphan",
               "api"
             )

    elsewhere = %{actor | athanor_id: "ath_elsewhere"}
    assert {:error, :no_execution} = ExecutionPayloads.put(elsewhere, exec, "result", "x", "api")
  end

  test "bytes that no longer match the row's digest are refused, not served", %{
    actor: actor,
    exec: exec
  } do
    {:ok, row} = ExecutionPayloads.put(actor, exec, "result", "true", "api")

    # The root is reserved: a member's write is refused...
    segments = String.split(row.blob_ref, "/")
    assert {:error, :forbidden} = Arca.put(actor, segments, "false")
    assert {:ok, _, "true"} = ExecutionPayloads.get(actor, exec, "result")

    # ...and bytes changed underneath the store are corruption.
    :ok =
      Arca.Overlay.with_internal_writes(fn ->
        Arca.put(actor, segments, "false")
      end)

    assert {:error, :payload_corrupt} =
             ExecutionPayloads.get(actor, exec, "result")
  end

  test "a payload is the athanor's: another estate reads nothing", %{actor: actor, exec: exec} do
    {:ok, _} = ExecutionPayloads.put(actor, exec, "result", "mine", "api")

    assert {:error, :not_found} =
             ExecutionPayloads.get(%{actor | athanor_id: "ath_elsewhere"}, exec, "result")
  end

  test "payloads older than the retention window go, bytes and rows", %{actor: actor, exec: exec} do
    {:ok, row} = ExecutionPayloads.put(actor, exec, "result", "old", "api")

    old = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
    {1, _} = Arca.Repo.update_all(Arca.Schemas.ExecutionPayload, set: [inserted_at: old])

    assert {:ok, 1} =
             ExecutionPayloads.count_older_than_days(actor, 30, ["api"])

    assert {:ok, 0} =
             ExecutionPayloads.count_older_than_days(actor, 60, ["api"])

    assert {:ok, 1} =
             ExecutionPayloads.delete_older_than_days(actor, 30, ["api"])

    assert {:error, :not_found} =
             ExecutionPayloads.get(actor, exec, "result")

    assert {:error, :not_found} =
             Arca.get(actor, String.split(row.blob_ref, "/"))
  end

  test "a sweep is scoped to its retention classes", %{actor: actor} do
    api = execution!(actor)
    hook = execution!(actor)
    {:ok, _} = ExecutionPayloads.put(actor, api, "result", "api", "api")

    {:ok, _} =
      ExecutionPayloads.put(actor, hook, "result", "hook", "webhook")

    old = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
    {2, _} = Arca.Repo.update_all(Arca.Schemas.ExecutionPayload, set: [inserted_at: old])

    assert {:ok, 1} =
             ExecutionPayloads.count_older_than_days(actor, 30, ["webhook"])

    assert {:ok, 1} =
             ExecutionPayloads.delete_older_than_days(actor, 30, ["webhook"])

    assert {:error, :not_found} =
             ExecutionPayloads.get(actor, hook, "result")

    assert {:ok, _, "api"} = ExecutionPayloads.get(actor, api, "result")

    # Every class has a retention kind of its own, each with its window.
    kinds = Arca.Retention.kinds()

    for {kind, key} <- [
          {Arca.Retention.Payloads, "payload_days"},
          {Arca.Retention.WebhookPayloads, "webhook_payload_days"},
          {Arca.Retention.SchedulePayloads, "schedule_payload_days"},
          {Arca.Retention.SystemPayloads, "system_payload_days"}
        ] do
      assert kind in kinds
      assert kind.key() == key
      assert kind.unit() == :days
    end

    assert {:ok, 1} = Arca.Retention.Payloads.prune(actor, 30, true)
    assert {:ok, 0} = Arca.Retention.WebhookPayloads.prune(actor, 30, true)
  end

  test "a row whose bytes could not be deleted stays for the next sweep", %{
    actor: actor,
    exec: exec
  } do
    {:ok, row} = ExecutionPayloads.put(actor, exec, "result", "stuck", "api")
    old = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
    {1, _} = Arca.Repo.update_all(Arca.Schemas.ExecutionPayload, set: [inserted_at: old])

    # The object's directory refuses the unlink.
    dir = physical_dir(actor, row)

    File.chmod!(dir, 0o500)

    try do
      assert {:ok, 0} =
               ExecutionPayloads.delete_older_than_days(actor, 30, ["api"])

      assert {:ok, 1} =
               ExecutionPayloads.count_older_than_days(actor, 30, ["api"])
    after
      File.chmod!(dir, 0o700)
    end

    assert {:ok, 1} =
             ExecutionPayloads.delete_older_than_days(actor, 30, ["api"])

    assert {:ok, 0} =
             ExecutionPayloads.count_older_than_days(actor, 30, ["api"])
  end

  test "releasing executions frees their payloads and names the ones still held", %{actor: actor} do
    a = execution!(actor)
    b = execution!(actor)
    {:ok, _} = ExecutionPayloads.put(actor, a, "result", "a", "api")
    {:ok, row_b} = ExecutionPayloads.put(actor, b, "result", "b", "api")

    dir = physical_dir(actor, row_b)
    File.chmod!(dir, 0o500)

    try do
      assert {:ok, [^b]} =
               ExecutionPayloads.release(actor, [a, b, "exec_none"])
    after
      File.chmod!(dir, 0o700)
    end

    assert {:error, :not_found} = ExecutionPayloads.get(actor, a, "result")
    assert {:ok, _, "b"} = ExecutionPayloads.get(actor, b, "result")

    # An execution whose payload is still held cannot be deleted underneath it.
    refused =
      try do
        Arca.Repo.delete_all(from(e in Arca.Schemas.Execution, where: e.id == ^b))
        :deleted
      rescue
        _ -> :refused
      end

    assert refused == :refused

    assert {:ok, []} = ExecutionPayloads.release(actor, [b])
    assert {:ok, 1} = Arca.Execution.delete_ids([b], athanor_id: actor.athanor_id)
  end
end
