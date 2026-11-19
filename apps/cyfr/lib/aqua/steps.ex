# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Steps do
  @moduledoc """
  What Aqua did in a thread, as a person reads it: one sentence a step,
  worded here from the operation the step called and nothing else. No
  text a model wrote enters a step: not its arguments, its results or a
  name it chose.

  This is the one table from an operation to its sentence (`sentence/2`).
  A thread's kept steps (`steps/3`, across its turns, newest first) and
  the live entries the loop announces while a call runs
  (`Cyfr.Bus.ThreadEvent`'s `:tool_activity`) are worded by it alike, so
  a step reads the same while it runs and after.

  An operation the table does not name is worded by what kind of call it
  was: a component's run, a step that shows something, or a call of a
  tool.

  A step a page in Aqua's browser called (purpose `page`,
  `Aqua.PageCalls`) is worded as the page's: "The page ran an app".

  Who is at work in a workspace thread (`at_work/2`) is read from the
  same steps, one row an agent, as it stands: no agent has a status of
  its own.
  """

  alias Sanctum.Context

  @typedoc "A step as a view reads it."
  @type step :: %{
          id: String.t(),
          turn: String.t(),
          at: DateTime.t() | nil,
          sentence: String.t(),
          status: :running | :done | :failed | :refused | :skipped
        }

  @typedoc "An agent at work in a workspace thread, as a view reads it."
  @type at_work :: %{
          agent: String.t(),
          sentence: String.t(),
          at: DateTime.t() | nil,
          status: :running | :waiting | :queued
        }

  @sentences %{
    {"files", "read"} => "Read a file",
    {"files", "write"} => "Wrote a file",
    {"files", "edit"} => "Edited a file",
    {"files", "delete"} => "Deleted a file",
    {"files", "search"} => "Searched the files",
    {"files", "grep"} => "Searched the files",
    {"files", "tree"} => "Looked through the files",
    {"files", "list"} => "Looked through the files",
    {"storage", "read"} => "Read saved data",
    {"storage", "write"} => "Saved data",
    {"storage", "delete"} => "Removed saved data",
    {"http", "read"} => "Read a page on the web",
    {"http", "links"} => "Read a page's links",
    {"http", "metadata"} => "Read a page's title",
    {"execution", "run"} => "Ran an app",
    {"crew", "ask"} => "Asked the crew for help",
    {"crew", "list"} => "Looked at who is in the crew",
    {"thread", "post"} => "Posted in the thread",
    {"thread", "search"} => "Searched past posts",
    {"thread", "events"} => "Read a thread",
    {"workspace", "open"} => "Opened a workspace thread",
    {"workspace", "report"} => "Reported back to the daily thread",
    {"workspace", "list"} => "Looked at the workspace threads",
    {"threads", "list"} => "Looked at the shared threads",
    {"threads", "read"} => "Read a shared thread",
    {"notes", "keep"} => "Kept a note",
    {"notes", "pin"} => "Wrote the about-you page",
    {"notes", "workspace"} => "Wrote this thread's notes",
    {"notes", "read"} => "Read a note",
    {"notes", "list"} => "Looked at the notes",
    {"notes", "forget"} => "Forgot a note"
  }

  # The tools whose every action reads one way, whatever the action.
  @by_tool %{
    "http" => "Sent a request on the web",
    "notes" => "Worked on the notes",
    "browser" => "Used the browser"
  }

  @doc """
  The sentence of a step that calls `action` of `tool`. A tool or an
  action the table does not name reads as a call of a tool.
  """
  @spec sentence(String.t() | nil, String.t() | nil) :: String.t()
  def sentence(tool, action) do
    Map.get(@sentences, {tool, action}) || Map.get(@by_tool, tool) || "Used a tool"
  end

  @doc """
  The sentence of a step of `purpose` that calls `action` of `tool`: a
  page's step (`"page"`) as the page's, any other as `sentence/2`.
  """
  @spec sentence(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t()
  def sentence(tool, action, purpose), do: tool |> sentence(action) |> by(purpose)

  @doc """
  The steps of `thread_id` across its turns, newest first, at most 100,
  each `%{id, turn, at, sentence, status}`. `opts`: `:limit` and
  `:before` (a step's id: the page after it), as
  `Arca.TurnStorage.thread_steps/3` takes them. A thread of another
  athanor has none.
  """
  @spec steps(Context.t(), String.t(), keyword()) :: {:ok, [step()]} | {:error, term()}
  def steps(%Context{} = ctx, thread_id, opts \\ []) when is_binary(thread_id) do
    with {:ok, rows} <- Aqua.Tape.thread_steps(ctx, thread_id, opts) do
      {:ok, Enum.map(rows, &step/1)}
    end
  end

  @doc """
  Who is at work in the workspace thread `workspace_id` now, one row an
  agent, Aqua first: each agent with an open turn there or in its crew
  thread under it, worded by the last step that turn took and when, or
  by where the turn stands while it took none; and a crew member a
  request there asked whose delivery has opened no turn yet. A turn that ended is no
  current work, and a turn of a page's call is no agent's (it never
  speaks for its thread, `Arca.TurnStorage`'s "Workspace threads").
  Nothing is stored: the rows are read as they stand.
  """
  @spec at_work(Context.t(), String.t()) :: {:ok, [at_work()]} | {:error, term()}
  def at_work(%Context{} = ctx, workspace_id) when is_binary(workspace_id) do
    actor = Context.actor(ctx)

    with children when is_list(children) <- Arca.ThreadStorage.children(actor, workspace_id),
         {:ok, turns} <- open_turns(ctx, [workspace_id | Enum.map(children, & &1.id)]),
         asked when is_list(asked) <-
           Arca.ThreadStorage.pending_requests(actor,
             thread_id: workspace_id,
             unstarted: true
           ),
         {:ok, working} <- working(ctx, Enum.reject(turns, &page_call?(ctx, &1))) do
      busy = MapSet.new(working, & &1.agent)

      waiting =
        for request <- Enum.uniq_by(asked, & &1.addressee),
            not MapSet.member?(busy, request.addressee),
            do: %{
              agent: request.addressee,
              sentence: "Asked, not started yet",
              at: request.inserted_at,
              status: :queued
            }

      {:ok, Enum.sort_by(working ++ waiting, &{not Prima.AgentRef.soul?(&1.agent), &1.agent})}
    end
  end

  defp open_turns(ctx, thread_ids) do
    Enum.reduce_while(thread_ids, {:ok, []}, fn id, {:ok, acc} ->
      case Aqua.Tape.open_turns(ctx, id) do
        {:ok, turns} -> {:cont, {:ok, acc ++ turns}}
        {:error, _} = refused -> {:halt, refused}
      end
    end)
  end

  defp page_call?(ctx, %{message_id: id}) when is_binary(id),
    do: match?({:ok, %{kind: "page_call"}}, Aqua.Tape.message(ctx, id))

  defp page_call?(_ctx, _turn), do: false

  # Each agent's current turn, the one running or paused, else the first
  # queued, read by the last step it took.
  defp working(ctx, turns) do
    turns
    |> Enum.group_by(& &1.agent)
    |> Enum.reduce_while({:ok, []}, fn {agent, own}, {:ok, acc} ->
      turn = Enum.find(own, &(&1.status in ["running", "paused"])) || hd(own)

      case Aqua.Tape.steps(ctx, turn) do
        {:ok, steps} -> {:cont, {:ok, [row(agent, turn, last_step(steps)) | acc]}}
        {:error, _} = refused -> {:halt, refused}
      end
    end)
  end

  # A model step is thinking and an `input` step a delivery to a program
  # brain: neither is a step of the turn's work.
  defp last_step(steps) do
    steps
    |> Enum.reject(&(&1.kind in ["model", "input"]))
    |> Enum.max_by(& &1.seq, fn -> nil end)
  end

  defp row(agent, %{status: "accepted"} = turn, nil),
    do: %{agent: agent, sentence: "Waiting to start", at: turn.accepted_at, status: :queued}

  defp row(agent, %{status: "paused"} = turn, nil),
    do: %{
      agent: agent,
      sentence: "Waiting",
      at: turn.paused_at || turn.accepted_at,
      status: :waiting
    }

  defp row(agent, turn, nil),
    do: %{agent: agent, sentence: "Thinking", at: turn.accepted_at, status: :running}

  defp row(agent, _turn, step) do
    %{sentence: sentence, at: at} = step(step)
    %{agent: agent, sentence: sentence, at: at, status: :running}
  end

  defp step(row) do
    %{
      id: row.id,
      turn: row.turn_id,
      at: row.started_at || row.ended_at,
      sentence: row |> worded() |> by(row.purpose),
      status: status(row)
    }
  end

  defp worded(%{kind: "launch"}), do: sentence("execution", "run")
  defp worded(%{kind: "ui"}), do: "Showed something on the screen"
  defp worded(%{tool: tool, action: action}), do: sentence(tool, action)

  # Every sentence opens on its verb, which follows the page's name.
  defp by(<<first::utf8, rest::binary>>, "page"),
    do: "The page " <> String.downcase(<<first::utf8>>) <> rest

  defp by(sentence, _purpose), do: sentence

  defp status(%{outcome: nil}), do: :running
  defp status(%{outcome: "ok"}), do: :done
  defp status(%{outcome: "denied"}), do: :refused
  defp status(%{outcome: outcome}) when outcome in ["skipped", "cancelled"], do: :skipped
  defp status(%{outcome: _failed}), do: :failed
end
