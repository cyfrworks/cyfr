# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.InputsTest do
  @moduledoc """
  The invocation-scoped port (`Opus.Inputs`), reached through the host
  calls `input_next` and `input_sent` (`Opus.Host.Inputs`), with a
  supplier of the test's own that holds the supplier's contract
  (`Cyfr.Test.InputSupplier`).

  Only the invocation's own runner, under its signed header and its live
  attempt, reads its inputs or reports one sent, and the supplier hears the
  invocation's trusted identity with each ask. A read moves nothing; a
  report is recorded once, and `ok` only once the supplier recorded it.
  With no supplier, a read is none and a report is `unavailable`; a
  supplier that is gone, silent or answers no answer makes a read
  `unavailable` too, never none. A runner that is not the claimant, a replayed
  nonce, another attempt or a cancelled invocation is `lost`, and its
  supplier is asked nothing; an input answered while the invocation was
  stopped is handed nothing. A mark the supplier would commit for an
  invocation that no longer holds its attempt is refused in its own
  transaction (`Opus.Inputs.held!/1`). A supplier's input that does not
  read is refused by the member that breaks it, and what an input carries
  never reaches the log.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cyfr.Test.{AttemptFixtures, InputSupplier}

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    :ok
  end

  @first %{"id" => "evt_input.1", "content" => "Still waiting on the run?"}
  @second %{
    "id" => "evt_input.2",
    "content" => [
      %{"type" => "text", "text" => "And this"},
      %{"type" => "image", "media_type" => "image/png", "data" => "iVBORw0KGgo="}
    ]
  }

  defp attached(opts) do
    AttemptFixtures.attached!([ctx: Sanctum.TestContext.local(:api)] ++ opts)
  end

  defp next(fixture, opts \\ []), do: AttemptFixtures.call(fixture, "input_next", %{}, opts)

  defp sent(fixture, id, opts \\ []),
    do: AttemptFixtures.call(fixture, "input_sent", %{"id" => id}, opts)

  defp invocation_of(fixture) do
    %{
      athanor_id: fixture.athanor_id,
      execution_id: fixture.execution_id,
      attempt: fixture.attempt,
      fence: fixture.fence,
      grant: fixture.grant
    }
  end

  describe "the invocation's own runner" do
    test "reads its next input again until it reports it, and its report is recorded once" do
      supplier = InputSupplier.start!([@first, @second])
      fixture = attached(inputs: supplier)

      assert %{"v" => 1, "ok" => @first} == next(fixture)
      assert %{"v" => 1, "ok" => @first} == next(fixture), "a read moves nothing"
      assert %{"v" => 1, "ok" => true} == sent(fixture, @first["id"])
      assert %{"v" => 1, "ok" => @second} == next(fixture)
      assert %{"v" => 1, "ok" => true} == sent(fixture, @first["id"]), "a repeated report"
      assert InputSupplier.marked(supplier) == [@first["id"]]
      assert %{"v" => 1, "ok" => true} == sent(fixture, @second["id"])
      assert %{"v" => 1, "ok" => nil} == next(fixture)

      invocation = invocation_of(fixture)
      assert [{:next, ^invocation} | _rest] = InputSupplier.asks(supplier)
      assert Enum.all?(InputSupplier.asks(supplier), &(elem(&1, 1) == invocation))
      assert Process.alive?(fixture.pid)
    end

    test "is told unavailable for a report its supplier refuses: one never offered to it" do
      supplier = InputSupplier.start!([@first])
      fixture = attached(inputs: supplier)

      assert %{"v" => 1, "error" => "unavailable"} == sent(fixture, @first["id"])
      assert InputSupplier.marked(supplier) == []
    end
  end

  describe "with no supplier" do
    test "a read is none and a report is unavailable" do
      fixture = attached([])

      assert %{"v" => 1, "ok" => nil} == next(fixture)
      assert %{"v" => 1, "error" => "unavailable"} == sent(fixture, "evt_input.1")
      assert Process.alive?(fixture.pid)
    end
  end

  describe "a supplier that cannot answer" do
    test "one that is gone: a read and a report are unavailable, not an empty input" do
      supplier = spawn(fn -> :ok end)
      ref = Process.monitor(supplier)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}
      fixture = attached(inputs: supplier)

      assert %{"v" => 1, "error" => "unavailable"} == next(fixture)
      assert %{"v" => 1, "error" => "unavailable"} == sent(fixture, "evt_input.1")
    end

    test "one that is silent: a read is unavailable once its wait ends, and a late answer reaches no one" do
      supplier = InputSupplier.start!([@first], mode: :silent)
      fixture = attached(inputs: supplier)

      {elapsed, answer} = :timer.tc(fn -> next(fixture) end, :millisecond)
      assert answer == %{"v" => 1, "error" => "unavailable"}
      assert elapsed >= Opus.Inputs.answer_ms()
      assert elapsed < Prima.HostAPI.request_timeout_ms(:input_next)
    end

    test "one that answers no answer of the port's: a read is unavailable" do
      supplier = InputSupplier.start!([], mode: {:answer, fn _invocation -> :maybe end})
      fixture = attached(inputs: supplier)

      assert %{"v" => 1, "error" => "unavailable"} == next(fixture)
    end
  end

  describe "anyone but the invocation's own live runner" do
    @tag :capture_log
    test "another runner, another fence, a replayed nonce or a malformed id is lost, and nobody is asked" do
      supplier = InputSupplier.start!([@first])
      fixture = attached(inputs: supplier)

      assert %{"v" => 1, "error" => "lost"} == next(fixture, runner: "runner_other")
      assert %{"v" => 1, "error" => "lost"} == next(fixture, fence: fixture.fence + 1)
      assert %{"v" => 1, "error" => "lost"} == sent(fixture, @first["id"], runner: "runner_other")
      assert %{"v" => 1, "error" => "lost"} == sent(fixture, "evt input")

      assert %{"v" => 1, "error" => "lost"} ==
               AttemptFixtures.call(fixture, "input_next", %{"id" => "evt_input.1"})

      assert InputSupplier.asks(supplier) == []

      assert %{"ok" => _input} = next(fixture, nonce: "n_inputs_once")
      assert %{"v" => 1, "error" => "lost"} == next(fixture, nonce: "n_inputs_once")
      assert [{:next, _invocation}] = InputSupplier.asks(supplier)
    end

    @tag :capture_log
    test "a cancelled invocation is handed nothing and marks nothing" do
      supplier = InputSupplier.start!([@first])
      fixture = attached(inputs: supplier)
      assert %{"ok" => @first} = next(fixture)

      assert {:ok, %{cancelled: true}} = Opus.cancel(fixture.ctx, fixture.execution_id)

      assert %{"v" => 1, "error" => "lost"} == next(fixture)
      assert %{"v" => 1, "error" => "lost"} == sent(fixture, @first["id"])
      assert [{:next, _invocation}] = InputSupplier.asks(supplier)
      assert InputSupplier.marked(supplier) == []
    end

    @tag :capture_log
    test "an input answered while its invocation was stopped is handed nothing" do
      parent = self()

      stop = fn invocation ->
        send(parent, {:cancel, invocation})

        receive do
          :cancelled -> {:ok, @first}
        end
      end

      supplier = InputSupplier.start!([], mode: {:answer, stop})
      fixture = attached(inputs: supplier)
      task = Task.async(fn -> next(fixture) end)

      assert_receive {:cancel, _invocation}, 2_000
      assert {:ok, %{cancelled: true}} = Opus.cancel(fixture.ctx, fixture.execution_id)
      send(supplier, :cancelled)

      assert Task.await(task) == %{"v" => 1, "error" => "lost"}
    end
  end

  describe "the supplier's hold" do
    test "stands while the invocation holds its attempt, and refuses a mark once it does not" do
      fixture = attached([])
      invocation = invocation_of(fixture)

      assert {:ok, true} = Arca.Repo.locking_transaction(fn -> Opus.Inputs.held!(invocation) end)

      assert {:ok, false} =
               Arca.Repo.locking_transaction(fn ->
                 Opus.Inputs.held!(%{invocation | attempt: "att_other"})
               end)

      assert {:ok, %{cancelled: true}} = Opus.cancel(fixture.ctx, fixture.execution_id)

      assert {:ok, false} = Arca.Repo.locking_transaction(fn -> Opus.Inputs.held!(invocation) end)
    end

    @tag :capture_log
    test "a report the supplier receives for an attempt it no longer holds is refused and marks nothing" do
      supplier = InputSupplier.start!([@first])
      fixture = attached(inputs: supplier)
      invocation = invocation_of(fixture)
      assert %{"ok" => @first} = next(fixture)

      assert {:ok, %{cancelled: true}} = Opus.cancel(fixture.ctx, fixture.execution_id)

      # A report that passed the host's check just before the cancel: the
      # supplier's own transaction refuses it.
      assert {:ok, {:error, :not_held}} = Opus.Inputs.sent(supplier, invocation, @first["id"])
      assert InputSupplier.marked(supplier) == []
    end
  end

  describe "a supplier's input" do
    test "that does not read is refused by its member, and nothing it carries is logged" do
      secret = "the person's private words 7c41"

      bad = fn _invocation ->
        {:ok, %{"id" => "evt_x", "content" => [%{"type" => "audio", "text" => secret}]}}
      end

      supplier = InputSupplier.start!([], mode: {:answer, bad})
      fixture = attached(inputs: supplier)

      log =
        capture_log(fn ->
          assert %{
                   "v" => 1,
                   "error" => "guest_error",
                   "type" => "invalid_request",
                   "message" => message
                 } = next(fixture)

          assert message =~ "content[0].type"
          refute message =~ secret
        end)

      assert log =~ "content[0].type"
      refute log =~ secret
    end

    test "whose text is not UTF-8 is refused, and none of its bytes reaches the log" do
      bad = fn _invocation ->
        {:ok, %{"id" => "evt_x", "content" => <<"private ", 0xFF, " words 9d2e">>}}
      end

      supplier = InputSupplier.start!([], mode: {:answer, bad})
      fixture = attached(inputs: supplier)

      log =
        capture_log(fn ->
          assert %{"error" => "guest_error", "type" => "invalid_request", "message" => message} =
                   next(fixture)

          assert message =~ "(content)"
        end)

      refute log =~ "9d2e"
      assert Process.alive?(fixture.pid)
    end

    @tag :capture_log
    test "that is no input at all is refused, naming input" do
      supplier = InputSupplier.start!([], mode: {:answer, fn _invocation -> {:ok, "hi"} end})
      fixture = attached(inputs: supplier)

      assert %{"error" => "guest_error", "type" => "invalid_request", "message" => message} =
               next(fixture)

      assert message =~ "(input)"
    end
  end
end
