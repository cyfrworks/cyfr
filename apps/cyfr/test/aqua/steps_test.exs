# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.StepsTest do
  @moduledoc """
  A thread's steps as a person reads them: across its turns, newest first,
  by cursor and at most a hundred a page, each worded by the one table
  from an operation to its sentence, the live activity included, and
  never by anything a model wrote.
  """

  use ExUnit.Case, async: false

  alias Aqua.Steps
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

  test "a page holds a hundred steps at most", %{ctx: ctx, thread: thread} do
    turn = turn!(ctx, thread)
    ids = steps!(ctx, turn, for(_ <- 1..105, do: %{tool: "files", action: "read", outcome: "ok"}))

    assert {:ok, page} = Aqua.steps(ctx, thread.id, limit: 500)
    assert length(page) == 100
    assert hd(page).id == List.last(ids)

    assert {:ok, rest} = Aqua.steps(ctx, thread.id, before: List.last(page).id)
    assert length(rest) == 5
  end
end
