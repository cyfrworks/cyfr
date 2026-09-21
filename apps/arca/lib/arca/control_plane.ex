# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ControlPlane do
  @moduledoc """
  Whether this member of the cell holds its slot, and under which
  generation — answered from a cached copy of its `cell_leases` row.

  Every gate in the product asks this on the way in: the operation
  catalog before dispatch, the ownership plug on every request, the
  runner before it starts a thread, each background job on every tick. So
  it is a term read and an integer comparison, never a query. The row is
  the authority; this is the copy the authority leaves behind.

  ## The two clocks

  Which member holds a slot is decided on DATABASE time
  (`Arca.ServerMetaStorage.now!/0`), in the statement that writes the row:
  a take compares the lease it is replacing against the database's clock,
  so members whose own clocks have drifted still agree.

  How long a member goes on believing its own answer is decided on that
  member's MONOTONIC clock. `record/1` is handed a duration — the time
  left of the lease just won — not a deadline, and `held?/0` counts it
  down locally. A duration cannot carry the skew between a member's clock
  and the database's, and a monotonic countdown cannot be moved by a clock
  step, a leap second or an operator's hand. The claimant takes its
  monotonic instant BEFORE it issues the write and derives the duration
  from that instant, so what this module believes always runs out before
  the row it stands for becomes takeable, never after.

  ## The generation

  `generation/0` is the member's, not the cell's. It rises when this
  member's slot is taken over by a successor and at no other time, so a
  peer joining or leaving the cell invalidates nothing this member issued.
  Work issued under a generation — a worker assignment, a host-call
  binding, a bridge grant — is recognisably older than the same member's
  successor's, which is what fences a member that has been replaced.

    * `{:ok, n}` — this member holds `n`.
    * `:none` — no member claims a slot in this deployment, so there is no
      generation to stamp and nothing to fence.
    * `{:error, :unavailable}` — a slot is claimed here but this member
      holds no generation: before its claim is won, or after it lost the
      row. Never `:none`: the generation is not known, so nothing may be
      issued or checked under one.

  ## Who writes it

  The cell's claimant, and nothing else. This module keeps no timer, no
  process and no second copy of the row: it holds what the claimant last
  recorded and answers from that alone. A reader that needs the row itself
  reads the row.
  """

  @standing_key {__MODULE__, :standing}
  @generation_key {__MODULE__, :generation}

  @typedoc """
  What this member holds: its slot for a further `ms` milliseconds on the
  local monotonic clock, its slot indefinitely (no claimant runs, so
  nothing can take it), nothing after a lapse, or nothing recorded yet.
  """
  @type standing :: {:held, non_neg_integer() | :indefinitely} | :lost | :unclaimed

  @doc """
  Whether this member holds its slot right now. No query, no process, no
  wall clock.
  """
  @spec held?() :: boolean()
  def held? do
    case :persistent_term.get(@standing_key, :unclaimed) do
      {:held, :indefinitely} -> true
      {:held, deadline} -> System.monotonic_time(:millisecond) < deadline
      :lost -> false
      :unclaimed -> not claimed_here?()
    end
  end

  @doc "The generation this member holds. See the module doc."
  @spec generation() :: {:ok, pos_integer()} | :none | {:error, :unavailable}
  def generation do
    case :persistent_term.get(@generation_key, nil) do
      generation when is_integer(generation) -> {:ok, generation}
      :none -> :none
      nil -> if claimed_here?(), do: {:error, :unavailable}, else: :none
    end
  end

  @doc """
  Record what this member holds. The claimant's to call, and no one
  else's; a test that needs a member in a given state calls it too.

  `{:held, ms}` is a DURATION, counted down from now on the local
  monotonic clock — see the module doc for why it is not a deadline. The
  claimant takes its monotonic instant before the write that won the
  lease and passes the remainder, so this runs out first.
  """
  @spec record(standing()) :: :ok
  def record({:held, :indefinitely} = standing),
    do: :persistent_term.put(@standing_key, standing)

  def record({:held, ms}) when is_integer(ms) and ms >= 0,
    do: :persistent_term.put(@standing_key, {:held, System.monotonic_time(:millisecond) + ms})

  def record(standing) when standing in [:lost, :unclaimed],
    do: :persistent_term.put(@standing_key, standing)

  @doc """
  Record the generation this member won, or `:none` where no member claims
  a slot. `forget_generation/0` for a member that holds none: its
  generation is unknown, which is not the same as there being none.
  """
  @spec record_generation(pos_integer() | :none) :: :ok
  def record_generation(:none), do: :persistent_term.put(@generation_key, :none)

  def record_generation(generation) when is_integer(generation) and generation > 0,
    do: :persistent_term.put(@generation_key, generation)

  @doc "Unrecord the generation: this member holds none and none is known."
  @spec forget_generation() :: :ok
  def forget_generation do
    _ = :persistent_term.erase(@generation_key)
    :ok
  end

  # Whether a claimant runs in this deployment at all. With one, a member
  # that has recorded nothing holds nothing — the fail-closed direction,
  # and the state of every member between its start and its first claim.
  # Without one there is no slot to take, so every boot holds.
  defp claimed_here?, do: Application.get_env(:arca, :control_plane_claim_enabled, true)
end
