# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TurnTransitionContractTest do
  @moduledoc """
  Every transition whose legality once rested on the caller's map is
  decided by the rows: for each, the move the rows do not allow is refused
  and writes nothing, and the one they allow is admitted. The rows are
  read after the turn row is taken, so a caller's stale view decides
  nothing, and of two writers racing on one fence exactly one lands.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ExecutionAttempts
  alias Arca.Schemas.{Execution, ExecutionAttempt, Turn, TurnStep}
  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage

  @standing %{grant: :stored, verify: &Arca.Test.Actor.admits/1}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Test.Actor.athanor!()
    actor = Arca.Test.Actor.local()
    {:ok, thread} = Threads.create(actor)
    {:ok, actor: actor, thread: thread}
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp accept!(actor, thread) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: actor.user_id, content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
      })

    turn
  end

  defp root!(actor, turn_id, attrs \\ %{}) do
    budget_id = "bgt_#{System.unique_integer([:positive])}"

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        Map.merge(
          %{
            id: "exec_contract_#{System.unique_integer([:positive])}",
            reference: "agent:local.aqua",
            user_id: actor.user_id,
            athanor_id: actor.athanor_id,
            component_type: "agent",
            kind: "turn",
            turn_id: turn_id,
            profile_id: "prof_root",
            origin: :interactive
          },
          attrs
        ),
        reservation: %{budget_id: budget_id, cap: 4},
        grant: Arca.Test.Actor.grant(actor.athanor_id),
        verify: &Arca.Test.Actor.admits/1
      )

    %{execution: execution, attempt: attempt, budget_id: budget_id}
  end

  defp start_attrs(turn, root, extra \\ %{}) do
    Map.merge(
      %{
        root_execution_id: root.execution.id,
        attempt: root.attempt.attempt,
        budget_id: root.budget_id,
        profile_id: "prof_root",
        recovery_limit: 3,
        fence: turn.fence
      },
      extra
    )
  end

  defp started!(actor, thread) do
    turn = accept!(actor, thread)
    root = root!(actor, turn.id)
    {:ok, started} = TurnStorage.start(actor, turn.id, start_attrs(turn, root))
    {started, root}
  end

  defp model_step!(actor, turn) do
    {:ok, step} = TurnStorage.put_step(actor, turn.id, %{kind: "model", fence: turn.fence})
    step
  end

  defp call_step!(actor, turn, call \\ %{}) do
    model = model_step!(actor, turn)

    {:ok, %{calls: [%{step: step}]}} =
      TurnStorage.record_response(actor, turn.id, model.id, %{
        fence: turn.fence,
        tool_calls: [
          Map.merge(
            %{tool_call_id: "c1", name: "files.write", tool: "files", action: "write"},
            call
          )
        ]
      })

    step
  end

  defp row(id), do: Arca.Repo.get!(Turn, id)
  defp execution(id), do: Arca.Repo.get!(Execution, id)
  defp step_row(id), do: Arca.Repo.get!(TurnStep, id)

  defp set_turn!(id, sets),
    do: {1, _} = Arca.Repo.update_all(from(t in Turn, where: t.id == ^id), set: sets)

  # ---------------------------------------------------------------------------
  # start
  # ---------------------------------------------------------------------------

  describe "start binds only the turn's own root, attempt and reservation" do
    test "another turn's root, a root that is not running and a foreign attempt are refused",
         %{actor: actor, thread: thread} do
      turn = accept!(actor, thread)
      other = root!(actor, "trn_someone_else")

      assert {:error, :illegal_transition} =
               TurnStorage.start(actor, turn.id, start_attrs(turn, other))

      root = root!(actor, turn.id)

      assert {:error, :illegal_transition} =
               TurnStorage.start(
                 actor,
                 turn.id,
                 start_attrs(turn, root, %{attempt: other.attempt.attempt})
               )

      assert {:error, :illegal_transition} =
               TurnStorage.start(actor, turn.id, start_attrs(turn, root, %{budget_id: "bgt_x"}))

      assert {:error, :illegal_transition} =
               TurnStorage.start(
                 actor,
                 turn.id,
                 start_attrs(turn, root, %{profile_id: "prof_other"})
               )

      {1, _} =
        Arca.Repo.update_all(from(e in Execution, where: e.id == ^root.execution.id),
          set: [status: "completed"]
        )

      assert {:error, :illegal_transition} =
               TurnStorage.start(actor, turn.id, start_attrs(turn, root))

      assert %{status: "accepted", root_execution_id: nil, recovery_limit: nil} = row(turn.id)
    end

    test "the root's rows fill what the caller left out, and the limit is required and positive",
         %{actor: actor, thread: thread} do
      turn = accept!(actor, thread)
      root = root!(actor, turn.id)

      for limit <- [nil, 0, -1, "3"] do
        assert {:error, :illegal_transition} =
                 TurnStorage.start(
                   actor,
                   turn.id,
                   start_attrs(turn, root, %{recovery_limit: limit})
                 )
      end

      assert {:ok, started} =
               TurnStorage.start(actor, turn.id, %{
                 root_execution_id: root.execution.id,
                 recovery_limit: 2,
                 fence: turn.fence
               })

      assert started.attempt == root.attempt.attempt
      assert started.budget_id == root.budget_id
      assert started.profile_id == "prof_root"
      assert started.recovery_limit == 2
    end

    test "a rootless turn names no attempt and no budget", %{actor: actor, thread: thread} do
      turn = accept!(actor, thread)

      assert {:error, :illegal_transition} =
               TurnStorage.start(actor, turn.id, %{
                 attempt: "att_x",
                 recovery_limit: 3,
                 fence: turn.fence
               })

      assert {:ok, %{status: "running", attempt: nil}} =
               TurnStorage.start(actor, turn.id, %{recovery_limit: 3, fence: turn.fence})
    end
  end

  # ---------------------------------------------------------------------------
  # The root's grant and the lease
  # ---------------------------------------------------------------------------

  describe "the root's grant is required where the write must stand" do
    test "a resume, a completion, a recovery, a takeover and a set-down without a check are refused",
         %{actor: actor, thread: thread} do
      {turn, _root} = started!(actor, thread)
      {:ok, paused} = TurnStorage.pause(actor, turn.id, %{fence: turn.fence})

      assert {:error, :missing_grant} = TurnStorage.resume(actor, turn.id, %{fence: paused.fence})

      assert {:error, :missing_grant} =
               TurnStorage.resume(actor, turn.id, %{fence: paused.fence, grant: :stored})

      assert {:error, :missing_grant} =
               TurnStorage.finish(actor, turn.id, "completed", %{fence: paused.fence})

      assert {:error, :missing_grant} =
               TurnStorage.recover(actor, turn.id, %{fence: paused.fence})

      assert {:error, :missing_grant} =
               TurnStorage.takeover(actor, turn.id, %{fence: paused.fence})

      {:ok, running} =
        TurnStorage.resume(actor, turn.id, Map.put(@standing, :fence, paused.fence))

      assert {:error, :missing_grant} =
               TurnStorage.pause_recovered(actor, turn.id, %{fence: running.fence, content: "x"})

      assert %{status: "running", recovery_attempts: 0} = row(turn.id)
    end

    test "a completion of a rootless turn still names its check; a cancel does not",
         %{actor: actor, thread: thread} do
      turn = accept!(actor, thread)

      assert {:error, :missing_grant} =
               TurnStorage.finish(actor, turn.id, "completed", %{fence: turn.fence})

      assert {:ok, %{status: "cancelled"}} =
               TurnStorage.finish(actor, turn.id, "cancelled", %{fence: turn.fence})
    end

    test "the check's refusal writes nothing, and it runs after the turn row is read again",
         %{actor: actor, thread: thread} do
      {turn, _root} = started!(actor, thread)
      {:ok, paused} = TurnStorage.pause(actor, turn.id, %{fence: turn.fence})
      test = self()

      refuse = fn grant ->
        send(test, {:asked, grant, Arca.Repo.get!(Turn, turn.id).fence})
        {:error, :not_standing}
      end

      assert {:error, :not_standing} =
               TurnStorage.resume(actor, turn.id, %{
                 fence: paused.fence,
                 grant: :stored,
                 verify: refuse
               })

      assert_received {:asked, %Prima.ExecutionGrant{}, fence}
      assert fence == paused.fence
      assert %{status: "paused"} = row(turn.id)
    end

    test "a lease the caller names is not the one written: the database's clock is",
         %{actor: actor, thread: thread} do
      {turn, root} = started!(actor, thread)
      {:ok, paused} = TurnStorage.pause(actor, turn.id, %{fence: turn.fence})
      stale = DateTime.add(DateTime.utc_now(), -3_600, :second)

      assert {:ok, _} =
               TurnStorage.resume(
                 actor,
                 turn.id,
                 Map.merge(@standing, %{fence: paused.fence, lease_until: stale})
               )

      lease = ExecutionAttempts.get(actor, root.attempt.attempt).lease_until
      assert DateTime.compare(lease, DateTime.utc_now()) == :gt
    end
  end

  # ---------------------------------------------------------------------------
  # recover and takeover: the stored limit
  # ---------------------------------------------------------------------------

  describe "the recovery limit is the turn's stored one" do
    test "a caller's limit never widens a started turn's", %{actor: actor, thread: thread} do
      {turn, _root} = started!(actor, thread)
      set_turn!(turn.id, recovery_limit: 1)
      {:ok, suspended} = TurnStorage.suspend(actor, turn.id, %{fence: turn.fence})

      assert {:ok, recovered} =
               TurnStorage.recover(
                 actor,
                 turn.id,
                 Map.merge(@standing, %{fence: suspended.fence, recovery_limit: 100})
               )

      assert recovered.recovery_limit == 1
      assert recovered.recovery_attempts == 1

      assert {:error, :recovery_exhausted} =
               TurnStorage.recover(
                 actor,
                 turn.id,
                 Map.merge(@standing, %{fence: recovered.fence, recovery_limit: 100})
               )

      assert {:error, :recovery_exhausted} =
               TurnStorage.takeover(
                 actor,
                 turn.id,
                 Map.merge(@standing, %{fence: recovered.fence, recovery_limit: 100})
               )

      assert %{recovery_attempts: 1, recovery_limit: 1} = row(turn.id)
    end

    test "an accepted turn's recovery is its first claim: it writes the limit and spends none",
         %{actor: actor, thread: thread} do
      turn = accept!(actor, thread)

      assert {:error, :illegal_transition} =
               TurnStorage.recover(actor, turn.id, Map.put(@standing, :fence, turn.fence))

      assert {:ok, recovered} =
               TurnStorage.recover(
                 actor,
                 turn.id,
                 Map.merge(@standing, %{fence: turn.fence, recovery_limit: 2})
               )

      assert %{status: "accepted", recovery_limit: 2, recovery_attempts: 0} = recovered

      # The limit it wrote is the one its start keeps.
      root = root!(actor, turn.id)

      assert {:ok, %{recovery_limit: 2}} =
               TurnStorage.start(
                 actor,
                 turn.id,
                 start_attrs(recovered, root, %{recovery_limit: 9})
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Adoption: a failed root is taken up only after a lapse
  # ---------------------------------------------------------------------------

  describe "a failed root is revived only by a lapse" do
    test "a root its owner closed failed is not adopted", %{actor: actor, thread: thread} do
      {turn, root} = started!(actor, thread)

      {:ok, _} =
        Arca.Execution.record_end(
          actor,
          root.execution.id,
          "failed",
          %{completed_at: DateTime.utc_now(), duration_ms: 1},
          root.attempt.attempt,
          Arca.Test.Actor.stored()
        )

      assert {:error, {:execution_not_in, ["running", "paused", "failed"]}} =
               TurnStorage.takeover(actor, turn.id, Map.put(@standing, :fence, turn.fence))

      assert {:error, {:execution_not_in, _}} =
               TurnStorage.recover(actor, turn.id, Map.put(@standing, :fence, turn.fence))

      assert {:error, {:execution_not_in, _}} =
               TurnStorage.pause_recovered(
                 actor,
                 turn.id,
                 Map.merge(@standing, %{fence: turn.fence, content: "x"})
               )

      assert execution(root.execution.id).status == "failed"
      assert %{recovery_attempts: 0, status: "running"} = row(turn.id)
    end

    test "a root a lapse failed is adopted, running again under a successor",
         %{actor: actor, thread: thread} do
      {turn, root} = started!(actor, thread)
      lease = ExecutionAttempts.get(actor, root.attempt.attempt).lease_until

      assert {1, _} =
               Arca.Execution.mark_failed_if_running(
                 root.execution.id,
                 %{completed_at: DateTime.utc_now(), duration_ms: 1, error_message: "lapsed"},
                 Keyword.merge(Arca.Test.Actor.stored(),
                   attempt: root.attempt.attempt,
                   lease_until: lease
                 )
               )

      assert %{state: "lapsed"} = ExecutionAttempts.get(actor, root.attempt.attempt)

      assert {:ok, taken} =
               TurnStorage.takeover(actor, turn.id, Map.put(@standing, :fence, turn.fence))

      assert taken.attempt != root.attempt.attempt
      assert execution(root.execution.id).status == "running"
    end

    test "a successor is never opened on an ended execution", %{actor: actor, thread: thread} do
      {_turn, root} = started!(actor, thread)

      {1, _} =
        Arca.Repo.update_all(from(e in Execution, where: e.id == ^root.execution.id),
          set: [status: "completed"]
        )

      assert {:error, {:execution_not_in, ["running", "paused", "failed"]}} =
               Arca.Repo.transaction(fn ->
                 ExecutionAttempts.takeover!(actor, root.execution.id,
                   boot_id: Prima.Boot.id(),
                   lease_until: ExecutionAttempts.lease_until(),
                   grant: Arca.ExecutionStanding.stored(actor, root.attempt.attempt)
                 )
               end)

      assert Arca.Repo.all(
               from(a in ExecutionAttempt,
                 where: a.execution_id == ^root.execution.id,
                 select: a.attempt
               )
             ) == [root.attempt.attempt]
    end
  end

  # ---------------------------------------------------------------------------
  # pause
  # ---------------------------------------------------------------------------

  describe "a pause names a runner's reason and its own launch step" do
    test "an unknown reason, a launch without its step and a step that is not a launch are refused",
         %{actor: actor, thread: thread} do
      {turn, _root} = started!(actor, thread)
      tool = call_step!(actor, turn)

      assert {:error, :illegal_transition} =
               TurnStorage.pause(actor, turn.id, %{fence: turn.fence, reason: "suspended"})

      assert {:error, :illegal_transition} =
               TurnStorage.pause(actor, turn.id, %{fence: turn.fence, reason: "launch"})

      assert {:error, :illegal_transition} =
               TurnStorage.pause(actor, turn.id, %{
                 fence: turn.fence,
                 reason: "launch",
                 launch_step_id: tool.id
               })

      assert {:error, :illegal_transition} =
               TurnStorage.pause(actor, turn.id, %{
                 fence: turn.fence,
                 reason: "approval",
                 launch_step_id: tool.id
               })

      launch = call_step!(actor, turn, %{tool_call_id: "l1", step_kind: "launch"})

      assert {:ok, %{status: "paused", paused_reason: "launch", launch_step_id: launch_id}} =
               TurnStorage.pause(actor, turn.id, %{
                 fence: turn.fence,
                 reason: "launch",
                 launch_step_id: launch.id
               })

      assert launch_id == launch.id
    end

    test "a root attempt that is not the running owner refuses the pause",
         %{actor: actor, thread: thread} do
      {turn, root} = started!(actor, thread)

      {1, _} =
        Arca.Repo.update_all(
          from(a in ExecutionAttempt, where: a.attempt == ^root.attempt.attempt),
          set: [state: "paused"]
        )

      assert {:error, :attempt_not_owner} =
               TurnStorage.pause(actor, turn.id, %{fence: turn.fence})

      assert %{status: "running"} = row(turn.id)
      assert execution(root.execution.id).status == "running"
    end
  end

  # ---------------------------------------------------------------------------
  # Steps
  # ---------------------------------------------------------------------------

  describe "steps are recorded, answered and replayed by the rows" do
    test "a step is recorded proposed or dispatched on a running turn only",
         %{actor: actor, thread: thread} do
      accepted = accept!(actor, thread)

      assert {:error, :illegal_transition} =
               TurnStorage.put_step(actor, accepted.id, %{kind: "model", fence: accepted.fence})

      {turn, _root} = started!(actor, thread)

      assert {:error, :illegal_transition} =
               TurnStorage.put_step(actor, turn.id, %{
                 kind: "model",
                 dispatch_state: "closed",
                 fence: turn.fence
               })

      assert {:ok, %{dispatch_state: "dispatched"}} =
               TurnStorage.put_step(actor, turn.id, %{
                 kind: "model",
                 dispatch_state: "dispatched",
                 fence: turn.fence
               })
    end

    test "a response answers this turn's model step, with a recovery of the vocabulary",
         %{actor: actor, thread: thread} do
      {turn, _root} = started!(actor, thread)
      model = model_step!(actor, turn)
      tool = call_step!(actor, turn)

      calls = [%{tool_call_id: "c9", name: "files.read", tool: "files", action: "read"}]

      assert {:error, :step_not_found} =
               TurnStorage.record_response(actor, turn.id, tool.id, %{
                 fence: turn.fence,
                 tool_calls: calls
               })

      assert {:error, :illegal_transition} =
               TurnStorage.record_response(actor, turn.id, model.id, %{
                 fence: turn.fence,
                 tool_calls: [Map.put(hd(calls), :recovery, "always")]
               })

      assert %{dispatch_state: "proposed"} = step_row(model.id)

      assert {:ok, %{calls: [%{step: %{recovery: "replay_safe"}}]}} =
               TurnStorage.record_response(actor, turn.id, model.id, %{
                 fence: turn.fence,
                 tool_calls: [Map.put(hd(calls), :recovery, "replay_safe")]
               })
    end

    test "a step is opened again only when it was dispatched and its row calls a replay",
         %{actor: actor, thread: thread} do
      {turn, _root} = started!(actor, thread)
      unsafe = call_step!(actor, turn)
      safe = call_step!(actor, turn, %{tool_call_id: "c2", recovery: "replay_safe"})
      next = %{fence: turn.fence, child_execution_id: Prima.UUID7.execution_id()}

      assert {:error, :not_dispatched} = TurnStorage.next_generation(actor, safe.id, next)

      {:ok, _} = TurnStorage.dispatch_step(actor, unsafe.id, %{fence: turn.fence})
      {:ok, _} = TurnStorage.dispatch_step(actor, safe.id, %{fence: turn.fence})

      assert {:error, :illegal_transition} = TurnStorage.next_generation(actor, unsafe.id, next)
      assert %{dispatch_state: "dispatched", generation: 0} = step_row(unsafe.id)

      assert {:ok, %{dispatch_state: "proposed", generation: 1}} =
               TurnStorage.next_generation(actor, safe.id, next)
    end
  end

  # ---------------------------------------------------------------------------
  # Approvals
  # ---------------------------------------------------------------------------

  describe "an approval is opened on a proposed step and resolved as its kind allows" do
    defp card!(actor, turn, step) do
      {:ok, %{approval: approval}} =
        TurnStorage.open_approval(actor, step.id, %{
          proposal_digest: "sha256:proposal",
          card: %{content: "may I?"},
          fence: turn.fence
        })

      approval
    end

    test "a card is opened only for a proposed step", %{actor: actor, thread: thread} do
      {turn, _root} = started!(actor, thread)
      step = call_step!(actor, turn)
      {:ok, _} = TurnStorage.dispatch_step(actor, step.id, %{fence: turn.fence})

      assert {:error, :not_proposed} =
               TurnStorage.open_approval(actor, step.id, %{
                 proposal_digest: "sha256:proposal",
                 fence: turn.fence
               })
    end

    test "an approval never turns a step into a launch, and a launch stays one",
         %{actor: actor, thread: thread} do
      {turn, _root} = started!(actor, thread)
      step = call_step!(actor, turn)
      approval = card!(actor, turn, step)

      assert {:error, :illegal_transition} =
               TurnStorage.resolve_approval(actor, approval.id, "approved", %{
                 resolution_kind: "launch",
                 fence: turn.fence
               })

      assert {:error, :illegal_transition} =
               TurnStorage.resolve_approval(actor, approval.id, "declined", %{
                 resolution_kind: "continue",
                 fence: turn.fence
               })

      assert {:ok, %{step: %{kind: "tool", dispatch_state: "proposed"}}} =
               TurnStorage.resolve_approval(actor, approval.id, "approved", %{
                 resolution_kind: "continue",
                 fence: turn.fence
               })

      launch = call_step!(actor, turn, %{tool_call_id: "l1", step_kind: "launch"})
      approval = card!(actor, turn, launch)

      assert {:ok, %{approval: %{resolution_kind: "launch"}, step: %{kind: "launch"}}} =
               TurnStorage.resolve_approval(actor, approval.id, "approved", %{
                 resolution_kind: "launch",
                 fence: turn.fence
               })
    end

    test "a scope outside the vocabulary and a grant that is not this turn's are refused",
         %{actor: actor, thread: thread} do
      {turn, _root} = started!(actor, thread)
      step = call_step!(actor, turn)
      approval = card!(actor, turn, step)

      grant = %{
        athanor_id: actor.athanor_id,
        scope: "thread",
        agent_name: turn.agent,
        tool: step.tool,
        action: step.action,
        thread_id: turn.thread_id,
        effect: "allow",
        granted_by: actor.user_id
      }

      resolve = fn attrs ->
        TurnStorage.resolve_approval(
          actor,
          approval.id,
          "approved",
          Map.merge(%{resolution_kind: "continue", fence: turn.fence}, attrs)
        )
      end

      assert {:error, :illegal_transition} = resolve.(%{scope: "forever"})

      for foreign <- [
            %{grant | athanor_id: "ath_other"},
            %{grant | agent_name: "someone"},
            %{grant | tool: "http"},
            %{grant | action: "delete"},
            %{grant | thread_id: "thr_other"}
          ] do
        assert {:error, :illegal_transition} = resolve.(%{scope: "thread", grants: [foreign]})
      end

      assert %{status: "pending"} = Arca.Repo.get!(Arca.Schemas.Approval, approval.id)
      assert {:ok, _} = resolve.(%{scope: "thread", grants: [grant]})
    end
  end

  # ---------------------------------------------------------------------------
  # Clones
  # ---------------------------------------------------------------------------

  describe "a clone binds only a dispatched clone step of its parent" do
    test "a step of another turn, and a parent step that is not a clone, are refused",
         %{actor: actor, thread: thread} do
      {turn, _root} = started!(actor, thread)
      {:ok, other_thread} = Threads.create(actor)
      {other, _root} = started!(actor, other_thread)
      foreign = call_step!(actor, other, %{step_kind: "clone"})
      {:ok, _} = TurnStorage.dispatch_step(actor, foreign.id, %{fence: other.fence})
      tool = call_step!(actor, turn)

      for step_id <- [foreign.id, tool.id] do
        assert {:error, :illegal_transition} =
                 TurnStorage.open_clone_turn(actor, turn.id, %{
                   role: "helper",
                   step_id: step_id,
                   fence: turn.fence
                 })
      end

      assert {:ok, %{turn: clone, step: %{kind: "clone"}}} =
               TurnStorage.open_clone_turn(actor, turn.id, %{role: "helper", fence: turn.fence})

      assert clone.recovery_limit == turn.recovery_limit
    end
  end

  # ---------------------------------------------------------------------------
  # A turn that is over
  # ---------------------------------------------------------------------------

  describe "a turn that is over takes no row, pin, card or bookkeeping" do
    test "each write is refused :not_open under the fence that still matches",
         %{actor: actor, thread: thread} do
      {turn, _root} = started!(actor, thread)
      step = call_step!(actor, turn)

      {:ok, over} =
        TurnStorage.finish(actor, turn.id, "cancelled", Map.put(@standing, :fence, turn.fence))

      held = %{fence: over.fence}

      assert {:error, :not_open} = TurnStorage.pin_catalyst(actor, turn.id, "cat@1", held)

      assert {:error, :not_open} =
               TurnStorage.append_turn_row(
                 actor,
                 turn.id,
                 Map.merge(held, %{author: "system", kind: "text", content: "late"})
               )

      assert {:error, :not_open} = TurnStorage.drain_steer(actor, turn.id, held)

      assert {:error, :not_open} =
               TurnStorage.update_step(actor, step.id, Map.put(held, :error, "late"))

      assert {:error, :not_open} =
               TurnStorage.open_approval(
                 actor,
                 step.id,
                 Map.put(held, :proposal_digest, "sha256:p")
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Executions
  # ---------------------------------------------------------------------------

  describe "an execution ends on the attempt that owns it, with an outcome its status allows" do
    test "a row with an attempt is not ended on none, and an outcome off its status is refused",
         %{actor: actor, thread: thread} do
      {_turn, root} = started!(actor, thread)
      now = DateTime.utc_now()
      ended = %{completed_at: now, duration_ms: 1}
      id = root.execution.id
      attempt = root.attempt.attempt

      assert {:error, :attempt_not_owner} =
               Arca.Execution.record_end(
                 actor,
                 id,
                 "failed",
                 ended,
                 nil,
                 Arca.Test.Actor.stored()
               )

      for {status, outcome} <- [
            {"failed", "ok"},
            {"completed", "uncertain"},
            {"cancelled", "error"}
          ] do
        assert {:error, :illegal_transition} =
                 Arca.Execution.record_end(
                   actor,
                   id,
                   status,
                   Map.put(ended, :outcome, outcome),
                   attempt,
                   Arca.Test.Actor.stored()
                 )
      end

      assert execution(id).status == "running"

      assert {:ok, %{status: "failed"}} =
               Arca.Execution.record_end(
                 actor,
                 id,
                 "failed",
                 Map.merge(ended, %{outcome: "uncertain", event: %{"status" => "completed"}}),
                 attempt,
                 Arca.Test.Actor.stored()
               )

      assert %{state: "failed", outcome: "uncertain"} = ExecutionAttempts.get(actor, attempt)
      [event] = events(id, "execution.failed")
      assert event.data =~ ~s("status":"failed")
    end

    test "a failure's event is named by how its attempt was retired, never by the caller",
         %{actor: actor, thread: thread} do
      {_turn, a} = started!(actor, thread)
      {:ok, other_thread} = Threads.create(actor)
      {_turn, b} = started!(actor, other_thread)
      fail = %{completed_at: DateTime.utc_now(), duration_ms: 1, error_message: "gone"}
      lease = ExecutionAttempts.get(actor, a.attempt.attempt).lease_until

      assert {1, _} =
               Arca.Execution.mark_failed_if_running(
                 a.execution.id,
                 fail,
                 Arca.Test.Actor.stored() ++
                   [attempt: a.attempt.attempt, lease_until: lease, event: "execution.completed"]
               )

      assert {1, _} =
               Arca.Execution.mark_failed_if_running(
                 b.execution.id,
                 fail,
                 Arca.Test.Actor.stored() ++
                   [attempt: b.attempt.attempt, event: "execution.completed"]
               )

      assert [_] = events(a.execution.id, "execution.lapsed")
      assert [_] = events(b.execution.id, "execution.failed")
      assert [] = events(a.execution.id, "execution.completed")
      assert [] = events(b.execution.id, "execution.completed")
    end

    test "the test writers keep to the vocabulary", %{actor: actor} do
      base = %{
        id: "exec_writer_#{System.unique_integer([:positive])}",
        reference: "reagent:local.test:1.0.0",
        user_id: actor.user_id,
        athanor_id: actor.athanor_id,
        component_type: "reagent",
        started_at: DateTime.utc_now()
      }

      assert {:error, :illegal_transition} =
               Arca.Execution.record_start(
                 Map.merge(base, %{status: "running", current_attempt: "att_x"})
               )

      assert {:error, {:invalid, _}} =
               Arca.Execution.record_start(Map.put(base, :status, "sleeping"))

      assert {:ok, row} = Arca.Execution.record_start(Map.put(base, :status, "running"))

      done = %{completed_at: DateTime.utc_now(), duration_ms: 1, status: "completed"}
      opts = [grant: Arca.Test.Actor.grant(actor.athanor_id), verify: &Arca.Test.Actor.admits/1]

      assert {:error, :illegal_transition} =
               Arca.Execution.record_complete(
                 actor,
                 row.id,
                 Map.put(done, :outcome, "error"),
                 opts
               )

      assert {:ok, %{status: "completed"}} =
               Arca.Execution.record_complete(actor, row.id, done, opts)
    end
  end

  describe "admission holds the barriers the row's own columns call for" do
    test "a child that declares no parent attempt is held against the parent's current one",
         %{actor: actor, thread: thread} do
      {_turn, root} = started!(actor, thread)

      child = fn ->
        Arca.Execution.admit(
          %{
            id: "exec_child_#{System.unique_integer([:positive])}",
            reference: "reagent:local.test:1.0.0",
            user_id: actor.user_id,
            athanor_id: actor.athanor_id,
            component_type: "reagent",
            parent_execution_id: root.execution.id,
            root_execution_id: root.execution.id
          },
          grant: Arca.ExecutionStanding.stored(actor, root.attempt.attempt),
          verify: &Arca.Test.Actor.admits/1
        )
      end

      assert {:ok, _} = child.()

      {1, _} =
        Arca.Repo.update_all(
          from(a in ExecutionAttempt, where: a.attempt == ^root.attempt.attempt),
          set: [state: "paused"]
        )

      assert {:error, :parent_ended} = child.()
    end

    test "a scheduled root is admitted only against its occurrence", %{actor: actor} do
      assert {:error, :occurrence_not_claimed} =
               Arca.Execution.admit(
                 %{
                   id: "exec_sched_#{System.unique_integer([:positive])}",
                   reference: "reagent:local.test:1.0.0",
                   user_id: actor.user_id,
                   athanor_id: actor.athanor_id,
                   component_type: "reagent",
                   schedule_id: "sched_x",
                   origin: :schedule
                 },
                 Arca.Test.Actor.standing()
               )
    end
  end

  # ---------------------------------------------------------------------------
  # The rereads under the lock
  # ---------------------------------------------------------------------------

  describe "a transition reads its rows under the turn's lock" do
    test "of a recovery and a takeover racing on one fence, one lands and one recovery is spent",
         %{actor: actor, thread: thread} do
      {turn, _root} = started!(actor, thread)
      attrs = Map.put(@standing, :fence, turn.fence)

      results =
        [&TurnStorage.recover/3, &TurnStorage.takeover/3]
        |> Enum.map(fn transition ->
          Task.async(fn -> transition.(actor, turn.id, attrs) end)
        end)
        |> Enum.map(&Task.await(&1, 25_000))

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, _}, &1)) == 1

      assert %{recovery_attempts: 1} = row(turn.id)
    end
  end

  defp events(execution_id, type) do
    Arca.Repo.all(
      from(e in Arca.Schemas.ExecutionEvent,
        where: e.execution_id == ^execution_id and e.type == ^type
      )
    )
  end
end
