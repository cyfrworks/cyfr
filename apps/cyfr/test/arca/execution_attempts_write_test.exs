# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionAttemptsWriteTest do
  @moduledoc """
  A guest's mutable storage write is three steps
  (`Arca.ExecutionAttempts.while_held/5`): its intent commits with the
  check that its attempt holds its row, the store call runs with no
  transaction open, and the intent is settled against the same hold. A
  cancel, lapse or takeover that commits before the intent refuses the
  write untouched; one that commits between the intent and its settlement
  settles the intent `uncertain` itself and the write is answered
  `uncertain`, never confirmed and never refused. A store that cannot say
  what it did is `uncertain`, one that refused is `failed` with nothing
  written, and every intent is kept.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ExecutionAttempts
  alias Arca.Schemas.{ExecutionAttempt, StorageWriteIntent}

  @runner "runner_a"
  @path ["data", "intent.txt"]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Arca.Cache.init()
    Arca.Cache.delete_match({:scope_usage, :_, :_, :_})

    test_dir =
      Path.join(System.tmp_dir!(), "attempt_write_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_dir)
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    ctx = Sanctum.TestContext.local()

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(%{
        id: "exec_write_#{System.unique_integer([:positive])}",
        reference: "catalyst:local.write:0.1.0",
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        component_type: "catalyst",
        input: "{}"
      })

    :ok = ExecutionAttempts.claim(ctx.athanor_id, attempt.attempt, 1, @runner)
    {:ok, ctx: ctx, execution: execution, attempt: attempt.attempt}
  end

  # One write of the attempt at fence 1; `io` is the store call.
  defp write(%{ctx: ctx, attempt: attempt}, io, opts \\ []) do
    ExecutionAttempts.while_held(
      ctx.athanor_id,
      attempt,
      Keyword.get(opts, :fence, 1),
      @runner,
      %{
        op: Keyword.get(opts, :op, :put),
        path: Keyword.get(opts, :path, @path),
        bytes: Keyword.get(opts, :bytes, 5),
        io: io
      }
    )
  end

  defp put(%{ctx: ctx}, bytes \\ "bytes"), do: fn -> Arca.put(ctx, @path, bytes) end

  defp intents(%{ctx: ctx, attempt: attempt}),
    do: ExecutionAttempts.write_intents(ctx.athanor_id, attempt)

  defp states(test), do: for(i <- intents(test), do: {i.state, i.reason})

  defp cancel!(%{ctx: ctx, execution: execution}) do
    {:ok, _} =
      Arca.Execution.record_end(
        ctx,
        execution.id,
        "cancelled",
        %{completed_at: DateTime.utc_now(), duration_ms: 1},
        nil
      )

    :ok
  end

  defp takeover!(%{ctx: ctx, execution: execution}) do
    {:ok, %{attempt: successor}} =
      ExecutionAttempts.takeover(ctx.athanor_id, execution.id,
        boot_id: Cyfr.Boot.id(),
        lease_until: ExecutionAttempts.lease_until()
      )

    successor
  end

  defp attempt_row(%{attempt: attempt}), do: Arca.Repo.get!(ExecutionAttempt, attempt)

  describe "a write its attempt holds throughout" do
    test "records its intent before the store is touched and confirms it after", test do
      io = fn ->
        assert [%StorageWriteIntent{} = intent] = intents(test)
        assert intent.state == "pending"
        assert intent.attempt == test.attempt
        assert intent.execution_id == test.execution.id
        assert {intent.fence, intent.runner} == {1, @runner}
        assert {intent.op, intent.path, intent.bytes} == {"put", "data/intent.txt", 5}
        assert intent.settled_at == nil
        refute Arca.exists?(test.ctx, @path)
        put(test).()
      end

      assert {:ok, {:confirmed, :ok}} = write(test, io)
      assert {:ok, "bytes"} = Arca.get(test.ctx, @path)

      assert [%{state: "confirmed", reason: nil, settled_at: %DateTime{}}] = intents(test)
      assert attempt_row(test).fence == 1
    end

    test "holds no transaction and asks the database nothing while the store is touched", test do
      handler = "write-probe-#{System.unique_integer([:positive])}"
      probe = self()

      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measures, meta, _config ->
          if Process.get(:in_store_call), do: send(probe, {:queried, meta.query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      io = fn ->
        refute Arca.Repo.in_transaction?()
        Process.put(:in_store_call, true)
        result = Arca.Adapters.Local.put(test.ctx, @path, "bytes")
        Process.delete(:in_store_call)
        result
      end

      assert {:ok, {:confirmed, :ok}} = write(test, io)
      refute_received {:queried, _query}

      # The probe does see a query made while it is armed.
      Process.put(:in_store_call, true)
      assert [_intent] = intents(test)
      assert_received {:queried, _query}
    end

    test "a delete and an append are intents of their own operation", test do
      :ok = Arca.put(test.ctx, @path, "a")

      assert {:ok, {:confirmed, :ok}} =
               write(test, fn -> Arca.append(test.ctx, @path, "b") end, op: :append, bytes: 1)

      assert {:ok, {:confirmed, :ok}} =
               write(test, fn -> Arca.delete(test.ctx, @path) end, op: :delete, bytes: nil)

      assert [%{op: "append", bytes: 1}, %{op: "delete", bytes: nil}] = intents(test)
      refute Arca.exists?(test.ctx, @path)
    end

    test "two concurrent writes to one path are two confirmed intents, and both appends land",
         test do
      :ok = Arca.put(test.ctx, @path, "")
      gate = self()

      writers =
        for line <- ["one\n", "two\n"] do
          Task.async(fn ->
            io = fn ->
              send(gate, {:in_store_call, self()})

              receive do
                :go -> Arca.append(test.ctx, @path, line)
              end
            end

            write(test, io, op: :append, bytes: byte_size(line))
          end)
        end

      # Both intents are pending together before either store call runs.
      pids =
        for _ <- writers do
          assert_receive {:in_store_call, pid}, 5_000
          pid
        end

      assert [{"pending", nil}, {"pending", nil}] = states(test)
      for pid <- pids, do: send(pid, :go)

      assert [{:ok, {:confirmed, :ok}}, {:ok, {:confirmed, :ok}}] = Task.await_many(writers)
      assert [{"confirmed", nil}, {"confirmed", nil}] = states(test)

      assert {:ok, content} = Arca.get(test.ctx, @path)
      assert Enum.sort(String.split(content, "\n", trim: true)) == ["one", "two"]
    end
  end

  describe "a cancel at the write's boundaries" do
    test "before the intent: the write is lost, nothing is recorded and the store is untouched",
         test do
      cancel!(test)

      assert {:error, :lost} = write(test, fn -> flunk("the store was touched") end)
      assert [] = intents(test)
      refute Arca.exists?(test.ctx, @path)
    end

    test "between the intent and the store call: uncertain, settled by the cancel", test do
      io = fn ->
        cancel!(test)
        # The cancel committed the evidence before any byte moved.
        assert [{"uncertain", "cancelled"}] = states(test)
        put(test).()
      end

      assert {:ok, {:uncertain, :hold_lost}} = write(test, io)
      assert [{"uncertain", "cancelled"}] = states(test)
      assert %{state: "cancelled", outcome: "cancelled"} = attempt_row(test)
    end

    test "between the store call and the settlement: uncertain, never confirmed", test do
      io = fn ->
        :ok = put(test).()
        cancel!(test)
        :ok
      end

      assert {:ok, {:uncertain, :hold_lost}} = write(test, io)
      assert [{"uncertain", "cancelled"}] = states(test)
      assert {:ok, "bytes"} = Arca.get(test.ctx, @path)
    end

    test "after the settlement: the write stays confirmed", test do
      assert {:ok, {:confirmed, :ok}} = write(test, put(test))
      cancel!(test)

      assert [{"confirmed", nil}] = states(test)
      assert {:error, :lost} = write(test, fn -> flunk("the store was touched") end)
      assert [{"confirmed", nil}] = states(test)
    end

    test "a store that refused after a cancel is still a refusal: nothing was written", test do
      io = fn ->
        cancel!(test)
        {:error, :not_found}
      end

      assert {:ok, {:failed, {:error, :not_found}}} = write(test, io, op: :delete)
      # The cancel's settlement stands; the stale attempt overwrites nothing.
      assert [{"uncertain", "cancelled"}] = states(test)
    end
  end

  describe "losing the row another way" do
    test "a takeover between the intent and the settlement is uncertain, and the successor writes",
         test do
      {:ok, successor} = Agent.start_link(fn -> nil end)

      io = fn ->
        Agent.update(successor, fn _ -> takeover!(test) end)
        put(test, "stale").()
      end

      assert {:ok, {:uncertain, :hold_lost}} = write(test, io)
      assert [{"uncertain", "taken_over"}] = states(test)
      assert %{state: "lapsed", outcome: "uncertain"} = attempt_row(test)

      %{attempt: next, fence: 2} = Agent.get(successor, & &1)
      :ok = ExecutionAttempts.claim(test.ctx.athanor_id, next, 2, @runner)

      assert {:ok, {:confirmed, :ok}} = write(%{test | attempt: next}, put(test, "new"), fence: 2)
      assert {:ok, "new"} = Arca.get(test.ctx, @path)

      # The stale fence is refused outright from here on.
      assert {:error, :lost} = write(test, fn -> flunk("the store was touched") end)
    end

    test "a lapse between the intent and the settlement is uncertain", test do
      io = fn ->
        lease = attempt_row(test).lease_until
        assert {:ok, ran} = ExecutionAttempts.lapse(test.attempt, lease)
        assert is_integer(ran)
        put(test).()
      end

      assert {:ok, {:uncertain, :hold_lost}} = write(test, io)
      assert [{"uncertain", "lapsed"}] = states(test)
    end

    test "a lease that ran out holds nothing, swept or not", test do
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      from(a in ExecutionAttempt, where: a.attempt == ^test.attempt)
      |> Arca.Repo.update_all(set: [lease_until: past])

      assert {:error, :lost} = write(test, fn -> flunk("the store was touched") end)
      assert [] = intents(test)
    end

    test "a writer killed in its store call leaves its intent to whatever ends the attempt",
         test do
      gate = self()

      writer =
        spawn(fn ->
          write(test, fn ->
            send(gate, :in_store_call)
            Process.sleep(:infinity)
          end)
        end)

      assert_receive :in_store_call, 5_000
      Process.exit(writer, :kill)
      assert [{"pending", nil}] = states(test)

      cancel!(test)
      assert [{"uncertain", "cancelled"}] = states(test)
    end
  end

  describe "what the store answered" do
    test "unknown is uncertain, and the attempt still holds its row", test do
      assert {:ok, {:uncertain, :unknown_outcome}} = write(test, fn -> {:error, :unknown} end)
      assert [{"uncertain", "unknown_outcome"}] = states(test)

      assert ExecutionAttempts.held?(test.ctx.athanor_id, test.attempt, 1, @runner)
      assert {:ok, {:confirmed, :ok}} = write(test, put(test))
    end

    test "an append that kept losing is a failed intent: a conflict, nothing appended", test do
      assert {:ok, {:failed, {:error, :precondition_failed}}} =
               write(test, fn -> {:error, :precondition_failed} end, op: :append)

      assert [%{op: "append", state: "failed", reason: "precondition_failed"}] = intents(test)
    end

    test "a refusal settles the intent failed under the reason's name alone", test do
      for {error, reason} <- [
            {{:error, :eacces}, "eacces"},
            {{:error, {:limit_reached, :athanor_storage_bytes, 10}}, "limit_reached"},
            {{:error, {:s3_error, 403}}, "s3_error"},
            {{:error, "AccessDenied for key AKIA-not-kept"}, "error"}
          ] do
        assert {:ok, {:failed, ^error}} = write(test, fn -> error end)
        assert %{state: "failed", reason: ^reason} = List.last(intents(test))
      end

      refute Arca.exists?(test.ctx, @path)
    end

    @tag :capture_log
    test "a store call that raised, exited, threw or answered no result is uncertain", test do
      for io <- [
            fn -> raise "the adapter broke" end,
            fn -> exit(:gone) end,
            fn -> throw(:out) end,
            fn -> :written end
          ] do
        assert {:ok, {:uncertain, :io_crashed}} = write(test, io)
      end

      assert List.duplicate({"uncertain", "io_crashed"}, 4) == states(test)
    end
  end

  describe "a database that cannot answer" do
    @tag :capture_log
    test "before the intent: an error, and the store is untouched", test do
      Arca.Repo.query!("DROP TABLE storage_write_intents")

      assert {:error, :database_error} = write(test, fn -> flunk("the store was touched") end)
    end

    @tag :capture_log
    test "after the store applied the write: uncertain, never confirmed", test do
      io = fn ->
        :ok = put(test).()
        Arca.Repo.query!("DROP TABLE storage_write_intents")
        :ok
      end

      assert {:ok, {:uncertain, :unconfirmed}} = write(test, io)
    end
  end

  test "an intent is another estate's to neither read nor settle", test do
    assert {:ok, {:confirmed, :ok}} = write(test, put(test))

    assert [] = ExecutionAttempts.write_intents("ath_gamma", test.attempt)

    assert {:error, :lost} =
             ExecutionAttempts.while_held(
               "ath_gamma",
               test.attempt,
               1,
               @runner,
               %{op: :put, path: @path, io: fn -> flunk("the store was touched") end}
             )
  end
end
