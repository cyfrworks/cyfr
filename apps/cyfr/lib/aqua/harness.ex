# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Harness do
  @moduledoc """
  The boundary between the thread engine (`Aqua.Loop`) and what answers a
  turn: a model through a catalyst, or a program (`Aqua.Harness.Program`).
  The engine keeps the fence, the intake, the reading of rows, every
  decision and dispatch, launches, pauses, settlement and the end; a
  harness does its own job and none of the engine's.

  The engine holds a handle, a process of the harness's that lives while
  the loop holds the turn and stops when that loop returns or dies. The
  loop puts it in its holder's registration (`Aqua.Loop.holder/1`), so a
  Stop reaches it before the loop stops.

  `open/1` returns once the harness's process exists and never waits for
  the model or the program. `{:admit, call}` asks the engine to decide
  the harness's own start through the gate and open again, in the loop's
  process, with the step it admitted; a turn that goes on passes the step
  it already has. `{:end, finish}` ends the turn before it starts.

  `facts` are all the engine reads of a harness: a launch waits while
  `child_of_root?` holds and the harness works, and a post that arrives
  skips the calls not yet started when `supersedes?` holds. They belong to
  the harness the turn pins, so they are known before `open/1`
  (`facts/1`), and the engine reads no fact it was not given.

  `moved/1` says only that the turn's rows moved, once for each time the
  loop is woken: what the harness is owed, a closed ask's result before a
  post that waits, is what the rows say, read by the harness in one view
  of them, each item once by its row's id. A provider's call id repeats
  across rounds and is never an identity, and the rows are the truth, so
  a restart reads them again. A harness that owes nothing once it read
  them and is idle has done its work.
  What the harness says reaches the loop after its commit
  (`Aqua.Tape.commit_events/3`), as `{Aqua.Harness, turn_id, event}`.
  A harness passes a reason, never a sentence: the engine writes the
  sentence once (`Prima.Refusal`).
  """

  require Prima.TestSeam

  alias Aqua.Loop.Turn

  @typedoc "The process of the turn's harness, which the loop holds."
  @type handle :: pid()

  @typedoc "All the engine reads of a harness."
  @type facts :: %{child_of_root?: boolean(), supersedes?: boolean()}

  @typedoc """
  What the engine hands a harness of the turn: its contexts, the turn as
  the loop holds it (the fence the loop acquired), the step that admitted
  the harness's start or nil before it, the member's title and what the
  work runs with, and `history`, the turn's rows a predicate keeps with the
  rows handed over beside them, joined to the turn in one join and with
  their reading (`Aqua.Reader.join/5`).
  """
  @type work :: %{
          required(:ctx) => Sanctum.Context.t(),
          required(:guest) => Sanctum.Context.t(),
          required(:turn) => map(),
          required(:admitted) => map() | nil,
          required(:history) => ((map() -> boolean()), [map()] -> {:ok, map()} | {:error, term()}),
          optional(atom()) => term()
        }

  @typedoc """
  How a turn's work ended: done; refused, turned away by CYFR or by the
  harness's own end; or lost, gone short of its end. The reason has a row
  in `Prima.Refusal`.
  """
  @type finish :: :done | {:refused, reason :: term()} | {:lost, reason :: term()}

  @typedoc """
  What a harness tells the loop after its commit: the admitted start taken,
  with whether a new native session took it; a text row; asks recorded as
  proposed steps; usage counted; an entry of what runs; its end.
  """
  @type event ::
          {:took, [{String.t(), :started | :went_on}]}
          | {:text, map()}
          | {:ask, [map()]}
          | {:usage, [map()]}
          | {:activity, {:own, String.t(), String.t()} | :idle | :session_ended}
          | {:end, finish()}

  @callback open(work()) :: {:ok, handle(), facts()} | {:admit, map()} | {:end, finish()}
  @callback moved(handle()) :: :ok
  @callback stop(handle()) :: :ok
  @callback facts() :: facts()

  @doc """
  The harness of a turn, the one place that picks it from the turn's pin:
  a program row's turn is the program's; nil for a turn whose rounds the
  loop still makes itself. A test build may stand a harness of its own in
  for the program's (`Prima.TestSeam.value/2`), to show that the engine
  holds for a harness it does not know.
  """
  @spec of(Turn.t()) :: module() | nil
  def of(%Turn{program: %{}}) do
    Prima.TestSeam.value(Aqua.Harness.Program, fn ->
      Application.get_env(:cyfr, :program_harness, Aqua.Harness.Program)
    end)
  end

  def of(%Turn{}), do: nil

  @doc """
  The facts of the turn's harness, from its pin, before anything is
  opened. A turn whose rounds the loop still makes itself answers a
  model's: its call is the root's child, and a newer post supersedes it.
  """
  @spec facts(Turn.t()) :: facts()
  def facts(%Turn{} = spec) do
    case of(spec) do
      nil -> %{child_of_root?: true, supersedes?: true}
      module -> module.facts()
    end
  end
end
