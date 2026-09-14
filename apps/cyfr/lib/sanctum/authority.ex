# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority do
  @moduledoc """
  The live half of `Cyfr.Authority`: what an authority does against this
  node's running state rather than as data.

    * `step/3` is `Cyfr.Authority.Transition.step/3` with the root budget
      charged. Every `spawn` outcome that starts work — a bound child, a
      zero child, or an allowed tool dispatch — takes one slot of the
      root-keyed invoke budget at this single chokepoint; exhaustion turns
      the outcome into `{:deny, :invoke_budget_exhausted}`. A denied or
      malformed spawn consumes nothing, and synchronous `call` is bounded
      by the depth cap instead: it adds no concurrency, the parent blocks.
      The caller releases the slot via `release_invoke/1` when the spawned
      work completes.
    * The invoke-budget counter (`Sanctum.Authority.BudgetCounter`) behind
      the budget id: `try_acquire_invoke/1`, `guard_invoke/2`,
      `release_invoke/1` and `budget/1`. The id names the root's reservation
      row (`Arca.BudgetReservations`), which is the authority on what is in
      flight; the counter on this node is a pre-check.
    * `from_wire/1`, which reads `Cyfr.Authority.to_wire/1`'s map back under
      this instance's platform ceiling and the reservation row's cap.
  """

  alias Cyfr.Authority
  alias Cyfr.Authority.Blob
  alias Cyfr.Authority.Budget
  alias Cyfr.Authority.Transition
  alias Sanctum.Authority.BudgetCounter
  alias Sanctum.Authority.BudgetGuard

  @depth_cap Authority.depth_cap()

  # ============================================================================
  # Charged transition
  # ============================================================================

  @doc """
  Apply one guest function to a target under an Authority, charging the
  root budget for every `spawn` that starts work.

  The decision is `Cyfr.Authority.Transition.step/3`'s; a caller that
  dispatches the outcome as spawned work steps through here so no handler
  can forget the charge and no deny path needs a rollback.
  """
  @spec step(Authority.t(), Transition.guest_fn(), Transition.target()) :: Transition.outcome()
  def step(%Authority{} = auth, guest_fn, target) do
    auth
    |> Transition.step(guest_fn, target)
    |> charge_spawn_budget(auth, guest_fn)
  end

  defp charge_spawn_budget(outcome, auth, :spawn)
       when elem(outcome, 0) in [:child, :child_zero, :allow_tool] do
    case try_acquire_invoke(auth) do
      :ok -> outcome
      {:error, :invoke_budget_exhausted} -> {:deny, :invoke_budget_exhausted}
    end
  end

  defp charge_spawn_budget(outcome, _auth, _fun), do: outcome

  # ============================================================================
  # Root budget
  # ============================================================================

  @doc """
  Take one root-keyed invoke-budget slot. Every acquire must be paired with
  `release_invoke/1` when the spawned work completes — and the process
  doing the work registers itself with `guard_invoke/2` so a slot whose
  holder is brutally killed (the cancel and await-timeout paths) is
  released by the guard's `:DOWN` compensation instead of leaking.
  """
  @spec try_acquire_invoke(Authority.t()) :: :ok | {:error, :invoke_budget_exhausted}
  def try_acquire_invoke(%Authority{budget: %Budget{} = budget}),
    do: BudgetCounter.try_acquire(budget)

  @doc """
  Register the calling (or named) process as the holder of one charged
  slot — see `Sanctum.Authority.BudgetGuard`.
  """
  @spec guard_invoke(Authority.t(), pid()) :: :ok
  def guard_invoke(%Authority{budget: %Budget{} = budget}, pid \\ self()),
    do: BudgetGuard.guard(budget, pid)

  @spec release_invoke(Authority.t()) :: :ok
  def release_invoke(%Authority{budget: %Budget{} = budget}),
    do: BudgetGuard.release(budget, self())

  @spec budget(Authority.t()) :: %{in_flight: non_neg_integer(), cap: non_neg_integer()}
  def budget(%Authority{budget: %Budget{} = budget}), do: BudgetCounter.snapshot(budget)

  # ============================================================================
  # Wire
  # ============================================================================

  @doc """
  An Authority back from its wire map. Fail-closed: every field is
  validated the way the blob parser validates a consent — an unknown key,
  a malformed cursor or a policy that does not parse is an error, never a
  looser Authority.
  """
  @spec from_wire(map()) :: {:ok, Authority.t()} | {:error, term()}
  def from_wire(%{} = wire) do
    with :ok <- wire_keys(wire),
         {:ok, profile_kind} <- wire_enum(wire["profile_kind"], [:owner, :public], true),
         {:ok, invoke_mode} <- wire_enum(wire["invoke_mode"], [:open_inert, :edge_only], false),
         {:ok, policy} <- wire_policy(wire["policy"]),
         {:ok, cursor} <- wire_cursor(wire["cursor"]),
         {:ok, resources} <- wire_resources(wire["resources"]),
         {:ok, budget} <- wire_budget(wire["budget"]),
         :ok <- wire_strings(wire["chain"], "chain"),
         :ok <- wire_activation(wire["activation"]),
         :ok <- wire_depth(wire["depth"]) do
      {:ok,
       %Authority{
         profile_id: wire["profile_id"],
         consent_id: wire["consent_id"],
         source_ref: wire["source_ref"],
         profile_kind: profile_kind,
         policy: policy,
         activation: wire["activation"],
         invoke_mode: invoke_mode,
         cursor: cursor,
         resources: resources,
         chain: wire["chain"],
         depth: wire["depth"],
         budget: budget
       }}
    end
  end

  def from_wire(other), do: {:error, {:invalid_wire, other}}

  @wire_keys Enum.sort(
               ~w(profile_id consent_id source_ref profile_kind policy activation invoke_mode cursor resources chain depth budget)
             )

  defp wire_keys(wire) do
    case Enum.sort(Map.keys(wire)) do
      @wire_keys -> :ok
      keys -> {:error, {:invalid_wire_keys, keys}}
    end
  end

  defp wire_enum(nil, _allowed, true), do: {:ok, nil}

  defp wire_enum(value, allowed, _nil_ok) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_wire_value, value}}
      atom -> {:ok, atom}
    end
  end

  defp wire_enum(value, _allowed, _nil_ok), do: {:error, {:invalid_wire_value, value}}

  defp wire_policy(nil), do: {:ok, :none}

  defp wire_policy(%{} = map) do
    case Blob.parse(map) do
      # Clamped on the way in, exactly as `Cyfr.Authority.root/3` clamps on
      # the way out of a consent. A wire map is the one route to an Authority
      # that does not pass through `root/3`, so it re-establishes the ceiling
      # itself — a sender that could install its own limits would be a sender
      # that writes its own roof.
      {:ok, blob} -> {:ok, Blob.clamp(blob, Sanctum.Policy.Ceiling.platform_ceiling())}
      {:error, reason} -> {:error, {:invalid_wire_policy, reason}}
    end
  end

  defp wire_policy(other), do: {:error, {:invalid_wire_policy, other}}

  defp wire_cursor("unbound"), do: {:ok, :unbound}
  defp wire_cursor(%{"bound" => ref}) when is_binary(ref) and ref != "", do: {:ok, {:bound, ref}}
  defp wire_cursor(other), do: {:error, {:invalid_wire_cursor, other}}

  defp wire_resources(nil), do: {:ok, :none}

  defp wire_resources(%{} = map) do
    case Blob.parse_edge(map) do
      {:ok, edge} -> {:ok, edge}
      {:error, reason} -> {:error, {:invalid_wire_resources, reason}}
    end
  end

  defp wire_resources(other), do: {:error, {:invalid_wire_resources, other}}

  # The wire names the reservation; the cap is the row's, never the
  # sender's — a sender that could write its cap would write its own
  # ceiling. A reservation the store does not know, or one already
  # released, does not cross.
  defp wire_budget(%{"id" => id} = map) when is_binary(id) and id != "" and map_size(map) == 1 do
    case Arca.BudgetReservations.fetch(id) do
      {:ok, %{released_at: nil, cap: cap}} -> {:ok, %Budget{id: id, cap: cap}}
      {:ok, _released} -> {:error, {:released_reservation, id}}
      {:error, :not_found} -> {:error, {:unknown_reservation, id}}
      {:error, reason} -> {:error, {:reservation_unavailable, reason}}
    end
  end

  defp wire_budget(other), do: {:error, {:invalid_wire_budget, other}}

  defp wire_strings(list, _label) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, {:invalid_wire_chain, list}}
  end

  defp wire_strings(other, label), do: {:error, {:"invalid_wire_#{label}", other}}

  defp wire_activation(%{} = map) do
    if Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end),
      do: :ok,
      else: {:error, {:invalid_wire_activation, map}}
  end

  defp wire_activation(other), do: {:error, {:invalid_wire_activation, other}}

  # Bounded by the same cap `Cyfr.Authority.Transition` checks before every
  # invoke. Accepting any non-negative integer let a wire map hand back an
  # authority already past the cap — or restart the count at zero, which is
  # the other half of the same hole.
  defp wire_depth(depth) when is_integer(depth) and depth >= 0 and depth <= @depth_cap, do: :ok

  defp wire_depth(other), do: {:error, {:invalid_wire_depth, other}}
end
