# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.StepSpans do
  @moduledoc """
  The latency of one child run through `Cyfr.Execution.run_child/5`,
  split where the time goes: admission before the guest starts, the
  guest's first streamed delta, its completed row, and the whole call as
  its caller waits on it.

  The port starts a clock when it is called and hands it to the engine in
  the call's options as `:step_spans`. The run's attempt marks the guest's
  start when its runner attaches, and its first streamed delta and its
  completed write as they happen (`Cyfr.Execution.Attempt`), from
  whichever process each happens in. Each event is emitted at most
  once per call, and only for a moment that happened: a guest that never
  started emits no admission, a guest that streams nothing emits no
  first delta, and a run that fails emits no completion.

  ## Events

  Every event measures `%{duration: integer}` in `:native` time units
  (`System.convert_time_unit/3`).

  | Event | From | To |
  |---|---|---|
  | `[:cyfr, :execution, :child, :admission]` | the port is called | the guest starts: its runner attaches |
  | `[:cyfr, :execution, :child, :first_delta]` | the guest starts | its first `text.delta` or `tool_call.*` event is pushed to its stream |
  | `[:cyfr, :execution, :child, :completion]` | the guest starts | its completed row is written |
  | `[:cyfr, :execution, :run_child]` | the port is called | the port returns, whatever it answers |

  ## Metadata

  Identifiers only, the same four on every event, taken from the call:
  `execution_id` (the child's id when the caller names one, else nil),
  `root_execution_id`, `athanor_id` (the calling context's) and
  `component` (the reference asked for). No input, output, header or
  credential ever rides an event.
  """

  @admission [:cyfr, :execution, :child, :admission]
  @first_delta [:cyfr, :execution, :child, :first_delta]
  @completion [:cyfr, :execution, :child, :completion]
  @run_child [:cyfr, :execution, :run_child]

  # The clock's shared cells, written by whichever process marks: the
  # guest's start state (0 not started, 1 being marked, 2 started — its
  # time is readable only at 2), the start's monotonic time, and whether
  # a first delta was emitted.
  @started 1
  @started_at 2
  @delta_seen 3

  @enforce_keys [:called_at, :cells, :metadata]
  defstruct [:called_at, :cells, :metadata]

  @typedoc "The clock of one `run_child/5` call."
  @type t :: %__MODULE__{
          called_at: integer(),
          cells: :atomics.atomics_ref(),
          metadata: metadata()
        }

  @typedoc "The identifiers every event carries."
  @type metadata :: %{
          execution_id: String.t() | nil,
          root_execution_id: String.t() | nil,
          athanor_id: String.t() | nil,
          component: String.t()
        }

  @doc "The four event names, in the order a run reaches them."
  @spec events() :: [[atom(), ...]]
  def events, do: [@admission, @first_delta, @completion, @run_child]

  @doc """
  Start the clock for a call of `reference` with the port's `opts`
  (`:execution_id`, `:root_execution_id`, `:ctx`).
  """
  @spec start(String.t(), keyword()) :: t()
  def start(reference, opts) when is_binary(reference) and is_list(opts) do
    %__MODULE__{
      called_at: System.monotonic_time(),
      cells: :atomics.new(3, signed: true),
      metadata: %{
        execution_id: Keyword.get(opts, :execution_id),
        root_execution_id: Keyword.get(opts, :root_execution_id),
        athanor_id: athanor_of(Keyword.get(opts, :ctx)),
        component: reference
      }
    }
  end

  @doc "Mark the guest's start and emit admission. A nil clock marks nothing."
  @spec guest_started(t() | nil) :: :ok
  def guest_started(nil), do: :ok

  def guest_started(%__MODULE__{cells: cells} = clock) do
    now = System.monotonic_time()

    if :atomics.compare_exchange(cells, @started, 0, 1) == :ok do
      :atomics.put(cells, @started_at, now)
      :atomics.put(cells, @started, 2)
      emit(@admission, now - clock.called_at, clock)
    end

    :ok
  end

  @doc """
  Mark an event pushed to the guest's stream: the first `text.delta` or
  `tool_call.*` after the guest started emits first delta. Any other
  event, and a nil clock, marks nothing.
  """
  @spec pushed(t() | nil, map()) :: :ok
  def pushed(%__MODULE__{cells: cells} = clock, %{"type" => type}) when is_binary(type) do
    if delta?(type) and :atomics.get(cells, @started) == 2 and
         :atomics.compare_exchange(cells, @delta_seen, 0, 1) == :ok do
      emit(@first_delta, System.monotonic_time() - :atomics.get(cells, @started_at), clock)
    end

    :ok
  end

  def pushed(_clock, _event), do: :ok

  @doc "Mark the completed row written and emit completion. A nil clock marks nothing."
  @spec completed(t() | nil) :: :ok
  def completed(nil), do: :ok

  def completed(%__MODULE__{cells: cells} = clock) do
    if :atomics.get(cells, @started) == 2 do
      emit(@completion, System.monotonic_time() - :atomics.get(cells, @started_at), clock)
    end

    :ok
  end

  @doc "Mark the port's return and emit run_child."
  @spec returned(t()) :: :ok
  def returned(%__MODULE__{} = clock),
    do: emit(@run_child, System.monotonic_time() - clock.called_at, clock)

  defp delta?("text.delta"), do: true
  defp delta?("tool_call." <> _), do: true
  defp delta?(_type), do: false

  defp athanor_of(%{athanor_id: athanor_id}) when is_binary(athanor_id), do: athanor_id
  defp athanor_of(_ctx), do: nil

  defp emit(event, duration, %__MODULE__{metadata: metadata}),
    do: :telemetry.execute(event, %{duration: duration}, metadata)
end
