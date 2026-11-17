# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.NudgeStorageTest do
  @moduledoc """
  The nudge of a quiet workspace thread and the server's post of one
  that waits on its person, at their owner: each decided afresh under the
  thread's lock from the rows and the database's clock, each write placed
  before and after the one it races. Quiet periods are made by moving the
  rows' stamps back, never by waiting.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{Approval, Message, Thread, Turn, TurnStep}
  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage

  @grant %{grant: :stored, verify: &Arca.Test.Actor.admits/1}
  @quiet 15 * 60

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Test.Actor.athanor!()
    actor = Arca.Test.Actor.local()
    {:ok, daily} = Arca.Test.Days.thread(actor)
    {:ok, claim} = Arca.JobClaims.claim("aqua_nudge", actor.athanor_id, "boot_test", 60_000)
    {:ok, slot} = Arca.ControlPlane.member_slot()
    {:ok, actor: actor, daily: daily, held: %{claim: claim, slot: slot}}
  end

  # ---- fixtures ------------------------------------------------------------

  defp open!(actor, daily) do
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

  # A workspace thread whose opening's turn ended with nothing said of its
  # work: it reads working with nothing running, the thread a nudge is for.
  defp at_rest!(actor, daily) do
    workspace = open!(actor, daily)
    [opening] = Threads.messages(actor, workspace.id)

    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, workspace.id, %{
        message: %{author: actor.user_id, sent_by: "person", content: opening.content},
        opening_id: opening.id,
        turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
      })

    cancel!(actor, turn)
    workspace
  end

  # A turn of Aqua's accepted on a person's post in `thread`, started.
  defp running!(actor, thread) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: actor.user_id, sent_by: "person", content: "go"},
        turn: %{agent: thread.agent || "aqua", requested_by: actor.user_id, origin: :interactive}
      })

    start!(actor, turn)
  end

  # An accepted turn started with its root, as the loop starts one.
  defp start!(actor, turn) do
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

    started
  end

  defp cancel!(actor, turn) do
    {:ok, _} =
      TurnStorage.finish(actor, turn.id, "cancelled", Map.merge(@grant, %{fence: turn.fence}))
  end

  # A model step of `turn`, as a round opens one: it carries what the turn
  # has read by then.
  defp model_step!(actor, turn, key) do
    {:ok, step} =
      TurnStorage.put_step(actor, turn.id, %{
        kind: "model",
        purpose: "chat",
        idempotency_key: "model:#{key}",
        fence: turn.fence
      })

    step
  end

  # The model's answer, which closes its step.
  defp answered!(actor, turn, step) do
    {:ok, _} =
      TurnStorage.record_response(actor, turn.id, step.id, %{
        fence: turn.fence,
        text: "Still waiting on the build.",
        usage: %{},
        stop_reason: "end_turn",
        tool_calls: []
      })
  end

  # A card in `turn`, as the loop opens one.
  defp card!(actor, turn, key) do
    model = model_step!(actor, turn, key)

    {:ok, %{calls: [%{step: call}]}} =
      TurnStorage.record_response(actor, turn.id, model.id, %{
        fence: turn.fence,
        text: nil,
        usage: %{},
        stop_reason: "tool_call",
        tool_calls: [
          %{
            tool_call_id: key,
            name: "notes",
            tool: "notes",
            action: "keep",
            arguments: %{},
            kind: "write",
            idempotency_key: "call:#{key}",
            proposal_digest: "sha256:#{key}"
          }
        ]
      })

    {:ok, %{approval: approval}} =
      TurnStorage.open_approval(actor, call.id, %{
        proposal_digest: "sha256:#{key}",
        card: %{content: "Keep the note?"},
        fence: turn.fence
      })

    approval
  end

  defp decline!(actor, turn, approval) do
    {:ok, _} =
      TurnStorage.resolve_approval(actor, approval.id, "declined", %{
        fence: turn.fence,
        decided_by: actor.user_id,
        resolution_kind: Prima.TurnState.resolution_kind("declined", "tool"),
        denied_result: %{content: "declined", payload: %{}}
      })
  end

  defp stop!(actor, workspace),
    do: TurnStorage.stop_work(actor, workspace.id, Map.put(@grant, :error, "stopped"))

  # Everything the athanor's rows say happened, moved back past the quiet
  # period: the period passes without a wait.
  defp aged!(actor) do
    past = DateTime.add(DateTime.utc_now(), -(@quiet + 60), :second)

    for {schema, fields} <- [
          {Message, [:inserted_at]},
          {Turn, [:accepted_at, :ended_at]},
          {TurnStep, [:started_at, :ended_at]},
          {Approval, [:inserted_at, :decided_at]}
        ],
        field <- fields do
      from(r in schema,
        where: r.athanor_id == ^actor.athanor_id and not is_nil(field(r, ^field))
      )
      |> Arca.Repo.update_all(set: [{field, past}])
    end

    :ok
  end

  # The nudge as the tick sends it, bound to the work the thread's view
  # names as it is sent, unless `extra` binds it to other work.
  defp nudge(actor, workspace, held, extra \\ %{}) do
    TurnStorage.nudge(
      actor,
      workspace.id,
      Map.merge(
        %{
          message: %{content: "Say where it stands."},
          turn: %{
            agent: "aqua",
            requested_by: actor.user_id,
            origin: :interactive,
            options: %{"agent" => "aqua"}
          },
          work: bound(actor, workspace),
          quiet: @quiet
        },
        Map.merge(held, extra)
      )
    )
  end

  defp bound(actor, workspace) do
    {:ok, %{work: work}} = TurnStorage.nudge_view(actor, workspace.id, @quiet)
    work && work.id
  end

  # A further opening of the workspace thread from the daily thread, under
  # the schedule's narrower origin and tools, not yet delivered.
  defp further_opening!(actor, daily, workspace) do
    TurnStorage.open_workspace(actor, %{
      daily_id: daily.id,
      workspace_id: workspace.id,
      title: "Moon report",
      opened_from: "msg_again",
      opening: %{
        id: Prima.UUID7.generate_id("msg"),
        author: actor.user_id,
        content: "do the next task",
        payload: %{"ask" => "do the next task", "tools" => ["thread"]}
      },
      pointer: %{author: "aqua", sent_by: "aqua", content: "Moon report", payload: %{}},
      files: fn _thread, _message -> {:ok, []} end,
      person_id: actor.user_id,
      origin: :schedule
    })
  end

  # The further opening, landed and waiting for its own turn.
  defp waiting_opening!(actor, daily, workspace) do
    {:ok, _} = further_opening!(actor, daily, workspace)

    %{turn_id: nil, status: nil} =
      Enum.find(
        Threads.messages(actor, workspace.id),
        &(&1.kind == "opening" and &1.content == "do the next task")
      )
  end

  defp thread(actor, id), do: elem(Threads.get(actor, id), 1)

  defp nudges(actor, thread_id),
    do: Enum.filter(Threads.messages(actor, thread_id), &(&1.kind == "nudge"))

  # ---- the nudge -----------------------------------------------------------

  describe "the nudge" do
    test "a quiet workspace thread with nothing running gets one, which opens a turn of its Aqua; the row is the server's, no post, and reopens nothing",
         %{actor: actor, daily: daily, held: held} do
      workspace = at_rest!(actor, daily)
      before = thread(actor, workspace.id)
      {:ok, unread} = Threads.unread(actor, before)

      # Fresh activity: not quiet, nothing written.
      assert {:error, :not_quiet} = nudge(actor, workspace, held)
      assert nudges(actor, workspace.id) == []

      :ok = aged!(actor)

      assert {:ok, %{joined: false, turn: turn, message: row}} = nudge(actor, workspace, held)

      assert %{kind: "nudge", sent_by: "system", author: "system", turn_id: turn_id} = row
      assert turn_id == turn.id
      assert %{status: "accepted", sent_by: "system", agent: "aqua", origin: "interactive"} = turn
      refute Threads.post?(row)

      after_it = thread(actor, workspace.id)
      assert after_it.workspace_state == "open"
      assert after_it.workspace_outcome == nil
      assert Threads.unread(actor, after_it) == {:ok, unread}

      # Its turn is the thread's work, and no second nudge comes while it
      # is unanswered, however quiet the thread is.
      :ok = aged!(actor)
      assert {:error, :unanswered} = nudge(actor, workspace, held)
      assert length(nudges(actor, workspace.id)) == 1
    end

    test "a nudge is answered by the model round that carried it, not by one that opened before it",
         %{actor: actor, daily: daily, held: held} do
      workspace = at_rest!(actor, daily)
      turn = running!(actor, workspace)

      # A round opens before the nudge lands, and its answer comes after.
      before = model_step!(actor, turn, "before")
      :ok = aged!(actor)
      assert {:ok, %{joined: true, turn: nil, message: row}} = nudge(actor, workspace, held)
      assert row.turn_id == turn.id

      answered!(actor, turn, before)
      :ok = aged!(actor)
      assert {:error, :unanswered} = nudge(actor, workspace, held)

      # A round whose drain ran before the row landed opens its step after
      # it: its request does not carry the row, so it answers nothing.
      raced = model_step!(actor, turn, "raced")
      assert thread_row(row).resolved_by == nil
      answered!(actor, turn, raced)
      :ok = aged!(actor)
      assert {:error, :unanswered} = nudge(actor, workspace, held)

      # The next round drains it and carries it; until that round's answer
      # lands it is still being answered.
      {:ok, drained} = TurnStorage.drain_steer(actor, turn.id, %{fence: turn.fence})
      assert Enum.map(drained, & &1.id) == [row.id]
      carrying = model_step!(actor, turn, "carrying")
      assert thread_row(row).resolved_by == carrying.id
      :ok = aged!(actor)
      assert {:error, :unanswered} = nudge(actor, workspace, held)

      answered!(actor, turn, carrying)
      :ok = aged!(actor)
      assert {:ok, %{joined: true}} = nudge(actor, workspace, held)
    end

    test "a nudge whose turn ended unanswered is retired: a stop refuses the nudge, and the stopped one never blocks the next",
         %{actor: actor, daily: daily, held: held} do
      workspace = at_rest!(actor, daily)
      :ok = aged!(actor)
      {:ok, %{turn: stopped}} = nudge(actor, workspace, held)

      assert {:ok, %{cancelled: [_]}} = stop!(actor, workspace)
      :ok = aged!(actor)
      assert {:error, {:workspace_state, "stopped"}} = nudge(actor, workspace, held)

      # New work makes it working again and goes quiet.
      posted = running!(actor, workspace)
      cancel!(actor, posted)
      assert thread(actor, workspace.id).workspace_state == "open"
      :ok = aged!(actor)

      assert {:ok, %{turn: turn}} = nudge(actor, workspace, held)
      assert turn.id != stopped.id
      assert {:ok, %{status: "cancelled"}} = TurnStorage.get(actor, stopped.id)
    end

    test "the thread's activity, its crew threads' included, keeps it from quiet; a page's rows, a read mark and a nudge are none",
         %{actor: actor, daily: daily, held: held} do
      workspace = at_rest!(actor, daily)
      {:ok, child} = Threads.crew_thread(actor, workspace.id, "planner")

      activity = [
        post: fn ->
          {:ok, _} =
            Threads.append(actor, workspace.id, %{
              author: "aqua",
              sent_by: "aqua",
              content: "Waiting on the build."
            })
        end,
        crew_post: fn ->
          {:ok, _} =
            Threads.append(actor, child.id, %{
              author: "aqua",
              sent_by: "planner",
              content: "on it"
            })
        end,
        crew_turn: fn -> cancel!(actor, running!(actor, child)) end
      ]

      for {what, act} <- activity do
        :ok = aged!(actor)
        act.()
        assert {:error, :not_quiet} = nudge(actor, workspace, held), "#{what} is activity"
      end

      :ok = aged!(actor)

      {:ok, _} =
        Threads.append(actor, workspace.id, %{
          author: "aqua",
          sent_by: "aqua",
          kind: "page_call",
          content: "{}"
        })

      {:ok, _} = Threads.mark_read(actor, workspace.id, 1_000)
      assert {:ok, _} = nudge(actor, workspace, held)
    end

    test "a step starting and a card decided are activity; a card waiting is the person's, not the thread's quiet",
         %{actor: actor, daily: daily, held: held} do
      workspace = at_rest!(actor, daily)
      turn = running!(actor, workspace)
      card = card!(actor, turn, "k1")
      :ok = aged!(actor)
      assert {:error, {:workspace_state, "needs_you"}} = nudge(actor, workspace, held)

      decline!(actor, turn, card)
      assert {:error, :not_quiet} = nudge(actor, workspace, held)

      :ok = aged!(actor)
      step = model_step!(actor, turn, "k2")
      {:ok, _} = TurnStorage.dispatch_step(actor, step.id, %{fence: turn.fence})
      assert {:error, :not_quiet} = nudge(actor, workspace, held)
    end

    test "a nudge joins only Aqua's turn that holds the thread; a turn queued and not started leaves it to the next tick",
         %{actor: actor, daily: daily, held: held} do
      workspace = at_rest!(actor, daily)

      {:ok, %{turn: queued}} =
        TurnStorage.accept_message(actor, workspace.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "and this"},
          turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
        })

      idle = at_rest!(actor, daily)
      :ok = aged!(actor)
      assert {:error, :busy} = nudge(actor, workspace, held)

      # Joining alone, as a member that does not hold the thread asks: with
      # nothing to join it opens nothing.
      assert {:error, :nothing_to_join} = nudge(actor, idle, held, %{join_only: true})
      assert nudges(actor, idle.id) == []

      start!(actor, queued)
      :ok = aged!(actor)
      assert {:ok, %{joined: true}} = nudge(actor, workspace, held, %{join_only: true})
    end

    test "a turn queued behind the one that holds the thread never keeps the nudge from it",
         %{actor: actor, daily: daily, held: held} do
      workspace = at_rest!(actor, daily)
      active = running!(actor, workspace)

      {:ok, %{turn: queued}} =
        TurnStorage.accept_message(actor, workspace.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "next task"},
          turn: %{agent: "aqua", requested_by: actor.user_id, origin: :schedule}
        })

      assert queued.status == "accepted"
      assert thread(actor, workspace.id).active_turn_id == active.id
      :ok = aged!(actor)

      assert {:ok, %{joined: true, message: %{turn_id: joined}}} =
               nudge(actor, workspace, held, %{join_only: true})

      assert joined == active.id
    end

    test "an opening not yet delivered never keeps the nudge from the turn that holds the thread",
         %{actor: actor, daily: daily, held: held} do
      workspace = at_rest!(actor, daily)
      active = running!(actor, workspace)
      assert {:ok, _} = further_opening!(actor, daily, workspace)
      :ok = aged!(actor)

      assert {:ok, %{due?: true, work: %{id: work}}} =
               TurnStorage.nudge_view(actor, workspace.id, @quiet)

      assert work == active.id
      assert thread(actor, workspace.id).active_turn_id == active.id
      assert {:ok, %{joined: true, message: %{turn_id: ^work}}} = nudge(actor, workspace, held)
    end

    test "an opening still waiting for its own turn stays out of what the turn a nudge joined reads",
         %{actor: actor, daily: daily, held: held} do
      workspace = at_rest!(actor, daily)
      active = running!(actor, workspace)
      assert active.origin == "interactive"
      opening = waiting_opening!(actor, daily, workspace)
      :ok = aged!(actor)

      assert {:ok, %{joined: true, message: nudged}} = nudge(actor, workspace, held)

      assert {:ok, [%{id: drained}]} =
               TurnStorage.drain_steer(actor, active.id, %{fence: active.fence})

      assert drained == nudged.id
      assert {:ok, rows} = TurnStorage.projection(actor, active.id)
      assert nudged.id in Enum.map(rows, & &1.id)
      refute opening.id in Enum.map(rows, & &1.id)
    end

    test "an opening still waiting for its own turn stays out of what a turn a person's post steered reads",
         %{actor: actor, daily: daily} do
      workspace = at_rest!(actor, daily)
      active = running!(actor, workspace)
      opening = waiting_opening!(actor, daily, workspace)

      {:ok, %{message: post}} =
        TurnStorage.accept_message(actor, workspace.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "and also this"},
          steer_turn_id: active.id
        })

      assert {:ok, [%{id: drained}]} =
               TurnStorage.drain_steer(actor, active.id, %{fence: active.fence})

      assert drained == post.id
      assert {:ok, rows} = TurnStorage.projection(actor, active.id)
      refute opening.id in Enum.map(rows, & &1.id)
    end

    test "the acceptance binds a nudge's turn only to the work the thread's lock finds",
         %{actor: actor, daily: daily, held: held} do
      # A narrower opening lands after the tick read the work, written by a
      # member whose clock is behind: it is the work now, and no nudge opens
      # a turn beside it under the older turn's authority.
      workspace = at_rest!(actor, daily)
      :ok = aged!(actor)

      assert {:ok, %{work: %{id: read, origin: "interactive"}}} =
               TurnStorage.nudge_view(actor, workspace.id, @quiet)

      assert {:ok, _} = further_opening!(actor, daily, workspace)
      :ok = aged!(actor)
      assert {:error, :busy} = nudge(actor, workspace, held, %{work: read})
      assert nudges(actor, workspace.id) == []

      # Another turn of the thread's ran and ended after the read: the
      # nudge bound to the older work lands nothing, and one bound to the
      # work as it stands lands.
      moved = at_rest!(actor, daily)
      :ok = aged!(actor)
      {:ok, %{work: %{id: before}}} = TurnStorage.nudge_view(actor, moved.id, @quiet)
      cancel!(actor, running!(actor, moved))
      :ok = aged!(actor)
      assert {:error, :work_moved} = nudge(actor, moved, held, %{work: before})
      assert nudges(actor, moved.id) == []
      assert {:ok, %{joined: false}} = nudge(actor, moved, held)
    end

    test "a turn paused around a launch is joined; one paused otherwise waits for its person, whom a timer never stands in for",
         %{actor: actor, daily: daily, held: held} do
      launching = at_rest!(actor, daily)
      turn = running!(actor, launching)

      {:ok, launch} =
        TurnStorage.put_step(actor, turn.id, %{
          kind: "launch",
          idempotency_key: "launch:1",
          fence: turn.fence
        })

      {:ok, _} =
        TurnStorage.pause(actor, turn.id, %{
          reason: "launch",
          launch_step_id: launch.id,
          fence: turn.fence
        })

      held_back = at_rest!(actor, daily)
      other = running!(actor, held_back)
      {:ok, _} = TurnStorage.pause(actor, other.id, %{reason: "approval", fence: other.fence})

      :ok = aged!(actor)
      assert {:ok, %{joined: true, message: row}} = nudge(actor, launching, held)
      assert row.turn_id == turn.id
      assert {:error, :busy} = nudge(actor, held_back, held)
      assert nudges(actor, held_back.id) == []
    end

    test "a claim lost lands nothing", %{actor: actor, daily: daily, held: held} do
      workspace = at_rest!(actor, daily)
      :ok = aged!(actor)

      # Its lease ran out: still this holder's row, and nobody's to act on.
      from(c in Arca.Schemas.JobClaim,
        where: c.kind == "aqua_nudge" and c.key == ^actor.athanor_id
      )
      |> Arca.Repo.update_all(set: [lease_until: DateTime.add(DateTime.utc_now(), -60, :second)])

      assert {:error, :lapsed} = nudge(actor, workspace, held)

      # A peer took it over.
      {:ok, _taken} =
        Arca.JobClaims.claim("aqua_nudge", actor.athanor_id, "boot_other", 60_000)

      assert {:error, :taken} = nudge(actor, workspace, held)
      assert nudges(actor, workspace.id) == []
      assert {:ok, []} = TurnStorage.open_turns(actor, workspace.id)
    end

    test "a stop and a person's post, before and after the nudge's acceptance",
         %{actor: actor, daily: daily, held: held} do
      # Before: the stop's state refuses it; the post is activity.
      stopped = at_rest!(actor, daily)

      {:ok, _} =
        TurnStorage.accept_message(actor, stopped.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "hold on"},
          turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
        })

      {:ok, _} = stop!(actor, stopped)
      :ok = aged!(actor)
      assert {:error, {:workspace_state, "stopped"}} = nudge(actor, stopped, held)

      posted = at_rest!(actor, daily)
      :ok = aged!(actor)

      {:ok, _} =
        Threads.append(actor, posted.id, %{
          author: actor.user_id,
          sent_by: "person",
          content: "any news?"
        })

      assert {:error, :not_quiet} = nudge(actor, posted, held)

      # After: the stop cancels the nudge's turn, and a post queues behind it.
      later = at_rest!(actor, daily)
      :ok = aged!(actor)
      {:ok, %{turn: turn}} = nudge(actor, later, held)

      {:ok, %{turn: behind}} =
        TurnStorage.accept_message(actor, later.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "any news?"},
          turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
        })

      assert behind.id != turn.id
      assert {:ok, %{cancelled: cancelled}} = stop!(actor, later)
      assert Enum.sort(Enum.map(cancelled, & &1.turn_id)) == Enum.sort([turn.id, behind.id])
      assert thread(actor, later.id).workspace_state == "stopped"
    end

    test "a nudge's turn asks, as it starts, whether the thread read without it still works",
         %{actor: actor, daily: daily, held: held} do
      workspace = at_rest!(actor, daily)
      :ok = aged!(actor)
      {:ok, %{turn: turn}} = nudge(actor, workspace, held)
      assert {:ok, true} = TurnStorage.line_stands(actor, turn)

      # How its work ended, recorded while it waited to start: what the
      # rule reads once nothing else runs.
      from(c in Thread, where: c.id == ^workspace.id)
      |> Arca.Repo.update_all(set: [workspace_outcome: "done"])

      assert {:ok, false} = TurnStorage.line_stands(actor, turn)
      assert {:ok, true} = TurnStorage.line_stands(actor, running!(actor, daily))
    end
  end

  defp thread_row(row), do: Arca.Repo.get!(Message, row.id)

  # ---- the wait ------------------------------------------------------------

  describe "the wait a reminder names" do
    test "a move into needs you or error starts a wait; one out keeps it; an act of the person that leaves it waiting starts a new one, later than the last whatever the clock",
         %{actor: actor, daily: daily} do
      workspace = at_rest!(actor, daily)
      assert thread(actor, workspace.id).waits_since == nil

      turn = running!(actor, workspace)
      first = card!(actor, turn, "k1")
      %{workspace_state: "needs_you", waits_since: began} = thread(actor, workspace.id)
      assert %DateTime{} = began

      # A second card is no move and no act.
      {:ok, child} = Threads.crew_thread(actor, workspace.id, "planner")
      member = running!(actor, child)
      second = card!(actor, member, "k2")
      assert thread(actor, workspace.id).waits_since == began

      # Deciding one of the two is an act: a new wait.
      decline!(actor, turn, first)
      %{workspace_state: "needs_you", waits_since: again} = thread(actor, workspace.id)
      assert DateTime.compare(again, began) == :gt

      # The last one decided puts it back to work, and the wait stays.
      decline!(actor, member, second)
      assert %{workspace_state: "open", waits_since: ^again} = thread(actor, workspace.id)

      # A clock behind the last wait still starts a later one.
      ahead = DateTime.add(DateTime.utc_now(), 3600, :second)

      from(c in Thread, where: c.id == ^workspace.id)
      |> Arca.Repo.update_all(set: [waits_since: ahead])

      _third = card!(actor, turn, "k3")
      assert thread(actor, workspace.id).waits_since == DateTime.add(ahead, 1, :microsecond)
    end
  end

  # ---- the post of a wait --------------------------------------------------

  describe "the server's post of a wait" do
    defp waiting!(actor, daily) do
      workspace = at_rest!(actor, daily)
      turn = running!(actor, workspace)
      card = card!(actor, turn, "k#{System.unique_integer([:positive])}")
      {thread(actor, workspace.id), turn, card}
    end

    # A wait begun past the quiet period: its stamp moved back, as the
    # period passes without a wait.
    defp waited!(actor, daily) do
      {waiting, turn, card} = waiting!(actor, daily)
      past = DateTime.add(waiting.waits_since, -(@quiet + 60), :second)

      from(c in Thread, where: c.id == ^waiting.id)
      |> Arca.Repo.update_all(set: [waits_since: past])

      {thread(actor, waiting.id), turn, card}
    end

    # The post as the tick sends it (`Aqua.Nudge`): an ordinary post of the
    # server's on `day`, opening a turn of Aqua's under the `schedule`
    # origin unless `extra` steers it, named by its wait on that day.
    defp post(actor, day, wait, held, extra \\ %{}) do
      since = Map.get(extra, :waits_since, wait.waits_since)

      TurnStorage.accept_message(
        actor,
        day.id,
        Map.merge(
          %{
            message: %{
              author: "system",
              sent_by: "system",
              addressee: "aqua",
              content: Map.get(extra, :content, "Needs your attention: #{wait.title}"),
              workspace_id: wait.id,
              client_id: "wait:#{wait.id}:#{DateTime.to_iso8601(since)}"
            },
            turn: %{
              agent: "aqua",
              requested_by: actor.user_id,
              origin: :schedule,
              options: %{"agent" => "aqua"}
            },
            wait: %{waits_since: since, quiet: @quiet},
            claim: held
          },
          Map.drop(extra, [:waits_since, :content])
        )
      )
    end

    defp posts(actor, day),
      do:
        for(
          %{kind: "text", sent_by: "system"} = row <- Threads.messages(actor, day.id),
          do: row.id
        )

    test "lands as an ordinary post of the server's, opening a turn of Aqua's under the schedule origin; it counts as unread, keeps its wait, moves none, and is its own receipt on its day",
         %{actor: actor, daily: daily, held: held} do
      {wait, _, _} = waited!(actor, daily)
      {:ok, today} = Arca.Test.Days.thread(actor)
      {:ok, unread} = Threads.unread(actor, thread(actor, today.id))

      assert {:ok, %{message: row, turn: turn}} = post(actor, today, wait, held)

      assert %{kind: "text", author: "system", sent_by: "system", workspace_id: named} = row
      assert named == wait.id and row.turn_id == turn.id
      assert Jason.decode!(row.payload)["waits_since"] == DateTime.to_iso8601(wait.waits_since)
      assert %{status: "accepted", origin: "schedule", sent_by: "system", agent: "aqua"} = turn
      assert Jason.decode!(turn.options) == %{"agent" => "aqua"}
      assert {:ok, count} = Threads.unread(actor, thread(actor, today.id))
      assert count == unread + 1

      # The post moves no wait: the thread waits as it did, since the stamp.
      assert %{workspace_state: "needs_you", waits_since: since} = thread(actor, wait.id)
      assert since == wait.waits_since

      # The same wait on the same day is the same post, whatever its words
      # have become since.
      assert {:error, :duplicate_client_id} = post(actor, today, wait, held)

      assert {:error, :duplicate_client_id} =
               post(actor, today, wait, held, %{content: "Needs your attention: renamed"})

      assert posts(actor, today) == [row.id]

      # The next day's thread takes the wait's post again.
      {:ok, tomorrow} = Arca.Test.Days.thread(actor)
      assert {:ok, %{message: again}} = post(actor, tomorrow, wait, held)
      assert posts(actor, tomorrow) == [again.id]
    end

    test "a wait decided, moved, too young or archived, a workspace thread gone or a daily thread archived lands no post",
         %{actor: actor, daily: daily, held: held} do
      {:ok, today} = Arca.Test.Days.thread(actor)

      {decided, turn, card} = waited!(actor, daily)
      decline!(actor, turn, card)
      assert {:error, :wait_moved} = post(actor, today, decided, held)

      {young, _, _} = waiting!(actor, daily)
      assert {:error, :not_quiet} = post(actor, today, young, held)

      {moved, _, _} = waited!(actor, daily)
      earlier = DateTime.add(moved.waits_since, -1, :second)
      assert {:error, :wait_moved} = post(actor, today, moved, held, %{waits_since: earlier})

      {archived, _, _} = waited!(actor, daily)
      archive!(archived.id)
      assert {:error, :thread_archived} = post(actor, today, archived, held)
      assert thread(actor, archived.id).archived_at

      {gone, _, _} = waited!(actor, daily)
      assert {:ok, _} = Threads.delete(actor, gone.id, Map.put(@grant, :error, "deleted"))
      assert {:error, :workspace_gone} = post(actor, today, gone, held)

      {kept, _, _} = waited!(actor, daily)
      {:ok, archived_day} = Arca.Test.Days.thread(actor)
      archive!(archived_day.id)
      assert {:error, :thread_archived} = post(actor, archived_day, kept, held)

      assert posts(actor, today) == [] and posts(actor, archived_day) == []
      assert {:ok, []} = TurnStorage.open_turns(actor, today.id)
      assert {:ok, []} = TurnStorage.open_turns(actor, archived_day.id)
    end

    test "a wait decided, archived or taken out of the archive after its post leaves the post as it was, read as any post, and admits no second that day",
         %{actor: actor, daily: daily, held: held} do
      {:ok, today} = Arca.Test.Days.thread(actor)
      {wait, turn, card} = waited!(actor, daily)
      {:ok, %{message: row, turn: posting}} = post(actor, today, wait, held)

      decline!(actor, turn, card)
      archive!(wait.id)
      assert posts(actor, today) == [row.id]
      started = start!(actor, posting)
      assert {:ok, rows} = TurnStorage.projection(actor, started.id)
      assert row.id in Enum.map(rows, & &1.id)
      assert {:ok, true} = TurnStorage.line_stands(actor, started)

      # Archived and taken out again with its stamp unchanged: the same
      # wait, whose post this day already holds.
      {again, _, _} = waited!(actor, daily)
      {:ok, %{message: first}} = post(actor, today, again, held)
      archive!(again.id)

      from(c in Thread, where: c.id == ^again.id)
      |> Arca.Repo.update_all(set: [archived_at: nil])

      assert thread(actor, again.id).waits_since == again.waits_since
      assert {:error, :duplicate_client_id} = post(actor, today, again, held)
      assert posts(actor, today) == [row.id, first.id]
    end

    test "a waiting thread archived, then taken out by new work in a crew member's thread under it, keeps its wait, so the day's post stands for it and no second lands",
         %{actor: actor, daily: daily, held: held} do
      {:ok, today} = Arca.Test.Days.thread(actor)
      {wait, _, _} = waited!(actor, daily)
      {:ok, %{message: first}} = post(actor, today, wait, held)
      {:ok, child} = Threads.crew_thread(actor, wait.id, "planner")
      assert {:ok, _} = Threads.archive(actor, wait.id)
      assert {:error, :thread_archived} = post(actor, today, wait, held)

      assert {:ok, %{turn: %{}}} =
               TurnStorage.accept_message(actor, child.id, %{
                 message: %{author: actor.user_id, sent_by: "person", content: "one more thing"},
                 turn: %{agent: "planner", requested_by: actor.user_id, origin: :interactive}
               })

      assert %{archived_at: nil, workspace_state: "needs_you", waits_since: since} =
               thread(actor, wait.id)

      assert since == wait.waits_since
      assert {:error, :duplicate_client_id} = post(actor, today, wait, held)
      assert posts(actor, today) == [first.id]
    end

    test "a claim lost lands no post", %{actor: actor, daily: daily, held: held} do
      {wait, _, _} = waited!(actor, daily)
      {:ok, today} = Arca.Test.Days.thread(actor)

      # Its lease ran out: still this holder's row, and nobody's to act on.
      from(c in Arca.Schemas.JobClaim,
        where: c.kind == "aqua_nudge" and c.key == ^actor.athanor_id
      )
      |> Arca.Repo.update_all(set: [lease_until: DateTime.add(DateTime.utc_now(), -60, :second)])

      assert {:error, :lapsed} = post(actor, today, wait, held)

      # A peer took it over.
      {:ok, _taken} = Arca.JobClaims.claim("aqua_nudge", actor.athanor_id, "boot_other", 60_000)
      assert {:error, :taken} = post(actor, today, wait, held)

      assert posts(actor, today) == []
      assert {:ok, []} = TurnStorage.open_turns(actor, today.id)
    end

    test "a post steers a turn of its own sender and origin: one before the turn's finish holds it open to be answered, one after is refused for ordinary admission",
         %{actor: actor, daily: daily, held: held} do
      {one, _, _} = waited!(actor, daily)
      {two, _, _} = waited!(actor, daily)
      {three, _, _} = waited!(actor, daily)
      {:ok, today} = Arca.Test.Days.thread(actor)

      {:ok, %{turn: accepted}} = post(actor, today, one, held)
      running = start!(actor, accepted)

      assert {:ok, %{message: steered, turn: %{id: steered_turn}}} =
               post(actor, today, two, held, %{turn: nil, steer_turn_id: running.id})

      assert steered_turn == running.id and steered.turn_id == running.id

      # Before the finish: the steer waits for its answer.
      assert {:error, :steer_pending} =
               TurnStorage.finish(
                 actor,
                 running.id,
                 "completed",
                 Map.merge(@grant, %{fence: running.fence})
               )

      # After the finish: refused, for the runner to admit it as a turn of
      # its own.
      cancel!(actor, running)

      assert {:error, :turn_over} =
               post(actor, today, three, held, %{turn: nil, steer_turn_id: running.id})

      assert {:ok, %{turn: %{id: own}}} = post(actor, today, three, held)
      assert own != running.id
    end

    test "deleting a workspace thread takes its posts with it", %{
      actor: actor,
      daily: daily,
      held: held
    } do
      {wait, _, _} = waited!(actor, daily)
      {:ok, today} = Arca.Test.Days.thread(actor)
      {:ok, %{message: row}} = post(actor, today, wait, held)

      assert {:ok, _} = Threads.delete(actor, wait.id, Map.put(@grant, :error, "deleted"))
      refute row.id in Enum.map(Threads.messages(actor, today.id), & &1.id)
    end
  end

  # ---- the archive ---------------------------------------------------------

  describe "an archived thread" do
    defp archive!(id) do
      from(c in Thread, where: c.id == ^id)
      |> Arca.Repo.update_all(set: [archived_at: DateTime.utc_now()])
    end

    test "is neither a candidate nor nudged, and a nudge's turn that starts late does not stand",
         %{actor: actor, daily: daily, held: held} do
      archived = at_rest!(actor, daily)
      kept = at_rest!(actor, daily)
      :ok = aged!(actor)
      {:ok, %{turn: turn}} = nudge(actor, kept, held)

      archive!(archived.id)
      archive!(kept.id)

      assert {:error, :thread_archived} = nudge(actor, archived, held)
      assert nudges(actor, archived.id) == []
      assert {:ok, false} = TurnStorage.line_stands(actor, turn)

      {:ok, rows} = TurnStorage.nudge_candidates({actor.athanor_id, ""}, 100)
      refute Enum.any?(rows, &(&1.id in [archived.id, kept.id]))

      assert {:ok, %{archived?: true, due?: false}} =
               TurnStorage.nudge_view(actor, archived.id, @quiet)

      assert thread(actor, archived.id).archived_at
    end
  end

  # ---- the reads -----------------------------------------------------------

  test "the candidates are the cell's working and waiting workspace threads, a page at a time",
       %{actor: actor, daily: daily} do
    ids = for _ <- 1..3, do: at_rest!(actor, daily).id
    done = open!(actor, daily)

    from(c in Thread, where: c.id == ^done.id)
    |> Arca.Repo.update_all(set: [workspace_state: "done"])

    mine = fn rows -> for %{athanor_id: a, id: id} <- rows, a == actor.athanor_id, do: id end
    {:ok, first} = TurnStorage.nudge_candidates({actor.athanor_id, ""}, 2)
    last = List.last(first)
    {:ok, rest} = TurnStorage.nudge_candidates({last.athanor_id, last.id}, 2)

    assert Enum.sort(mine.(first) ++ mine.(rest)) == Enum.sort(ids)
    refute done.id in mine.(first ++ rest)
  end
end
