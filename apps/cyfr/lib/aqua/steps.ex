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
  was: a component's run, a step that shows something, a card's decision,
  or a call of a tool.
  """

  alias Sanctum.Context

  @typedoc "A step as a view reads it."
  @type step :: %{
          id: String.t(),
          turn: String.t(),
          at: DateTime.t() | nil,
          sentence: String.t(),
          status: :running | :done | :failed | :refused | :skipped | :waiting
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

  defp step(row) do
    %{
      id: row.id,
      turn: row.turn_id,
      at: row.started_at || row.ended_at,
      sentence: worded(row),
      status: status(row)
    }
  end

  defp worded(%{kind: "launch"}), do: sentence("execution", "run")
  defp worded(%{kind: "ui"}), do: "Showed something on the screen"
  defp worded(%{kind: "approval"}), do: "Asked you to decide"
  defp worded(%{tool: tool, action: action}), do: sentence(tool, action)

  defp status(%{approval_id: id, dispatch_state: "proposed", outcome: nil}) when is_binary(id),
    do: :waiting

  defp status(%{outcome: nil}), do: :running
  defp status(%{outcome: "ok"}), do: :done
  defp status(%{outcome: "denied"}), do: :refused
  defp status(%{outcome: outcome}) when outcome in ["skipped", "cancelled"], do: :skipped
  defp status(%{outcome: _failed}), do: :failed
end
