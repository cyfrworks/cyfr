# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.StepsTest do
  @moduledoc """
  A thread's steps as a person reads them: across its turns, newest first,
  by cursor and at most a hundred a page, each worded by the one table
  from an operation to its sentence, the live activity included, and
  never by anything a model wrote. Who is at work in a workspace thread
  is read from the same rows, one row an agent, by its current turn
  alone.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.Steps
  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage

  setup do
    Cyfr.Test.Sandbox.setup!()
    {ctx, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
    athanor = Sanctum.Test.People.athanor!(user)
    ctx = %{ctx | athanor_id: athanor.id, origin: :interactive}
    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    {:ok, ctx: ctx, thread: thread}
  end

  defp turn!(ctx, thread) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(Sanctum.Context.actor(ctx), thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "go"},
        turn: %{agent: "aqua", requested_by: ctx.user_id, origin: :interactive}
      })

    turn
  end

  # Steps as a turn's loop leaves them, in the order they were opened.
  defp steps!(ctx, turn, specs) do
    rows =
      specs
      |> Enum.with_index(1)
      |> Enum.map(fn {spec, seq} ->
        Map.merge(
          %{
            id: Prima.UUID7.generate_id("stp"),
            athanor_id: ctx.athanor_id,
            turn_id: turn.id,
            seq: seq,
            kind: "tool",
            purpose: "chat",
            dispatch_state: "dispatched",
            generation: 0,
            started_at: DateTime.utc_now(),
            tool: nil,
            action: nil,
            outcome: nil,
            approval_id: nil
          },
          spec
        )
      end)

    {_, _} = Arca.Repo.insert_all(Arca.Schemas.TurnStep, rows)
    Enum.map(rows, & &1.id)
  end

  test "one table words a step by its operation, and nothing a model wrote" do
    assert Steps.sentence("files", "write") == "Wrote a file"
    assert Steps.sentence("workspace", "open") == "Opened a workspace thread"
    assert Steps.sentence("workspace", "report") == "Reported back to the daily thread"
    assert Steps.sentence("thread", "post") == "Posted in the thread"
    assert Steps.sentence("execution", "run") == "Ran an app"
    assert Steps.sentence("http", "post") == "Sent a request on the web"
    assert Steps.sentence("server:anything", "say_hello") == "Used a tool"
    assert Steps.sentence(nil, nil) == "Used a tool"
  end

  test "a thread's steps span its turns, newest first, with their states, and no model step",
       %{ctx: ctx, thread: thread} do
    first = turn!(ctx, thread)

    [read, model] =
      steps!(ctx, first, [
        %{tool: "files", action: "read", outcome: "ok"},
        %{kind: "model", tool: "catalyst:local.claude", action: "chat", outcome: "ok"}
      ])

    second = turn!(ctx, thread)

    [denied, waiting, running, launched] =
      steps!(ctx, second, [
        %{tool: "files", action: "delete", outcome: "denied"},
        %{tool: "notes", action: "keep", approval_id: "apr_1", dispatch_state: "proposed"},
        %{tool: "http", action: "read"},
        %{kind: "launch", tool: "execution", action: "run", outcome: "error"}
      ])

    assert {:ok, steps} = Aqua.steps(ctx, thread.id)
    refute model in Enum.map(steps, & &1.id)

    assert [
             %{id: ^launched, sentence: "Ran an app", status: :failed},
             %{id: ^running, sentence: "Read a page on the web", status: :running},
             %{id: ^waiting, sentence: "Kept a note", status: :waiting},
             %{id: ^denied, sentence: "Deleted a file", status: :refused},
             %{id: ^read, sentence: "Read a file", status: :done, turn: turn_id}
           ] = steps

    assert turn_id == first.id

    # By cursor: the page after a step is the older ones.
    assert {:ok, [%{id: ^waiting}, %{id: ^denied}]} =
             Aqua.steps(ctx, thread.id, before: running, limit: 2)

    # Another athanor's reader finds none of them.
    {other, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
    other = %{other | athanor_id: Sanctum.Test.People.athanor!(user).id}
    assert {:ok, []} = Aqua.steps(other, thread.id)
  end

  test "a page's step reads as the page's, by its purpose; a model's call's as before",
       %{ctx: ctx, thread: thread} do
    turn = turn!(ctx, thread)

    [launch, listed, shown, read] =
      steps!(ctx, turn, [
        %{kind: "launch", purpose: "page", tool: "execution", action: "run", outcome: "ok"},
        %{purpose: "page", tool: "component", action: "list", outcome: "denied"},
        %{kind: "ui", purpose: "page", tool: "ui", action: "show"},
        %{tool: "files", action: "read", outcome: "ok"}
      ])

    assert {:ok,
            [
              %{id: ^read, sentence: "Read a file", status: :done},
              %{
                id: ^shown,
                sentence: "The page showed something on the screen",
                status: :running
              },
              %{id: ^listed, sentence: "The page used a tool", status: :refused},
              %{id: ^launch, sentence: "The page ran an app", status: :done}
            ]} = Aqua.steps(ctx, thread.id)

    assert Steps.sentence("notes", "keep", "page") == "The page kept a note"
    assert Steps.sentence("notes", "keep", "chat") == "Kept a note"
    assert Steps.sentence(nil, nil, "page") == "The page used a tool"
  end

  test "a program brain's start and asks are steps of its thread, and its deliveries none",
       %{ctx: ctx, thread: thread} do
    turn = turn!(ctx, thread)

    [start, _post, searched, _answer] =
      steps!(ctx, turn, [
        %{purpose: "brain", tool: "program", action: "start", outcome: "ok"},
        %{kind: "input", purpose: "brain", tool: "program", action: "post", outcome: "ok"},
        %{purpose: "brain", tool: "files", action: "search", outcome: "ok"},
        %{kind: "input", purpose: "brain", tool: "program", action: "answer"}
      ])

    assert {:ok,
            [
              %{id: ^searched, sentence: "Searched the files", status: :done},
              %{id: ^start, sentence: "Used a tool", status: :done}
            ]} = Aqua.steps(ctx, thread.id)
  end

  test "a page holds a hundred steps at most", %{ctx: ctx, thread: thread} do
    turn = turn!(ctx, thread)
    ids = steps!(ctx, turn, for(_ <- 1..105, do: %{tool: "files", action: "read", outcome: "ok"}))

    assert {:ok, page} = Aqua.steps(ctx, thread.id, limit: 500)
    assert length(page) == 100
    assert hd(page).id == List.last(ids)

    assert {:ok, rest} = Aqua.steps(ctx, thread.id, before: List.last(page).id)
    assert length(rest) == 5
  end

  # ---------------------------------------------------------------------------
  # Who is at work in a workspace thread
  # ---------------------------------------------------------------------------

  defp actor(ctx), do: Sanctum.Context.actor(ctx)

  # A workspace thread the person opened from the daily thread, its
  # opening waiting for its turn.
  defp workspace!(ctx, daily) do
    {:ok, %{workspace: workspace}} =
      TurnStorage.open_workspace(actor(ctx), %{
        daily_id: daily.id,
        id: Prima.UUID7.generate_id("thread"),
        title: "Moon report",
        opened_from: "msg_ask",
        opening: %{
          id: Prima.UUID7.generate_id("msg"),
          author: ctx.user_id,
          content: "write the moon report",
          payload: %{"ask" => "write the moon report"}
        },
        pointer: %{author: ctx.user_id, sent_by: "person", content: "Moon report", payload: %{}},
        files: fn _thread, _message -> {:ok, []} end,
        person_id: ctx.user_id,
        origin: :interactive
      })

    workspace
  end

  # The soul's turn the opening's delivery opens on it, accepted.
  defp work!(ctx, workspace) do
    [opening] =
      Enum.filter(
        Threads.messages(actor(ctx), workspace.id),
        &(&1.kind == "opening" and is_nil(&1.turn_id))
      )

    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor(ctx), workspace.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: opening.content},
        opening_id: opening.id,
        turn: %{agent: "aqua", requested_by: ctx.user_id, origin: :interactive}
      })

    turn
  end

  # A turn of `agent` in `thread`, accepted.
  defp turn!(ctx, thread, agent) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor(ctx), thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "go"},
        turn: %{agent: agent, requested_by: ctx.user_id, origin: :interactive}
      })

    turn
  end

  # A turn a page's call opens on the call's own row, as the runner opens one.
  defp page_turn!(ctx, thread) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor(ctx), thread.id, %{
        message: %{
          author: Prima.Author.agent(),
          sent_by: "aqua",
          kind: "page_call",
          content: "component.list",
          client_id: Prima.UUID7.generate_id("pgc")
        },
        turn: %{agent: "aqua", requested_by: ctx.user_id, origin: :interactive}
      })

    turn
  end

  # Where a turn stands, as its loop moves it.
  defp moved!(ctx, turn, set) do
    {1, _} = Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id), set: set)
    {:ok, moved} = Aqua.Tape.turn(ctx, turn.id)
    moved
  end

  defp ended!(ctx, turn) do
    {:ok, current} = Aqua.Tape.turn(ctx, turn.id)
    {:ok, _} = Aqua.Tape.finish(ctx, current, "cancelled", %{error: "stopped"})
  end

  # A request of the workspace thread to `member`, waiting for its answer,
  # as `crew.ask` writes it.
  defp asked!(ctx, workspace, member) do
    {:ok, %{message: row}} =
      TurnStorage.accept_message(actor(ctx), workspace.id, %{
        message: %{
          author: Prima.Author.agent(),
          sent_by: "aqua",
          addressee: member,
          status: "pending",
          content: "plan it"
        },
        request: %{
          member: member,
          task: "plan it",
          tools: nil,
          options: %{},
          person_id: ctx.user_id,
          origin: :interactive
        }
      })

    row
  end

  # The request delivered into its member's thread, which opens its turn.
  defp delivered!(ctx, workspace, request) do
    {:ok, child} = Threads.crew_thread(actor(ctx), workspace.id, request.addressee)

    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor(ctx), child.id, %{
        message: %{
          author: ctx.user_id,
          sent_by: request.sent_by,
          addressee: request.addressee,
          content: request.content,
          payload: %{"request_id" => request.id}
        },
        turn: %{agent: request.addressee, requested_by: ctx.user_id, origin: :interactive},
        reply_address: %{asking_thread_id: workspace.id, request_id: request.id}
      })

    turn
  end

  defp step_at(ctx, thread_id, step_id) do
    {:ok, steps} = Aqua.steps(ctx, thread_id)
    Enum.find(steps, &(&1.id == step_id)).at
  end

  describe "who is at work in a workspace thread" do
    test "a turn accepted with no step yet waits to start, since it was accepted",
         %{ctx: ctx, thread: daily} do
      workspace = workspace!(ctx, daily)
      turn = work!(ctx, workspace)

      assert {:ok, [%{agent: "aqua", sentence: "Waiting to start", status: :queued, at: at}]} =
               Aqua.at_work(ctx, workspace.id)

      assert at == turn.accepted_at
    end

    test "a running turn thinks until it takes a step, then reads by its last step and when, " <>
           "never a model's",
         %{ctx: ctx, thread: daily} do
      workspace = workspace!(ctx, daily)
      turn = moved!(ctx, work!(ctx, workspace), status: "running")

      assert {:ok, [%{agent: "aqua", sentence: "Thinking", status: :running, at: at}]} =
               Aqua.at_work(ctx, workspace.id)

      assert at == turn.accepted_at

      [_read, searching, _model] =
        steps!(ctx, turn, [
          %{tool: "files", action: "read", outcome: "ok"},
          %{tool: "files", action: "search", outcome: nil},
          %{kind: "model", tool: "catalyst:local.claude", action: "chat", outcome: nil}
        ])

      assert {:ok, [%{agent: "aqua", sentence: "Searched the files", status: :running, at: at}]} =
               Aqua.at_work(ctx, workspace.id)

      assert at == step_at(ctx, workspace.id, searching)
    end

    test "a turn on a program brain reads by its last step, never a delivery to its brain",
         %{ctx: ctx, thread: daily} do
      workspace = workspace!(ctx, daily)
      turn = moved!(ctx, work!(ctx, workspace), status: "running")

      [_start, searching, _post] =
        steps!(ctx, turn, [
          %{purpose: "brain", tool: "program", action: "start", outcome: "ok"},
          %{purpose: "brain", tool: "files", action: "search", outcome: nil},
          %{kind: "input", purpose: "brain", tool: "program", action: "post"}
        ])

      assert {:ok, [%{agent: "aqua", sentence: "Searched the files", status: :running, at: at}]} =
               Aqua.at_work(ctx, workspace.id)

      assert at == step_at(ctx, workspace.id, searching)
    end

    test "a paused turn waits: by where it stands with no step, by its card's step with one",
         %{ctx: ctx, thread: daily} do
      workspace = workspace!(ctx, daily)
      paused_at = DateTime.add(DateTime.utc_now(), -120, :second)
      turn = moved!(ctx, work!(ctx, workspace), status: "paused", paused_at: paused_at)

      assert {:ok, [%{agent: "aqua", sentence: "Waiting", status: :waiting, at: at}]} =
               Aqua.at_work(ctx, workspace.id)

      assert at == turn.paused_at

      [card] =
        steps!(ctx, turn, [
          %{tool: "notes", action: "keep", approval_id: "apr_1", dispatch_state: "proposed"}
        ])

      assert {:ok, [%{agent: "aqua", sentence: "Kept a note", status: :waiting, at: at}]} =
               Aqua.at_work(ctx, workspace.id)

      assert at == step_at(ctx, workspace.id, card)
    end

    test "crew members at work in their threads under it each read by their own turn, Aqua first",
         %{ctx: ctx, thread: daily} do
      workspace = workspace!(ctx, daily)
      _aqua = work!(ctx, workspace)
      {:ok, planning} = Threads.crew_thread(actor(ctx), workspace.id, "planner")
      {:ok, building} = Threads.crew_thread(actor(ctx), workspace.id, "builder")
      planner = moved!(ctx, turn!(ctx, planning, "planner"), status: "running")
      _builder = turn!(ctx, building, "builder")
      [_step] = steps!(ctx, planner, [%{tool: "http", action: "read", outcome: nil}])

      assert {:ok,
              [
                %{agent: "aqua", sentence: "Waiting to start", status: :queued},
                %{agent: "builder", sentence: "Waiting to start", status: :queued},
                %{agent: "planner", sentence: "Read a page on the web", status: :running}
              ]} = Aqua.at_work(ctx, workspace.id)

      # Another athanor's reader finds nobody at work there.
      {other, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
      other = %{other | athanor_id: Sanctum.Test.People.athanor!(user).id}
      assert {:ok, []} = Aqua.at_work(other, workspace.id)
    end

    test "a crew member asked and not yet started reads so, until its turn opens, and its " <>
           "ended turn reads as nothing at work while its answer is on its way",
         %{ctx: ctx, thread: daily} do
      workspace = workspace!(ctx, daily)
      ended!(ctx, work!(ctx, workspace))
      request = asked!(ctx, workspace, "planner")

      assert {:ok,
              [%{agent: "planner", sentence: "Asked, not started yet", status: :queued, at: at}]} =
               Aqua.at_work(ctx, workspace.id)

      assert at == request.inserted_at

      turn = delivered!(ctx, workspace, request)

      assert {:ok, [%{agent: "planner", sentence: "Waiting to start", status: :queued, at: at}]} =
               Aqua.at_work(ctx, workspace.id)

      assert at == turn.accepted_at

      # The request waits for its answer; the turn that answers it is over.
      ended!(ctx, turn)
      assert {:ok, %{status: "pending"}} = Aqua.Tape.message(ctx, request.id)
      assert {:ok, []} = Aqua.at_work(ctx, workspace.id)
    end

    test "a turn a page's call opened is nobody at work", %{ctx: ctx, thread: daily} do
      workspace = workspace!(ctx, daily)
      ended!(ctx, work!(ctx, workspace))
      _call = moved!(ctx, page_turn!(ctx, workspace), status: "running")

      assert {:ok, []} = Aqua.at_work(ctx, workspace.id)

      # Beside the soul's own turn, the row is the soul's turn's.
      turn = turn!(ctx, workspace, "aqua")

      assert {:ok, [%{agent: "aqua", sentence: "Waiting to start", status: :queued, at: at}]} =
               Aqua.at_work(ctx, workspace.id)

      assert at == turn.accepted_at
    end

    test "an agent's row goes once its turn ends, and an ended turn's step never words the next",
         %{ctx: ctx, thread: daily} do
      workspace = workspace!(ctx, daily)
      first = moved!(ctx, work!(ctx, workspace), status: "running")
      [_read] = steps!(ctx, first, [%{tool: "files", action: "read", outcome: "ok"}])
      assert {:ok, [%{sentence: "Read a file"}]} = Aqua.at_work(ctx, workspace.id)

      ended!(ctx, first)
      assert {:ok, []} = Aqua.at_work(ctx, workspace.id)

      next = turn!(ctx, workspace, "aqua")

      assert {:ok, [%{agent: "aqua", sentence: "Waiting to start", status: :queued, at: at}]} =
               Aqua.at_work(ctx, workspace.id)

      assert at == next.accepted_at
    end
  end
end
