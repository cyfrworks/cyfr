# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Crew.Activity do
  @moduledoc """
  The athanor's crew at work as a canvas reads it, the `activity.changes`
  stream (`Aqua.Providers.Thread.streams/0`), and its publisher on the
  athanor's `Cyfr.Bus.crew_activity/1` topic (`Cyfr.Bus.CrewActivity`).

  A job is a crew member's turn: a turn of any agent but the soul, since
  only a member's child thread opens one (`Aqua.Runner.Admission`). It is
  its `member`, who it was `asked_by` (a person by the name a reader
  outside CYFR may see, `Sanctum.Tenancy.Users.public_name/1`; the soul
  as AQUA; another agent by its name), `since` it was accepted, and its
  `status` (`Prima.TurnState`). Never the task's text, a person's id or an
  address.

  `started/2` follows the tape's commits that open a job or start it
  (`Aqua.Tape.accept/3`, `start_turn/3`), and `ended/2` the one that ends
  it (`Aqua.Tape.finish/4`); `cancelled/3` ends the jobs an archive or a
  room's deletion cancelled, from the open turns read before the write,
  since a deleted thread's turns no longer read after it. A pause and a
  resume, which Opus writes, move no announcement, and the next refresh
  reads them.
  """

  require Logger

  alias Aqua.Runner.Admission
  alias Cyfr.Bus.CrewActivity
  alias Sanctum.Context
  alias Sanctum.Tenancy.Users

  @doc """
  The refresh of `activity.changes`: every open job of the caller's
  athanor, one per open turn of a member's child thread, oldest first,
  each read as `started`. A child thread is listed among the athanor's
  threads (`Arca.ThreadStorage.list/2`), and an archived one holds no
  open turn.
  """
  @spec open(Context.t(), nil) :: {:ok, [CrewActivity.t()]} | {:error, term()}
  def open(%Context{athanor_id: athanor_id} = ctx, _subject)
      when is_binary(athanor_id) and athanor_id != "" do
    actor = Context.actor(ctx)

    with threads when is_list(threads) <- Arca.ThreadStorage.list(actor, kind: "crew"),
         {:ok, turns} <- open_turns(ctx, for(%{archived_at: nil, id: id} <- threads, do: id)) do
      {:ok,
       turns
       |> Enum.sort_by(& &1.accepted_at, DateTime)
       |> Enum.map(&payload(actor, :started, &1))}
    end
  end

  def open(%Context{}, _subject), do: {:error, :no_athanor}

  @doc "The open turns of `thread_ids`, for a write that may cancel them (`cancelled/3`)."
  @spec open_turns(Context.t(), [String.t()]) :: {:ok, [map()]} | {:error, term()}
  def open_turns(%Context{} = ctx, thread_ids) when is_list(thread_ids) do
    actor = Context.actor(ctx)

    Enum.reduce_while(thread_ids, {:ok, []}, fn thread_id, {:ok, acc} ->
      case Arca.TurnStorage.open_turns(actor, thread_id) do
        {:ok, turns} -> {:cont, {:ok, acc ++ turns}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc "A job opened or started, as its committed turn row reads; the soul's turn is none."
  @spec started(Context.t(), map()) :: :ok
  def started(%Context{} = ctx, turn), do: announce(ctx, :started, turn)

  @doc "A job ended, as the committed turn row of its terminal write reads."
  @spec ended(Context.t(), map()) :: :ok
  def ended(%Context{} = ctx, turn), do: announce(ctx, :ended, turn)

  @doc """
  The jobs a committed archive or deletion cancelled: of `open`, the turns
  read before it, those `cancelled` names (`%{turn_id: id}`), ended
  `cancelled` as the write ended them.
  """
  @spec cancelled(Context.t(), [map()], [map()]) :: :ok
  def cancelled(%Context{} = ctx, open, cancelled) when is_list(open) and is_list(cancelled) do
    ids = for %{turn_id: id} <- cancelled, into: MapSet.new(), do: id

    for %{id: id} = turn <- open,
        MapSet.member?(ids, id),
        do: ended(ctx, %{turn | status: "cancelled"})

    :ok
  end

  defp announce(ctx, kind, %{agent: agent} = turn) when is_binary(agent) do
    if Prima.AgentRef.soul?(agent) do
      :ok
    else
      actor = Context.actor(ctx)

      case Cyfr.Bus.broadcast(actor, Cyfr.Bus.crew_activity(actor), payload(actor, kind, turn)) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[Aqua.Crew.Activity] turn #{turn.id} not announced: #{inspect(reason)}")
      end
    end
  end

  defp announce(_ctx, _kind, _turn), do: :ok

  defp payload(actor, kind, turn) do
    CrewActivity.new(actor, kind,
      member: turn.agent,
      asked_by: asked_by(turn),
      since: turn.accepted_at,
      status: turn.status
    )
  end

  # Who asked: a person by the name a reader outside CYFR may see, the
  # soul as the console names it, another agent by its name.
  defp asked_by(%{sent_by: sent_by} = turn) when is_binary(sent_by) do
    cond do
      sent_by == Admission.person() -> Users.public_name(turn.requested_by)
      Prima.AgentRef.soul?(sent_by) -> "AQUA"
      true -> sent_by
    end
  end

  defp asked_by(_turn), do: nil
end
