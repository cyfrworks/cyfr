# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Health do
  @moduledoc """
  Whether the database answers.

  A probe, not a query. It asks the pool for one value the database
  computes itself (`SELECT 1`) and reads no table, which is the whole
  point: a probe that read product rows would answer "nothing there" for
  a freshly migrated database and could not tell that apart from a
  database that is gone. Absent data is not unavailable infrastructure,
  and this probe cannot confuse the two because it never looks at data.

  What depends on that distinction is a load balancer's rotation. A
  readiness check that says "ready" while the database is unreachable
  puts a broken node back in front of traffic; one that says "not ready"
  because a table is empty takes a healthy node out of it.

  ## Its first argument

  Every other Arca facade takes the caller's actor and works on that
  actor's athanor. A readiness check has no athanor to work on — it is
  the server asking about its own connection, for no caller — so it takes
  `Prima.Actor.system/0`, the actor the control plane holds when it acts as
  itself, and matches `system: true` in the head. An ordinary tenant
  actor is refused and reaches no connection: accepting one would imply
  the probe had checked something on that tenant's behalf, and it has
  not. A probe with no argument at all would say the same thing less
  loudly, and would be the one Arca entry point whose authority is
  implied by an absence.

  ## Three answers, three meanings

    * `:ok` — the database answered. Whether it holds any rows is not
      asked and not implied.
    * `{:error, {:unavailable, why}}` — it did not answer: no connection,
      a closed pool, a repo that never started, an adapter error. `why` is
      a sentence for the operator's log.
    * `{:error, :not_system}` — the caller holds no system authority.

  None of the three is a degraded form of another, and a caller that
  collapses them loses the decision the probe exists to make.
  """

  @type refusal :: {:error, {:unavailable, String.t()} | :not_system}

  @doc """
  Ask the database for one computed value and say whether it came back.

  Takes the server's own actor (`Prima.Actor.system/0`).
  """
  @spec check(Prima.Actor.t()) :: :ok | refusal()
  # arca:unscoped-ok a reachability probe — `SELECT 1` reads no table, so there is no tenant to scope to.
  def check(%Prima.Actor{system: true}) do
    case Arca.Repo.query("SELECT 1") do
      {:ok, _} -> :ok
      {:error, reason} -> unavailable(reason)
    end
  rescue
    # Deliberately not `Arca.Repo.Errors.with_db_rescue/2`: the failure a
    # readiness probe exists to catch is often not an adapter error at all.
    # A repo that never started, or whose supervisor is gone, raises an
    # ArgumentError or a RuntimeError, and the outage the probe must report
    # would otherwise escape as a crash — answering the load balancer with
    # a 500 instead of the refusal that takes the node out of rotation.
    e -> unavailable(Exception.message(e))
  end

  def check(%Prima.Actor{}), do: {:error, :not_system}

  # One shape for the reason, whatever raised or was returned: a string, so
  # the operator's log never mixes Ecto structs, atoms and exception
  # messages.
  defp unavailable(reason) when is_binary(reason), do: {:error, {:unavailable, reason}}
  defp unavailable(reason), do: {:error, {:unavailable, inspect(reason)}}
end
