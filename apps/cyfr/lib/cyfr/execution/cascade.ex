# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Cascade do
  @moduledoc """
  Fails the children an execution leaves running when it ends abnormally.

  A parent that fails, is cancelled or lapses may leave child rows at
  `running`: a kill bypasses the child's own cleanup, and a spawned child
  is not linked to its parent. Each such child is failed with
  `"Parent execution (<parent id>) terminated"`, fenced on the attempt that
  owns it, and gets `[:cyfr, :opus, :execute, :exception]` and an
  `execution.failed` event; once every such child is failed, what runs
  each is stopped (`Cyfr.Execution.Dispatch.stop/2`), so neither its waiter
  nor its runner outlives the parent, and no child starts on the execution
  slot a stopped sibling gives back. A child that closed first is left as
  it closed.

  A parent that completes normally leaves its children to finish on their
  own; an abandoned one is reaped when its lease lapses
  (`Cyfr.Execution.Sweeper`).
  """

  require Logger

  alias Cyfr.Execution.{Dispatch, Events, Record, Telemetry}

  @doc """
  Fail the running children of a failed formula's record. Catalysts and
  reagents start no children, so any other record is a no-op.
  """
  @spec fail_children(Record.t()) :: :ok | {:error, term()}
  def fail_children(%Record{component_type: :formula, id: id}), do: fail_children_of(id)
  def fail_children(%Record{}), do: :ok

  @doc """
  Fail the running children of execution `execution_id`, whatever its type.
  The children are listed within the parent row's own athanor
  (`Arca.Execution.list_running_children/1`); a store that cannot list
  them answers `{:error, reason}` and nothing is failed.
  """
  @spec fail_children_of(String.t()) :: :ok | {:error, term()}
  def fail_children_of(execution_id) do
    case Arca.Execution.list_running_children(execution_id) do
      children when is_list(children) ->
        # Every child's row ends before any child is stopped: a child
        # stopped gives back its execution slot, and a sibling queued for
        # one that is granted it starts a runner unless its row has ended.
        children
        |> Enum.filter(&fail_child(execution_id, &1))
        |> Enum.each(&Dispatch.stop(&1.id, &1.athanor_id))

      {:error, reason} = error ->
        # Nothing is failed: the children run on, and end on their own.
        Logger.error(
          "[Cyfr.Execution.Cascade] children of #{execution_id} could not be listed: " <>
            inspect(reason)
        )

        error
    end
  end

  # Fails `child`'s row if it is still running, answering whether this
  # call did: a child that closed first has nothing of it to stop.
  defp fail_child(parent_id, child) do
    now = DateTime.utc_now()
    duration_ms = DateTime.diff(now, child.started_at, :millisecond)
    error_msg = "Parent execution (#{parent_id}) terminated"

    # Failing a child retires work: it needs the attempt's stored stamp,
    # never a grant that still stands
    # (`Cyfr.Boundaries.system_responsibilities/0`).
    {count, event_seq} =
      Arca.Execution.mark_failed_if_running(
        child.id,
        %{completed_at: now, duration_ms: duration_ms, error_message: error_msg},
        attempt: child.current_attempt,
        grant: :stored,
        verify: &Sanctum.ExecutionStanding.stamp_only/1
      )

    if count > 0 do
      Telemetry.row_failed(child, error_msg, duration_ms)

      Events.publish(child.id, child, "execution.failed", event_seq, %{
        "status" => "failed",
        "error" => error_msg
      })

      true
    else
      false
    end
  end
end
