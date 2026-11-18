# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TurnInputsStorageTest do
  @moduledoc """
  What a program brain's turn writes at its owner (`Arca.TurnStorage`'s
  "A program brain's session"): a delivery is one `input` step recorded
  before its command, a post it carries is history, a batch's effects
  commit with its position once, usage is counted once against its work,
  and the silence clock runs only while the program owes output. Each
  write is placed before and after the one it races.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{Message, Thread, TurnStep}
  alias Arca.TurnStorage

  @stored %{grant: :stored, verify: &Arca.Test.Actor.admits/1}
  @silence 60_000

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Test.Actor.athanor!()
    actor = Arca.Test.Actor.local()
    {:ok, daily} = Arca.Test.Days.thread(actor)
    turn = running!(actor, daily)
    start = start!(actor, turn)
    {:ok, actor: actor, daily: daily, turn: turn, start: start}
  end

  # ---- fixtures ------------------------------------------------------------

  # A turn of Aqua's on a program brain, accepted on a person's post in
  # `thread` and started with its root, as the loop starts one.
  defp running!(actor, thread) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: actor.user_id, sent_by: "person", content: "go"},
        turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
      })

    budget_id = "bgt_#{System.unique_integer([:positive])}"

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_root_#{System.unique_integer([:positive])}",
          reference: "agent:local.aqua",
          user_id: actor.user_id,
          athanor_id: actor.athanor_id,
          component_type: "agent",
          kind: "turn",
          turn_id: turn.id,
          origin: :interactive
        },
        reservation: %{budget_id: budget_id, cap: 4},
        grant: Arca.Test.Actor.grant(actor.athanor_id),
        verify: &Arca.Test.Actor.admits/1
      )

    {:ok, started} =
      TurnStorage.start(actor, turn.id, %{
        root_execution_id: execution.id,
        attempt: attempt.attempt,
        budget_id: budget_id,
        recovery_limit: 3,
        fence: turn.fence
      })

    {:ok, pinned} =
      TurnStorage.pin_program(actor, started.id, "prg_brain", %{fence: started.fence})

    pinned
  end

  # The host's `program.start` of the turn, decided and dispatched as the
  # loop dispatches it, with its call's row.
  defp start!(actor, turn, state \\ "dispatched") do
    {:ok, step} =
      TurnStorage.put_step(actor, turn.id, %{
        kind: "tool",
        purpose: "brain",
        tool: "program",
        action: "start",
        idempotency_key: TurnStorage.brain_start_key(turn.id),
        dispatch_state: state,
        fence: turn.fence,
        call: %{
          kind: "tool_call",
          content: "program",
          payload: %{"tool" => "program", "action" => "start", "tool_call_id" => "start"}
        }
      })

    step
  end

  # A person's post into the running turn.
  defp steer!(actor, thread, turn, content) do
    {:ok, %{message: row}} =
      TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: actor.user_id, sent_by: "person", content: content},
        steer_turn_id: turn.id
      })

    row
  end

  defp carry(actor, turn, deliver, row, extra \\ %{}),
    do:
      TurnStorage.carry(
        actor,
        turn.id,
        Map.merge(
          %{
            fence: turn.fence,
            deliver: deliver,
            row_id: row.id,
            generation: 0,
            silence_ms: @silence
          },
          extra
        )
      )

  defp commit(actor, thread, turn, attrs) do
    TurnStorage.commit_brain(
      actor,
      thread.id,
      Map.merge(
        %{
          agent: "aqua",
          generation: 0,
          boot: "boot-1",
          seq: System.unique_integer([:positive]),
          row_id: "prg_brain",
          epoch: 1,
          silence_ms: @silence,
          turn: turn && %{id: turn.id, fence: turn.fence}
        },
        attrs
      )
    )
  end

  defp finish(actor, turn, status),
    do: TurnStorage.finish(actor, turn.id, status, Map.put(@stored, :fence, turn.fence))

  defp carried_by(row), do: Arca.Repo.get!(Message, row.id).carried_by
  defp step(id), do: Arca.Repo.get!(TurnStep, id)
  defp fresh(actor, turn), do: elem(TurnStorage.get(actor, turn.id), 1)

  defp progress(thread),
    do: Jason.decode!(Arca.Repo.get!(Thread, thread.id).brain_progress || "{}")

  # The turn's own post, which opened it.
  defp opening(actor, turn) do
    {:ok, [row]} = TurnStorage.brain_posts(actor, turn.id)
    row
  end

  # ---- deliveries ------------------------------------------------------------

  test "a post its input step carried is history: no steer, never drained, and the turn's end " <>
         "waits for the idle that names it, never for its acceptance",
       %{actor: actor, daily: daily, turn: turn} do
    first = opening(actor, turn)
    later = steer!(actor, daily, turn, "and the moon")
    assert TurnStorage.steer_pending?(actor, turn.id) == true

    assert {:ok, %{step: step, row: %{id: first_id}}} = carry(actor, turn, "post", first)
    assert first_id == first.id
    assert {:ok, %{step: later_step}} = carry(actor, turn, "post", later)

    for {row, input} <- [{first, step}, {later, later_step}] do
      assert %TurnStep{
               kind: "input",
               purpose: "brain",
               tool: "program",
               dispatch_state: "dispatched",
               outcome: nil
             } = step(input.id)

      assert step(input.id).action == "post"
      assert step(input.id).message_id == row.id
      assert step(input.id).idempotency_key == "0:post:#{row.id}"
      assert carried_by(row) == input.id
    end

    assert TurnStorage.steer_pending?(actor, turn.id) == false
    window = fresh(actor, turn).window_upto_seq
    assert {:ok, []} = TurnStorage.drain_steer(actor, turn.id, %{fence: turn.fence})
    assert fresh(actor, turn).window_upto_seq == window
    assert {:ok, rows} = TurnStorage.projection(actor, turn.id)
    assert later.id in Enum.map(rows, & &1.id)
    assert progress(daily)["owed"] == [step.id, later_step.id]

    assert {:error, :call_pending} = finish(actor, turn, "completed")

    assert {:ok, %{seen: false}} =
             commit(actor, daily, turn, %{accepted: [step.id, later_step.id], busy: true})

    assert step(step.id).dispatch_state == "closed" and step(step.id).outcome == "ok"
    assert {:error, :call_pending} = finish(actor, turn, "completed")

    assert {:ok, _} = commit(actor, daily, turn, %{answered: [step.id], busy: false})
    assert {:error, :call_pending} = finish(actor, turn, "completed")
    assert {:ok, _} = commit(actor, daily, turn, %{answered: [later_step.id], busy: false})
    assert progress(daily)["owed"] == []
    assert {:ok, %{status: "completed"}} = finish(actor, turn, "completed")
  end

  test "a delivery is checked before its row: a take-over, a start not decided, another " <>
         "generation, a delivery already recorded and a turn that is over record nothing",
       %{actor: actor, daily: daily, turn: turn} do
    row = opening(actor, turn)

    assert {:error, :superseded} = carry(actor, %{turn | fence: turn.fence + 1}, "post", row)
    assert {:error, :generation_moved} = carry(actor, turn, "post", row, %{generation: 3})
    assert carried_by(row) == nil

    assert {:ok, %{step: step}} = carry(actor, turn, "post", row)
    assert {:error, :carried} = carry(actor, turn, "post", row)
    assert {:error, :not_waiting} = carry(actor, turn, "post", %{id: "msg_none"})
    assert carried_by(row) == step.id

    {:ok, _} = finish(actor, turn, "cancelled")
    later = steer!(actor, daily, running!(actor, daily), "for another turn")
    assert {:error, :not_running} = carry(actor, turn, "post", later)
  end

  test "a turn paused on its own program.start's card is written nothing; one paused on an " <>
         "ask's card takes a post or an answer, never a notice",
       %{actor: actor, daily: daily, turn: first} do
    {:ok, _} = finish(actor, first, "cancelled")
    carded = running!(actor, daily)
    _start = start!(actor, carded, "proposed")
    assert {:error, :not_admitted} = carry(actor, carded, "post", opening(actor, carded))

    {:ok, _} = finish(actor, carded, "cancelled")
    turn = running!(actor, daily)
    _start = start!(actor, turn)
    row = opening(actor, turn)
    {:ok, paused} = TurnStorage.pause(actor, turn.id, %{fence: turn.fence})
    assert paused.status == "paused"

    assert {:ok, %{step: step}} = carry(actor, paused, "post", row)
    assert {:error, :not_running} = carry(actor, paused, "notice", row)
    assert carried_by(row) == step.id
  end

  test "a delivery whose command was certainly not written is taken back: its post waits again " <>
         "and owes nothing",
       %{actor: actor, daily: daily, turn: turn} do
    row = opening(actor, turn)
    {:ok, %{step: step}} = carry(actor, turn, "post", row)
    assert :ok = TurnStorage.uncarry(actor, turn.id, %{fence: turn.fence, step_id: step.id})
    assert carried_by(row) == nil
    assert Arca.Repo.get(TurnStep, step.id) == nil
    assert progress(daily)["owed"] == []
    assert {:ok, [%{id: waiting}]} = TurnStorage.brain_posts(actor, turn.id)
    assert waiting == row.id

    assert {:error, :not_dispatched} =
             TurnStorage.uncarry(actor, turn.id, %{fence: turn.fence, step_id: step.id})
  end

  # ---- batches ----------------------------------------------------------------

  test "a batch commits with its position once: a line at or before it is skipped, another " <>
         "driver process's batch without its hello and an older epoch commit nothing",
       %{actor: actor, daily: daily, turn: turn} do
    said = %{message: "msg_native_1", text: "hello"}

    assert {:ok, %{seen: false, said: [row]}} =
             commit(actor, daily, turn, %{seq: 5, hello: true, said: [said]})

    assert %{kind: "text", content: "hello", sent_by: "aqua", turn_id: turn_id} = row
    assert turn_id == turn.id
    assert {:ok, %{seen: true, said: []}} = commit(actor, daily, turn, %{seq: 5, said: [said]})
    assert {:ok, %{seen: true}} = commit(actor, daily, turn, %{seq: 4, said: [said]})

    assert {:error, :superseded} =
             commit(actor, daily, turn, %{boot: "boot-2", seq: 9, said: [said]})

    assert {:ok, %{seen: false}} =
             commit(actor, daily, turn, %{boot: "boot-2", seq: 1, hello: true})

    assert {:error, :row_changed} =
             commit(actor, daily, turn, %{boot: "boot-2", seq: 2, epoch: 0})

    assert %{"boot" => "boot-2", "seq" => 1, "row" => "prg_brain", "epoch" => 1} =
             progress(daily)

    texts =
      Arca.Repo.all(Message)
      |> Enum.filter(&(&1.thread_id == daily.id and &1.kind == "text" and &1.sent_by == "aqua"))

    assert length(texts) == 1
  end

  test "with no turn open a batch commits and is read past, and what the program says stays " <>
         "out of the thread",
       %{actor: actor, daily: daily, turn: turn} do
    {:ok, _} = finish(actor, turn, "cancelled")

    assert {:ok, %{seen: false, said: [], asks: []}} =
             commit(actor, daily, nil, %{
               seq: 3,
               hello: true,
               said: [%{message: "m", text: "late prose"}]
             })

    assert progress(daily)["seq"] == 3
    refute Enum.any?(Arca.Repo.all(Message), &(&1.content == "late prose"))
  end

  test "an ask is recorded once by its native id on a running and on a paused turn, and being " <>
         "recorded dispatches nothing",
       %{actor: actor, daily: daily, turn: turn} do
    ask = fn id ->
      %{
        kind: "tool",
        tool: "files",
        action: "read",
        idempotency_key: TurnStorage.brain_ask_key(turn.id, id),
        call: %{
          kind: "tool_call",
          content: "files",
          payload: %{"tool_call_id" => id, "name" => "files", "arguments" => %{}}
        }
      }
    end

    assert {:ok, %{asks: [first]}} = commit(actor, daily, turn, %{asks: [ask.("toolu_1")]})
    assert {:ok, %{asks: []}} = commit(actor, daily, turn, %{asks: [ask.("toolu_1")]})
    assert %TurnStep{purpose: "brain", dispatch_state: "proposed", tool: "files"} = step(first.id)
    assert %Message{kind: "tool_call"} = Arca.Repo.get!(Message, step(first.id).message_id)

    {:ok, paused} = TurnStorage.pause(actor, turn.id, %{fence: turn.fence})
    assert {:ok, %{asks: [held]}} = commit(actor, daily, paused, %{asks: [ask.("toolu_2")]})
    assert step(held.id).dispatch_state == "proposed"
    assert fresh(actor, turn).status == "paused"
  end

  # ---- usage --------------------------------------------------------------

  test "usage is counted once against the work it names, an ended turn's included without " <>
         "reopening it, else kept unattributed; an accounting it cannot read stays unknown",
       %{actor: actor, daily: daily, turn: turn, start: start} do
    counts = %{
      "input_tokens" => 1177,
      "output_tokens" => 19,
      "cache_read_tokens" => 649,
      "cache_write_tokens" => 3427
    }

    usage = fn result, work ->
      %{
        "t" => "usage",
        "gen" => 0,
        "work" => work,
        "result" => result,
        "accounting" => "complete",
        "models" => [%{"model" => "claude-haiku-5-5", "counts" => counts}]
      }
    end

    assert {:ok, _} = commit(actor, daily, turn, %{usage: [usage.("r1", turn.id)]})
    assert {:ok, _} = commit(actor, daily, turn, %{usage: [usage.("r1", turn.id)]})

    once = %{
      "models" => %{"claude-haiku-5-5" => counts},
      "results" => 1,
      "partial" => 0,
      "unknown" => 0
    }

    assert Jason.decode!(step(start.id).usage) == once

    {:ok, _} = finish(actor, turn, "failed")

    unknown = %{
      "t" => "usage",
      "gen" => 0,
      "work" => turn.id,
      "result" => "r2",
      "accounting" => "unavailable"
    }

    assert {:ok, _} = commit(actor, daily, nil, %{usage: [unknown, usage.("r3", nil)]})

    assert Jason.decode!(step(start.id).usage) == %{once | "results" => 2, "unknown" => 1}
    assert fresh(actor, turn).status == "failed"
    assert progress(daily)["unattributed"] == once
  end

  # ---- nudges ---------------------------------------------------------------

  test "a nudge its post step carried is answered by the idle that names it, never by its " <>
         "acceptance",
       %{actor: actor, daily: daily, turn: turn} do
    _first = carry(actor, turn, "post", opening(actor, turn))

    nudge =
      Arca.ThreadStorage.insert_message!(actor, Arca.Repo.get!(Thread, daily.id), %{
        author: "system",
        sent_by: "system",
        kind: "nudge",
        content: "Where does the work stand?",
        turn_id: turn.id
      })

    {:ok, %{step: step}} = carry(actor, turn, "post", nudge)
    {:ok, _} = commit(actor, daily, turn, %{accepted: [step.id], busy: true})
    assert Arca.Repo.get!(Message, nudge.id).resolved_by == nil
    {:ok, _} = commit(actor, daily, turn, %{answered: [step.id], busy: false})
    assert Arca.Repo.get!(Message, nudge.id).resolved_by == step.id
  end

  # ---- the silence clock -----------------------------------------------------

  test "the clock runs only while the program owes output: it pauses for a post not yet " <>
         "taken, an ask open and a result not yet answered, resumes with what was left, and a " <>
         "line of the program's own restarts it",
       %{actor: actor, daily: daily, turn: turn} do
    {:ok, %{step: post}} = carry(actor, turn, "post", opening(actor, turn))
    assert {:ok, %{due_ms: nil, expired?: false}} = TurnStorage.brain_silence(actor, daily.id)

    {:ok, _} = commit(actor, daily, turn, %{accepted: [post.id], busy: true})
    assert {:ok, %{due_ms: due}} = TurnStorage.brain_silence(actor, daily.id)
    assert due > @silence - 5_000

    backdate!(daily, 20_000)

    ask = %{
      kind: "tool",
      tool: "files",
      action: "read",
      idempotency_key: TurnStorage.brain_ask_key(turn.id, "toolu_9"),
      call: %{kind: "tool_call", content: "files", payload: %{"tool_call_id" => "toolu_9"}}
    }

    {:ok, %{asks: [asked]}} = commit(actor, daily, turn, %{asks: [ask]})
    assert {:ok, %{due_ms: nil}} = TurnStorage.brain_silence(actor, daily.id)
    left = progress(daily)["clock"]["left_ms"]
    assert left in (@silence - 25_000)..(@silence - 20_000)

    # Forty minutes on an ask's card, then its result closed but not yet
    # answered: still paused, with what was left of the interval.
    {:ok, asked} = TurnStorage.dispatch_step(actor, asked.id, %{fence: turn.fence})

    {:ok, %{result: result}} =
      TurnStorage.close_step(actor, asked.id, "ok", %{fence: turn.fence, result: %{content: "x"}})

    {:ok, _} = commit(actor, daily, turn, %{})
    assert {:ok, %{due_ms: nil}} = TurnStorage.brain_silence(actor, daily.id)

    {:ok, %{step: answer}} = carry(actor, turn, "answer", result)
    {:ok, _} = commit(actor, daily, turn, %{accepted: [answer.id], busy: true})
    assert {:ok, %{due_ms: resumed}} = TurnStorage.brain_silence(actor, daily.id)
    assert resumed <= left and resumed > left - 5_000

    {:ok, _} = commit(actor, daily, turn, %{native: true})
    assert {:ok, %{due_ms: restarted}} = TurnStorage.brain_silence(actor, daily.id)
    assert restarted > @silence - 5_000

    backdate!(daily, @silence + 1)
    assert {:ok, %{expired?: true, due_ms: 0}} = TurnStorage.brain_silence(actor, daily.id)
  end

  # The clock as if its interval began `ms` earlier.
  defp backdate!(thread, ms) do
    progress = progress(thread)
    {:ok, since, _} = DateTime.from_iso8601(progress["clock"]["since"])
    since = since |> DateTime.add(-ms, :millisecond) |> DateTime.to_iso8601()
    progress = put_in(progress, ["clock", "since"], since)

    Arca.Repo.update_all(
      from(t in Thread, where: t.id == ^thread.id),
      set: [brain_progress: Jason.encode!(progress)]
    )
  end

  # ---- recovery ----------------------------------------------------------------

  test "a turn a dead runner left is set down with its deliveries still dispatched for its " <>
         "attendant to reconcile, never read as calls whose outcome is unknown",
       %{actor: actor, turn: turn, start: start} do
    # The start closed as its attendant took the work, as the loop closes it.
    {:ok, _} = TurnStorage.close_step(actor, start.id, "ok", %{fence: turn.fence})
    {:ok, %{step: step}} = carry(actor, turn, "post", opening(actor, turn))

    assert {:ok, %{status: "paused", paused_reason: "uncertain"}} =
             TurnStorage.pause_recovered(
               actor,
               turn.id,
               Map.merge(@stored, %{content: "restarted", fence: turn.fence})
             )

    assert %TurnStep{dispatch_state: "dispatched", outcome: nil} = step(step.id)
    assert TurnStorage.restricted?(actor, turn.id) == false
  end

  test "a resumed transcript reconciles the turn's deliveries first: a held post was delivered, " <>
         "one not held is uncertain, and an answer no transcript can say is uncertain",
       %{actor: actor, daily: daily, turn: turn} do
    first = opening(actor, turn)
    second = steer!(actor, daily, turn, "second")
    {:ok, %{step: held}} = carry(actor, turn, "post", first)
    {:ok, %{step: lost}} = carry(actor, turn, "post", second)
    {:ok, _} = commit(actor, daily, turn, %{accepted: [held.id], busy: true})

    assert {:ok, ids} = TurnStorage.brain_pending(actor, turn.id)
    assert ids == [held.id, lost.id]

    assert {:ok, %{held: [%{id: held_id}], absent: [%{id: lost_id}], answers: []}} =
             TurnStorage.reconcile_brain(actor, turn.id, %{
               fence: turn.fence,
               generation: 0,
               held: [held.id]
             })

    assert {held_id, lost_id} == {held.id, lost.id}
    assert step(held.id).outcome == "ok"
    assert step(lost.id).dispatch_state == "closed" and step(lost.id).outcome == "uncertain"
    assert carried_by(second) == lost.id

    # The held post owes one prompt, and stays owed an answer until that
    # prompt's own step is recorded, which takes the obligation over.
    assert progress(daily)["owed"] == [held.id]
    assert progress(daily)["notices"] == [%{"step" => held.id}]

    assert {:ok, [%{action: "post", message_id: first_id, context?: false}]} =
             TurnStorage.brain_notices(actor, turn.id)

    assert first_id == first.id
    {:ok, %{step: notice}} = carry(actor, turn, "notice", first)
    assert progress(daily)["owed"] == [notice.id]
    assert progress(daily)["notices"] == []
    assert {:ok, []} = TurnStorage.brain_notices(actor, turn.id)
  end

  test "a restart before a held post's prompt is recorded keeps the prompt owed: the post stays " <>
         "pending and held, and is reconciled again",
       %{actor: actor, daily: daily, turn: turn} do
    {:ok, %{step: input}} = carry(actor, turn, "post", opening(actor, turn))
    {:ok, _} = commit(actor, daily, turn, %{accepted: [input.id], busy: true})
    attrs = %{fence: turn.fence, generation: 0, held: [input.id]}
    assert {:ok, %{held: [%{id: id}]}} = TurnStorage.reconcile_brain(actor, turn.id, attrs)
    assert id == input.id

    # No prompt was recorded before the next restart.
    assert {:ok, [^id]} = TurnStorage.brain_pending(actor, turn.id)
    assert {:ok, %{held: [%{id: ^id}]}} = TurnStorage.reconcile_brain(actor, turn.id, attrs)
    assert progress(daily)["notices"] == [%{"step" => id}]
  end

  test "a restart before an uncertain answer's prompt is recorded keeps the prompt owed, and " <>
         "the reconcile run again answers it again",
       %{actor: actor, daily: daily, turn: turn} do
    ask = %{
      kind: "tool",
      tool: "files",
      action: "read",
      idempotency_key: TurnStorage.brain_ask_key(turn.id, "toolu_answered"),
      call: %{kind: "tool_call", content: "files", payload: %{"tool_call_id" => "toolu_answered"}}
    }

    {:ok, %{asks: [asked]}} = commit(actor, daily, turn, %{asks: [ask]})
    {:ok, asked} = TurnStorage.dispatch_step(actor, asked.id, %{fence: turn.fence})

    {:ok, %{result: result}} =
      TurnStorage.close_step(actor, asked.id, "ok", %{
        fence: turn.fence,
        result: %{content: "effect completed"}
      })

    {:ok, %{step: answer}} = carry(actor, turn, "answer", result)
    attrs = %{fence: turn.fence, generation: 0, held: []}
    assert {:ok, %{answers: [%{id: id}]}} = TurnStorage.reconcile_brain(actor, turn.id, attrs)
    assert id == answer.id
    assert step(answer.id).outcome == "uncertain"
    assert {:ok, %{answers: [%{id: ^id}]}} = TurnStorage.reconcile_brain(actor, turn.id, attrs)

    assert {:ok, [%{action: "answer", message_id: row, context?: false}]} =
             TurnStorage.brain_notices(actor, turn.id)

    assert row == result.id
    {:ok, _notice} = carry(actor, turn, "notice", result)
    assert {:ok, []} = TurnStorage.brain_notices(actor, turn.id)
    assert {:ok, %{answers: []}} = TurnStorage.reconcile_brain(actor, turn.id, attrs)
  end

  test "a session started anew while the turn was at work owes one prompt with the thread so " <>
         "far, for the newest post it delivered, and nothing else of before",
       %{actor: actor, daily: daily, turn: turn} do
    first = opening(actor, turn)
    second = steer!(actor, daily, turn, "second")
    {:ok, %{step: taken}} = carry(actor, turn, "post", first)
    {:ok, _} = commit(actor, daily, turn, %{accepted: [taken.id], busy: true})
    {:ok, %{step: handed}} = carry(actor, turn, "post", second)
    {:ok, 1} = TurnStorage.forget_session(actor, turn.id, %{fence: turn.fence, generation: 0})

    assert {:ok, %{held: [], absent: [], answers: []}} =
             TurnStorage.reconcile_brain(actor, turn.id, %{
               fence: turn.fence,
               generation: 1,
               fresh: true
             })

    assert step(taken.id).outcome == "ok"
    assert {step(handed.id).dispatch_state, step(handed.id).outcome} == {"closed", "uncertain"}
    assert progress(daily)["owed"] == []
    assert progress(daily)["notices"] == [%{"step" => handed.id, "context" => true}]

    assert {:ok, [%{action: "post", message_id: row, context?: true}]} =
             TurnStorage.brain_notices(actor, turn.id)

    assert row == second.id
  end
end
