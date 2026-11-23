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

  # A turn of Aqua's on a program brain, accepted on `message` in `thread`
  # (a person's post unless another is given) and started with its root,
  # as the loop starts one.
  defp running!(actor, thread, message \\ nil),
    do: started!(actor, accepted!(actor, thread, message))

  defp accepted!(actor, thread, message) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, thread.id, %{
        message: message || %{author: actor.user_id, sent_by: "person", content: "go"},
        turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
      })

    turn
  end

  # An accepted turn started with its root, as the loop starts one.
  defp started!(actor, turn) do
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
        idempotency_key: TurnStorage.admission_key(turn.id),
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

  # The turn paused around a launch it handed to a person.
  defp launch_paused!(actor, turn) do
    {:ok, launch} =
      TurnStorage.put_step(actor, turn.id, %{
        kind: "launch",
        idempotency_key: "launch:1",
        fence: turn.fence
      })

    {:ok, paused} =
      TurnStorage.pause(actor, turn.id, %{
        fence: turn.fence,
        reason: "launch",
        launch_step_id: launch.id
      })

    paused
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
    {told, progress} = Map.split(attrs, [:said, :asks, :accepted, :refused, :usage])

    TurnStorage.commit_events(
      actor,
      %{thread: thread.id, agent: "aqua", turn: turn && %{id: turn.id, fence: turn.fence}},
      %{
        events:
          Enum.map(Map.get(told, :said, []), &{:text, &1}) ++
            Enum.map(Map.get(told, :asks, []), &{:ask, &1}) ++
            Enum.map(Map.get(told, :accepted, []), &{:took, &1}) ++
            Enum.map(Map.get(told, :refused, []), &{:refused, &1}) ++
            Enum.map(Map.get(told, :usage, []), &{:usage, &1}),
        position:
          {:session,
           Map.merge(
             %{
               generation: 0,
               boot: "boot-1",
               seq: System.unique_integer([:positive, :monotonic]),
               row_id: "prg_brain",
               epoch: 1,
               silence_ms: @silence
             },
             progress
           )}
      }
    )
  end

  defp finish(actor, turn, status),
    do: TurnStorage.finish(actor, turn.id, status, Map.put(@stored, :fence, turn.fence))

  defp carried_by(row), do: Arca.Repo.get!(Message, row.id).carried_by
  defp step(id), do: Arca.Repo.get!(TurnStep, id)
  defp fresh(actor, turn), do: elem(TurnStorage.get(actor, turn.id), 1)

  defp progress(thread),
    do: Jason.decode!(Arca.Repo.get!(Thread, thread.id).brain_progress || "{}")

  # A workspace thread opened from `daily`, whose reports land there.
  defp workspace!(actor, daily) do
    {:ok, %{workspace: workspace}} =
      TurnStorage.open_workspace(actor, %{
        daily_id: daily.id,
        id: Prima.UUID7.generate_id("thread"),
        title: "Moon report",
        opened_from: "msg_ask",
        opening: %{
          id: Prima.UUID7.generate_id("msg"),
          author: actor.user_id,
          content: "write the moon report",
          payload: %{"ask" => "write the moon report"}
        },
        pointer: %{author: "aqua", sent_by: "aqua", content: "Moon report", payload: %{}},
        files: fn _thread, _message -> {:ok, []} end,
        person_id: actor.user_id,
        origin: :interactive
      })

    workspace
  end

  # The workspace thread's report, as Aqua writes it on the daily thread.
  defp report(workspace, content),
    do: %{
      author: "aqua",
      sent_by: "aqua",
      kind: "report",
      workspace_id: workspace.id,
      content: content
    }

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

  test "what a session was given is the first post it took in the newest turn that took one, " <>
         "and after it only the posts it took: nothing refused, uncertain or never sent counts",
       %{actor: actor, daily: daily, turn: turn, start: start} do
    {:ok, _} = TurnStorage.close_step(actor, start.id, "ok", %{fence: turn.fence})
    assert TurnStorage.brain_given(actor, daily.id) == {:ok, %{seq: nil, taken: []}}

    opening = opening(actor, turn)
    {:ok, %{step: first}} = carry(actor, turn, "post", opening)
    # Written, not yet taken: nothing is given.
    assert TurnStorage.brain_given(actor, daily.id) == {:ok, %{seq: nil, taken: []}}
    {:ok, _} = commit(actor, daily, turn, %{accepted: [first.id]})

    [refused, unsent, lost, taken] = for n <- 1..4, do: steer!(actor, daily, turn, "#{n}")

    [refusal, _unsent, losing, taking] =
      for row <- [refused, unsent, lost, taken],
          do: elem(carry(actor, turn, "post", row), 1)

    {:ok, _} =
      commit(actor, daily, turn, %{refused: [refusal.step.id], accepted: [taking.step.id]})

    {1, _} =
      Arca.Repo.update_all(from(s in TurnStep, where: s.id == ^losing.step.id),
        set: [dispatch_state: "closed", outcome: "uncertain"]
      )

    assert TurnStorage.brain_given(actor, daily.id) ==
             {:ok, %{seq: opening.seq, taken: [taken.id]}}

    # The next turn's first post taken is where what was given now stands.
    {:ok, _} = finish(actor, turn, "failed")
    next = running!(actor, daily, %{author: actor.user_id, sent_by: "person", content: "again"})
    next_start = start!(actor, next)
    {:ok, _} = TurnStorage.close_step(actor, next_start.id, "ok", %{fence: next.fence})
    again = opening(actor, next)
    {:ok, %{step: carried}} = carry(actor, next, "post", again)

    assert TurnStorage.brain_given(actor, daily.id) ==
             {:ok, %{seq: opening.seq, taken: [taken.id]}}

    {:ok, _} = commit(actor, daily, next, %{accepted: [carried.id]})
    assert TurnStorage.brain_given(actor, daily.id) == {:ok, %{seq: again.seq, taken: []}}

    assert TurnStorage.brain_given(%{actor | athanor_id: "ath_another"}, daily.id) ==
             {:error, :thread_not_found}
  end

  test "what was given is the newest turn's first delivery taken, though an older turn's " <>
         "later steer has the greater seq",
       %{actor: actor, daily: daily, turn: turn, start: start} do
    {:ok, _} = TurnStorage.close_step(actor, start.id, "ok", %{fence: turn.fence})
    {:ok, %{step: first}} = carry(actor, turn, "post", opening(actor, turn))
    {:ok, _} = commit(actor, daily, turn, %{accepted: [first.id]})

    # Job B is queued, then job A is steered: A's steer is written after
    # B's opening.
    queued = accepted!(actor, daily, %{author: actor.user_id, sent_by: "person", content: "B"})
    more = steer!(actor, daily, turn, "more for A")
    {:ok, %{step: steered}} = carry(actor, turn, "post", more)
    {:ok, _} = commit(actor, daily, turn, %{accepted: [steered.id]})
    {:ok, _} = finish(actor, turn, "failed")

    next = started!(actor, queued)
    next_start = start!(actor, next)
    {:ok, _} = TurnStorage.close_step(actor, next_start.id, "ok", %{fence: next.fence})
    opened = opening(actor, next)
    {:ok, %{step: taken}} = carry(actor, next, "post", opened)
    {:ok, _} = commit(actor, daily, next, %{accepted: [taken.id]})

    assert opened.seq < more.seq
    assert TurnStorage.brain_given(actor, daily.id) == {:ok, %{seq: opened.seq, taken: [more.id]}}
  end

  test "a recovery prompt the program took is given as a post is, and a session forgotten " <>
         "since was given nothing",
       %{actor: actor, daily: daily, turn: turn, start: start} do
    {:ok, _} = TurnStorage.close_step(actor, start.id, "ok", %{fence: turn.fence})
    opened = opening(actor, turn)
    # The post was written and its answer lost: a recovery prompt continues it.
    {:ok, %{step: _lost}} = carry(actor, turn, "post", opened)
    {:ok, %{step: noticed}} = carry(actor, turn, "notice", opened)
    {:ok, _} = commit(actor, daily, turn, %{accepted: [noticed.id]})
    assert TurnStorage.brain_given(actor, daily.id) == {:ok, %{seq: opened.seq, taken: []}}

    assert {:ok, 1} =
             TurnStorage.forget_session(actor, turn.id, %{fence: turn.fence, generation: 0})

    assert TurnStorage.brain_given(actor, daily.id) == {:ok, %{seq: nil, taken: []}}
  end

  test "a refused post is one whose delivery closed error: none still dispatched, taken or " <>
         "uncertain, and none a model step carried",
       %{actor: actor, daily: daily, turn: turn} do
    [refused, taken, lost, waiting] =
      posts = for n <- 1..4, do: steer!(actor, daily, turn, "#{n}")

    [refusal, taking, losing, _sent] =
      for row <- posts, do: elem(carry(actor, turn, "post", row), 1)

    assert {:ok, _} =
             commit(actor, daily, turn, %{refused: [refusal.step.id], accepted: [taking.step.id]})

    {1, _} =
      Arca.Repo.update_all(from(s in TurnStep, where: s.id == ^losing.step.id),
        set: [dispatch_state: "closed", outcome: "uncertain"]
      )

    read = steer!(actor, daily, turn, "to the model")

    {:ok, model} =
      TurnStorage.put_step(actor, turn.id, %{
        kind: "model",
        idempotency_key: "model:#{read.id}",
        dispatch_state: "dispatched",
        fence: turn.fence
      })

    {1, _} =
      Arca.Repo.update_all(from(m in Message, where: m.id == ^read.id),
        set: [carried_by: model.id]
      )

    {1, _} =
      Arca.Repo.update_all(from(s in TurnStep, where: s.id == ^model.id),
        set: [dispatch_state: "closed", outcome: "error"]
      )

    ids = [refused.id, taken.id, lost.id, waiting.id, read.id]
    assert TurnStorage.refused_posts(actor, ids) == {:ok, [refused.id]}

    assert TurnStorage.refused_posts(%{actor | athanor_id: "ath_another"}, ids) == {:ok, []}
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

  test "a turn whose own program.start is still proposed is written nothing; one paused " <>
         "around a launch takes a post or an answer, never a notice",
       %{actor: actor, daily: daily, turn: first} do
    {:ok, _} = finish(actor, first, "cancelled")
    carded = running!(actor, daily)
    _start = start!(actor, carded, "proposed")
    assert {:error, :not_admitted} = carry(actor, carded, "post", opening(actor, carded))

    {:ok, _} = finish(actor, carded, "cancelled")
    turn = running!(actor, daily)
    _start = start!(actor, turn)
    row = opening(actor, turn)
    paused = launch_paused!(actor, turn)
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

  test "a post an input step carried reads where it arrived, among the program's own words",
       %{actor: actor, daily: daily, turn: turn} do
    first = opening(actor, turn)
    assert {:ok, _} = carry(actor, turn, "post", first)

    assert {:ok, %{said: [said]}} =
             commit(actor, daily, turn, %{
               seq: 5,
               hello: true,
               said: [%{message: "msg_native_1", text: "on it"}]
             })

    later = steer!(actor, daily, turn, "and the moon")
    assert {:ok, _} = carry(actor, turn, "post", later)

    assert {:ok, rows} = TurnStorage.projection(actor, turn.id)
    ids = [first.id, said.id, later.id]
    assert rows |> Enum.map(& &1.id) |> Enum.filter(&(&1 in ids)) == ids
  end

  test "a report Aqua wrote is its Aqua turn's post, the one that opened it and one that joined " <>
         "it, each carried once, while what the program says is never handed back to it",
       %{actor: actor, daily: daily, turn: first} do
    {:ok, _} = finish(actor, first, "cancelled")
    workspace = workspace!(actor, daily)
    turn = running!(actor, daily, report(workspace, "Done: the moon report."))
    _start = start!(actor, turn)

    assert {:ok, [opened]} = TurnStorage.brain_posts(actor, turn.id)
    assert {opened.id, opened.kind, opened.sent_by} == {turn.message_id, "report", "aqua"}
    assert {:ok, %{step: step}} = carry(actor, turn, "post", opened)
    assert {:error, :carried} = carry(actor, turn, "post", opened)
    assert carried_by(opened) == step.id
    assert {:ok, []} = TurnStorage.brain_posts(actor, turn.id)

    assert {:ok, %{said: [said]}} =
             commit(actor, daily, turn, %{
               hello: true,
               accepted: [step.id],
               said: [%{message: "msg_native_1", text: "The moon report is done."}]
             })

    assert {said.kind, said.sent_by} == {"text", "aqua"}
    assert {:error, :not_waiting} = carry(actor, turn, "post", said)
    {:ok, _} = commit(actor, daily, turn, %{answered: [step.id], busy: false})

    # The program answered everything it took; a report joins before its
    # attendant carries it, and the turn cannot complete past it.
    {:ok, %{message: joined}} =
      TurnStorage.accept_message(actor, daily.id, %{
        message: report(workspace, "Also: the tides."),
        steer_turn_id: turn.id
      })

    assert joined.turn_id == turn.id
    assert {:error, :steer_pending} = finish(actor, turn, "completed")
    assert {:ok, [%{id: waiting}]} = TurnStorage.brain_posts(actor, turn.id)
    assert waiting == joined.id
    assert {:ok, %{step: joined_step}} = carry(actor, turn, "post", joined)
    assert {:error, :carried} = carry(actor, turn, "post", joined)
    assert carried_by(joined) == joined_step.id
    assert {:ok, []} = TurnStorage.brain_posts(actor, turn.id)

    {:ok, _} =
      commit(actor, daily, turn, %{accepted: [joined_step.id], answered: [joined_step.id]})

    assert {:ok, %{status: "completed"}} = finish(actor, turn, "completed")
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

    assert %{"boot" => "boot-2", "seq" => 1, "driver" => %{"row" => "prg_brain", "epoch" => 1}} =
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

    assert {:ok, %{asks: [%{step: first}]}} =
             commit(actor, daily, turn, %{asks: [ask.("toolu_1")]})

    assert {:ok, %{asks: []}} = commit(actor, daily, turn, %{asks: [ask.("toolu_1")]})
    assert %TurnStep{purpose: "brain", dispatch_state: "proposed", tool: "files"} = step(first.id)
    assert %Message{kind: "tool_call"} = Arca.Repo.get!(Message, step(first.id).message_id)

    paused = launch_paused!(actor, turn)

    assert {:ok, %{asks: [%{step: held}]}} =
             commit(actor, daily, paused, %{asks: [ask.("toolu_2")]})

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

  test "each complete result of one work adds its counts to the work's usage, by model and " <>
         "by count, within a batch and across batches",
       %{actor: actor, daily: daily, turn: turn, start: start} do
    a = %{
      "input_tokens" => 1177,
      "output_tokens" => 19,
      "cache_read_tokens" => 649,
      "cache_write_tokens" => 3427
    }

    b = %{
      "input_tokens" => 12,
      "output_tokens" => 340,
      "cache_read_tokens" => 0,
      "cache_write_tokens" => 81
    }

    usage = fn result, models ->
      %{
        "t" => "usage",
        "gen" => 0,
        "work" => turn.id,
        "result" => result,
        "accounting" => "complete",
        "models" => models
      }
    end

    haiku = &%{"model" => "claude-haiku-5-5", "counts" => &1}
    opus = &%{"model" => "claude-opus-5-5", "counts" => &1}

    assert {:ok, _} =
             commit(actor, daily, turn, %{
               usage: [usage.("r1", [haiku.(a)]), usage.("r2", [haiku.(b), opus.(a)])]
             })

    assert {:ok, _} = commit(actor, daily, turn, %{usage: [usage.("r3", [haiku.(a)])]})

    assert Jason.decode!(step(start.id).usage) == %{
             "models" => %{
               "claude-haiku-5-5" => Map.new(a, fn {name, n} -> {name, 2 * n + b[name]} end),
               "claude-opus-5-5" => a
             },
             "results" => 3,
             "partial" => 0,
             "unknown" => 0
           }
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

  test "the clock runs whenever the program owes something, an acknowledgement among it " <>
         "with a post waiting behind, and pauses while CYFR owes it",
       %{actor: actor, daily: daily, turn: turn} do
    opened = opening(actor, turn)
    behind = steer!(actor, daily, turn, "waits behind it")
    {:ok, %{step: post}} = carry(actor, turn, "post", opened)

    assert {:ok, %{due_ms: unacknowledged, expired?: false}} =
             TurnStorage.brain_silence(actor, daily.id)

    assert is_integer(unacknowledged)

    {:ok, %{step: second}} = carry(actor, turn, "post", behind)
    {:ok, _} = commit(actor, daily, turn, %{accepted: [post.id, second.id], busy: true})
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

    {:ok, %{asks: [%{step: asked}]}} = commit(actor, daily, turn, %{asks: [ask]})
    assert {:ok, %{due_ms: nil}} = TurnStorage.brain_silence(actor, daily.id)
    left = progress(daily)["clock"]["left_ms"]
    assert left in (@silence - 25_000)..(@silence - 20_000)

    # The ask dispatched and run, then its result closed but not yet
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

  test "there is no clock without a turn: a batch with none stops one that ran, and a turn " <>
         "that ends answered leaves none running",
       %{actor: actor, daily: daily, turn: turn} do
    {:ok, %{step: post}} = carry(actor, turn, "post", opening(actor, turn))
    {:ok, _} = commit(actor, daily, turn, %{accepted: [post.id], busy: true})
    assert {:ok, %{due_ms: due}} = TurnStorage.brain_silence(actor, daily.id)
    assert is_integer(due)

    assert {:ok, %{status: "failed"}} = finish(actor, turn, "failed")
    {:ok, _} = commit(actor, daily, nil, %{native: true})
    assert {:ok, %{due_ms: nil, expired?: false}} = TurnStorage.brain_silence(actor, daily.id)

    next = running!(actor, daily)
    _start = start!(actor, next)
    {:ok, _} = commit(actor, daily, next, %{hello: true, boot: "boot-2"})
    {:ok, %{step: answered}} = carry(actor, next, "post", opening(actor, next))
    {:ok, _} = commit(actor, daily, next, %{boot: "boot-2", accepted: [answered.id], busy: true})

    {:ok, _} =
      commit(actor, daily, next, %{boot: "boot-2", answered: [answered.id], busy: false})

    assert {:ok, %{status: "completed"}} = finish(actor, next, "completed")
    assert {:ok, %{due_ms: nil, expired?: false}} = TurnStorage.brain_silence(actor, daily.id)
  end

  test "a process's hello starts a whole interval: what the last turn's program spent is not " <>
         "taken from the next turn's",
       %{actor: actor, daily: daily, turn: turn} do
    {:ok, %{step: first}} = carry(actor, turn, "post", opening(actor, turn))
    {:ok, _} = commit(actor, daily, turn, %{accepted: [first.id], busy: true})
    backdate!(daily, @silence + 1)
    {:ok, _} = commit(actor, daily, turn, %{answered: [first.id], busy: false})
    {:ok, _} = finish(actor, turn, "completed")

    next = running!(actor, daily)
    _start = start!(actor, next)
    {:ok, _} = commit(actor, daily, next, %{hello: true, boot: "boot-2"})
    assert {:ok, %{expired?: false, due_ms: nil}} = TurnStorage.brain_silence(actor, daily.id)

    {:ok, %{step: post}} = carry(actor, next, "post", opening(actor, next))
    {:ok, _} = commit(actor, daily, next, %{boot: "boot-2", accepted: [post.id], busy: true})

    assert {:ok, %{expired?: false, due_ms: due}} = TurnStorage.brain_silence(actor, daily.id)
    assert is_integer(due) and due > @silence - 5_000
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

    # The held post owes one prompt, and stays owed an answer until the
    # driver takes that prompt, which takes the obligation over; recorded,
    # the prompt is offered no second time. The lost post stays owed until
    # the turn it ends is over.
    assert progress(daily)["owed"] == [held.id, lost.id]
    assert progress(daily)["notices"] == [%{"step" => held.id}]

    assert {:ok, [%{action: "post", message_id: first_id, context?: false}]} =
             TurnStorage.brain_notices(actor, turn.id)

    assert first_id == first.id
    {:ok, %{step: notice}} = carry(actor, turn, "notice", first)
    assert progress(daily)["owed"] == [held.id, lost.id, notice.id]
    assert progress(daily)["notices"] == [%{"step" => held.id}]
    assert {:ok, []} = TurnStorage.brain_notices(actor, turn.id)
    {:ok, _} = commit(actor, daily, turn, %{accepted: [notice.id], busy: true})
    assert progress(daily)["owed"] == [lost.id, notice.id]
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

    # No prompt was recorded before the next restart, nor before the one
    # after it.
    assert {:ok, [^id]} = TurnStorage.brain_pending(actor, turn.id)
    assert {:ok, %{held: [%{id: ^id}]}} = TurnStorage.reconcile_brain(actor, turn.id, attrs)
    assert {:ok, %{held: [%{id: ^id}]}} = TurnStorage.reconcile_brain(actor, turn.id, attrs)
    assert progress(daily)["notices"] == [%{"step" => id}]
  end

  test "a prompt certainly not written leaves the obligation it was to take over owed as it " <>
         "stood, and one recorded settles it at the next reconcile, written or not",
       %{actor: actor, daily: daily, turn: turn} do
    row = opening(actor, turn)
    {:ok, %{step: input}} = carry(actor, turn, "post", row)
    {:ok, _} = commit(actor, daily, turn, %{accepted: [input.id], busy: true})
    attrs = %{fence: turn.fence, generation: 0, held: [input.id]}
    {:ok, _} = TurnStorage.reconcile_brain(actor, turn.id, attrs)
    {:ok, %{step: notice}} = carry(actor, turn, "notice", row)
    assert :ok = TurnStorage.uncarry(actor, turn.id, %{fence: turn.fence, step_id: notice.id})
    assert progress(daily)["owed"] == [input.id]
    assert progress(daily)["notices"] == [%{"step" => input.id}]
    assert {:ok, [input.id]} == TurnStorage.brain_pending(actor, turn.id)
    {:ok, _} = TurnStorage.reconcile_brain(actor, turn.id, attrs)

    assert {:ok, [%{action: "post", message_id: id, context?: false}]} =
             TurnStorage.brain_notices(actor, turn.id)

    assert id == row.id

    # Recorded and never answered for, it may have been written: the next
    # reconcile settles the obligation, and no prompt follows.
    {:ok, %{step: again}} = carry(actor, turn, "notice", row)
    assert {:ok, %{absent: [%{id: absent}]}} = TurnStorage.reconcile_brain(actor, turn.id, attrs)
    assert absent == again.id
    assert progress(daily)["notices"] == []
    assert {:ok, []} = TurnStorage.brain_notices(actor, turn.id)
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

    {:ok, %{asks: [%{step: asked}]}} = commit(actor, daily, turn, %{asks: [ask]})
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

  # ---- running totals -----------------------------------------------------------

  # A Codex `usage` of native thread `thread`: its running total, the counts
  # so far across every model it ran, under the model it runs now.
  defp total(turn, model, n, thread \\ "native-thread-1") do
    %{
      "t" => "usage",
      "gen" => 0,
      "work" => turn.id,
      "total" => thread,
      "accounting" => "complete",
      "models" => [%{"model" => model, "counts" => tokens(n)}]
    }
  end

  defp tokens(n) do
    %{
      "input_tokens" => n,
      "output_tokens" => 0,
      "cache_read_tokens" => 0,
      "cache_write_tokens" => 0
    }
  end

  test "a running total is counted against its native thread's last one, whatever model each " <>
         "came under",
       %{actor: actor, daily: daily, turn: turn, start: start} do
    {:ok, _} = commit(actor, daily, turn, %{usage: [total(turn, "model-a", 100)]})
    {:ok, _} = commit(actor, daily, turn, %{usage: [total(turn, "model-b", 150)]})

    assert Jason.decode!(step(start.id).usage) == %{
             "models" => %{"model-a" => tokens(100), "model-b" => tokens(50)},
             "results" => 2,
             "partial" => 0,
             "unknown" => 0
           }
  end

  # Codex sends a thread's total again unchanged whenever its rate limits
  # update, and lowers a count only by resetting the thread's usage.
  test "a total sent again unchanged counts nothing more, and one with any count below the " <>
         "last is a reset, counted whole",
       %{actor: actor, daily: daily, turn: turn, start: start} do
    counts = fn input, output -> %{tokens(input) | "output_tokens" => output} end

    at = fn input, output ->
      %{
        total(turn, "model-a", 0)
        | "models" => [%{"model" => "model-a", "counts" => counts.(input, output)}]
      }
    end

    usage = fn input, output, results ->
      %{
        "models" => %{"model-a" => counts.(input, output)},
        "results" => results,
        "partial" => 0,
        "unknown" => 0
      }
    end

    {:ok, _} = commit(actor, daily, turn, %{usage: [at.(500, 0)]})
    {:ok, _} = commit(actor, daily, turn, %{usage: [at.(500, 0)]})
    assert Jason.decode!(step(start.id).usage) == usage.(500, 0, 2)

    {:ok, _} = commit(actor, daily, turn, %{usage: [at.(0, 0)]})
    {:ok, _} = commit(actor, daily, turn, %{usage: [at.(9, 0)]})
    assert Jason.decode!(step(start.id).usage) == usage.(509, 0, 4)

    # One count below the last, the others above it, is a reset too.
    {:ok, _} = commit(actor, daily, turn, %{usage: [at.(40, 10)]})
    {:ok, _} = commit(actor, daily, turn, %{usage: [at.(45, 3)]})
    assert Jason.decode!(step(start.id).usage) == usage.(585, 13, 6)

    assert progress(daily)["baseline"] == %{
             "total" => %{"thread" => "native-thread-1", "counts" => counts.(45, 3)}
           }
  end

  # From the first sign of a helper agent every total of Codex's session
  # says partial (`brain_wire.json`): it is still counted against the
  # thread's last one, and the step's usage says how many were partial.
  test "a partial total, as every one after a helper agent's first sign is, is counted " <>
         "against the last and says so",
       %{actor: actor, daily: daily, turn: turn, start: start} do
    partial = fn n -> %{total(turn, "model-a", n) | "accounting" => "partial"} end
    {:ok, _} = commit(actor, daily, turn, %{usage: [total(turn, "model-a", 100)]})
    {:ok, _} = commit(actor, daily, turn, %{usage: [partial.(160)]})
    {:ok, _} = commit(actor, daily, turn, %{usage: [partial.(200)]})

    assert Jason.decode!(step(start.id).usage) == %{
             "models" => %{"model-a" => tokens(200)},
             "results" => 3,
             "partial" => 2,
             "unknown" => 0
           }
  end

  test "a total with no counts is unknown and leaves the last usable total the baseline",
       %{actor: actor, daily: daily, turn: turn, start: start} do
    {:ok, _} = commit(actor, daily, turn, %{usage: [total(turn, "model-a", 100)]})

    unavailable = %{
      "t" => "usage",
      "gen" => 0,
      "work" => turn.id,
      "total" => "native-thread-1",
      "accounting" => "unavailable"
    }

    {:ok, _} = commit(actor, daily, turn, %{usage: [unavailable]})
    {:ok, _} = commit(actor, daily, turn, %{usage: [total(turn, "model-a", 150)]})

    assert Jason.decode!(step(start.id).usage) == %{
             "models" => %{"model-a" => tokens(150)},
             "results" => 3,
             "partial" => 0,
             "unknown" => 1
           }
  end

  test "another native session's total starts a baseline of its own",
       %{actor: actor, daily: daily, turn: turn, start: start} do
    {:ok, _} =
      commit(actor, daily, turn, %{session: "old-session", usage: [total(turn, "m", 100)]})

    {:ok, 1} = TurnStorage.forget_session(actor, turn.id, %{fence: turn.fence, generation: 0})
    new = Map.put(total(turn, "m", 150, "native-thread-2"), "gen", 1)
    {:ok, _} = commit(actor, daily, turn, %{generation: 1, session: "new-session", usage: [new]})

    assert Jason.decode!(step(start.id).usage) == %{
             "models" => %{"m" => tokens(250)},
             "results" => 2,
             "partial" => 0,
             "unknown" => 0
           }
  end

  # ---- the session's row ---------------------------------------------------------

  test "a new driver's hello leaves the native session with the row it was stored with",
       %{actor: actor, daily: daily, turn: turn} do
    {:ok, _} = commit(actor, daily, turn, %{session: "old-session", hello: true})

    {:ok, _} =
      commit(actor, daily, turn, %{row_id: "prg_successor", epoch: 2, boot: "boot-2", hello: true})

    assert {:ok, %{session: "old-session", progress: progress}} =
             TurnStorage.brain(actor, daily.id)

    assert {progress["row"], progress["epoch"]} == {"prg_brain", 1}
  end

  test "the session's row and epoch change only with the session it names, while each batch " <>
         "moves the owner the next is held to",
       %{actor: actor, daily: daily, turn: turn} do
    successor = %{row_id: "prg_successor", epoch: 2, boot: "boot-2"}
    {:ok, _} = commit(actor, daily, turn, %{session: "old-session", hello: true})
    {:ok, _} = commit(actor, daily, turn, Map.put(successor, :hello, true))

    assert {:ok, %{session: "old-session", progress: %{"row" => "prg_brain", "epoch" => 1}}} =
             TurnStorage.brain(actor, daily.id)

    assert {:error, :row_changed} = commit(actor, daily, turn, %{successor | epoch: 1})
    assert {:error, :superseded} = commit(actor, daily, turn, %{})
    {:ok, _} = commit(actor, daily, turn, Map.put(successor, :session, "new-session"))

    assert {:ok, %{session: "new-session", progress: %{"row" => "prg_successor", "epoch" => 2}}} =
             TurnStorage.brain(actor, daily.id)
  end

  # ---- a stop that outlives a crash ------------------------------------------------

  for held? <- [false, true] do
    test "a notice a reconcile reports stays owed until its turn is over, so a reconcile run " <>
           "again before the turn's failure lands reports it again and prompts nothing " <>
           "(the notice #{if held?, do: "held", else: "not held"})",
         %{actor: actor, daily: daily, turn: turn} do
      row = opening(actor, turn)
      {:ok, %{step: post}} = carry(actor, turn, "post", row)
      {:ok, _} = commit(actor, daily, turn, %{accepted: [post.id], busy: true})
      attrs = %{fence: turn.fence, generation: 0, held: [post.id]}
      {:ok, _} = TurnStorage.reconcile_brain(actor, turn.id, attrs)
      {:ok, %{step: notice}} = carry(actor, turn, "notice", row)
      attrs = %{attrs | held: if(unquote(held?), do: [post.id, notice.id], else: [post.id])}
      reported = if unquote(held?), do: :held, else: :absent
      {:ok, first} = TurnStorage.reconcile_brain(actor, turn.id, attrs)
      assert Enum.map(Map.fetch!(first, reported), & &1.id) == [notice.id]

      # CYFR died after that reconcile and before the turn's failure was
      # recorded: the next reconcile reports the notice again.
      {:ok, second} = TurnStorage.reconcile_brain(actor, turn.id, attrs)
      assert Enum.map(Map.fetch!(second, reported), & &1.id) == [notice.id]
      assert {second.answers, progress(daily)["owed"]} == {[], [notice.id]}
      assert {:ok, []} = TurnStorage.brain_notices(actor, turn.id)
    end
  end

  test "a post the transcript does not hold stays owed until its turn is over, so a reconcile " <>
         "run again before the turn's failure lands reports it again",
       %{actor: actor, daily: daily, turn: turn} do
    {:ok, %{step: post}} = carry(actor, turn, "post", opening(actor, turn))
    attrs = %{fence: turn.fence, generation: 0, held: []}
    assert {:ok, %{absent: [%{id: absent}]}} = TurnStorage.reconcile_brain(actor, turn.id, attrs)
    assert absent == post.id
    assert {:ok, %{absent: [%{id: ^absent}]}} = TurnStorage.reconcile_brain(actor, turn.id, attrs)
    assert progress(daily)["owed"] == [post.id]
    assert {:ok, []} = TurnStorage.brain_notices(actor, turn.id)
  end

  test "a fresh session's prompt certainly not written is owed again with the thread so far",
       %{actor: actor, daily: daily, turn: turn} do
    row = opening(actor, turn)
    {:ok, %{step: post}} = carry(actor, turn, "post", row)
    {:ok, _} = commit(actor, daily, turn, %{accepted: [post.id], busy: true})
    {:ok, 1} = TurnStorage.forget_session(actor, turn.id, %{fence: turn.fence, generation: 0})
    attrs = %{fence: turn.fence, generation: 1, fresh: true}
    {:ok, _} = TurnStorage.reconcile_brain(actor, turn.id, attrs)
    {:ok, %{step: notice}} = carry(actor, turn, "notice", row, %{generation: 1})
    assert {:ok, []} = TurnStorage.brain_notices(actor, turn.id)
    assert :ok = TurnStorage.uncarry(actor, turn.id, %{fence: turn.fence, step_id: notice.id})
    assert {:ok, [%{context?: true, message_id: id}]} = TurnStorage.brain_notices(actor, turn.id)
    assert id == row.id
  end
end
