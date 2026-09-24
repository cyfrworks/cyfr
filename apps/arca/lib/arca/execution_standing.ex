# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionStanding do
  @moduledoc """
  The rows an admitted execution's grant (`Prima.ExecutionGrant`) is held
  to, and the one contract every execution write that admits, renews,
  resumes, recovers or ends work runs under.

  ## The estate row

  `current/2` reads an estate's standing and `locked/2` reads it under a
  shared row lock inside the caller's transaction, each as the plain map
  `Arca.SecurityTransitions.Projection.athanor/1` answers (nil when there
  is no row). Nothing is decided here: the identity domain alone reads
  these rows and decides whether a grant still stands
  (`Sanctum.ExecutionStanding`).

  ## The fenced write

  An execution write that must hold a grant takes `grant:` — a
  `Prima.ExecutionGrant` or `:stored`, the stamp its attempt row carries —
  and `verify:`, the caller's check over that grant, which answers `:ok`
  or `{:error, reason}`. The write calls `verify` first in its locking
  transaction, before it locks any execution or attempt row, and matches
  the grant's generation against the attempt row's own
  `athanor_generation` once it holds that row. A write missing either
  input is refused `{:error, :missing_grant}`, and a stamp that does not
  match refuses the write as `:not_standing`.

  The lock order extends the standing transitions'
  (`Arca.SecurityTransitions`): the estate `verify` locks, then execution
  rows, then attempt rows by id, then the write intents of those attempts.
  A write never holds an attempt row and then asks for its estate's. The
  estate's lock is shared (`Arca.QueryHelpers.for_share/1`): execution
  writes and host effects never wait for one another on it, while an
  archive — which takes it exclusively — serializes against each of them:
  the write either commits first, and the archive retires what it
  admitted, or waits and reads the archive's result. A read-only host
  effect verifies in `Arca.Repo.read_transaction/1`, which on
  SQLite reads a snapshot rather than taking the one write lock.

  ## The retired scan

  `retired_attempts/3` pages, by attempt id, through the open attempts
  whose stored generation no longer matches their estate's active
  standing, for the sweep that cancels them (`Cyfr.Execution.Sweeper`).
  It answers identifiers and stored stamps only.
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.{Athanor, ExecutionAttempt}
  alias Arca.SecurityTransitions.Projection

  @typedoc "The caller's check over a grant, asked inside the write's transaction."
  @type verify :: (Prima.ExecutionGrant.t() -> :ok | {:error, term()})

  @typedoc "An attempt the retired scan found: execution, attempt, estate and stored generation."
  @type retired :: {String.t(), String.t(), String.t(), pos_integer()}

  @doc """
  The estate `athanor_id`'s standing row, read without a lock: `{:ok, row}`
  (nil when there is no such estate) or `{:error, :database_error}`. The
  actor must be in that estate.
  """
  @spec current(Prima.Actor.t(), String.t()) ::
          {:ok, map() | nil} | {:error, :database_error | :cross_tenant}
  def current(%Prima.Actor{athanor_id: athanor_id}, athanor_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionStanding.current", fn ->
      {:ok, Projection.athanor(Arca.Repo.one(estate(athanor_id)))}
    end)
  end

  def current(%Prima.Actor{}, _athanor_id), do: {:error, :cross_tenant}

  @doc """
  The estate `athanor_id`'s standing row, held against a writer until the
  caller's transaction ends (`Arca.QueryHelpers.for_share/1`): any number
  of these read it at once, and a transition that locks it for update
  waits for all of them. `{:ok, row}` (nil when there is no such estate)
  or `{:error, :database_error}`. Runs only inside a caller's transaction
  (`Arca.Repo.locking_transaction/2`, or `Arca.Repo.read_transaction/1`
  for a read-only effect), and raises outside one.
  """
  @spec locked(Prima.Actor.t(), String.t()) ::
          {:ok, map() | nil} | {:error, :database_error | :cross_tenant}
  def locked(%Prima.Actor{athanor_id: athanor_id}, athanor_id)
      when is_binary(athanor_id) and athanor_id != "" do
    unless Arca.Repo.in_transaction?() do
      raise ArgumentError, "Arca.ExecutionStanding.locked/2 runs inside a transaction"
    end

    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionStanding.locked", fn ->
      row = athanor_id |> estate() |> QueryHelpers.for_share() |> Arca.Repo.one()
      {:ok, Projection.athanor(row)}
    end)
  end

  def locked(%Prima.Actor{}, _athanor_id), do: {:error, :cross_tenant}

  defp estate(athanor_id), do: from(a in Athanor, where: a.id == ^athanor_id)

  @doc """
  Up to `limit` open attempts — `running` or `paused`, and their
  execution's current one — whose stored generation no longer matches
  their estate's active standing (an estate archived, reopened since, or
  gone), with attempt ids after `cursor` (nil for the first page), in
  attempt-id order. The server's own actor only.
  """
  @spec retired_attempts(Prima.Actor.t(), String.t() | nil, pos_integer()) ::
          {:ok, [retired()]} | {:error, :database_error | :cross_tenant}
  # arca:unscoped-ok the retired scan is a system responsibility across every
  # estate: its caller is the sweep, and it answers identifiers and stamps only.
  def retired_attempts(%Prima.Actor{scope: :platform, system: true}, cursor, limit)
      when (is_nil(cursor) or is_binary(cursor)) and is_integer(limit) and limit > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionStanding.retired_attempts", fn ->
      {:ok, Arca.Repo.all(retired_page(cursor, limit))}
    end)
  end

  def retired_attempts(%Prima.Actor{}, _cursor, _limit), do: {:error, :cross_tenant}

  defp retired_page(cursor, limit) do
    query =
      from(a in ExecutionAttempt,
        join: e in Arca.Schemas.Execution,
        on: e.id == a.execution_id and e.current_attempt == a.attempt,
        left_join: t in Athanor,
        on: t.id == a.athanor_id,
        where: a.state in ["running", "paused"] and e.status in ["running", "paused"],
        where:
          is_nil(t.id) or t.status != "active" or
            t.security_generation != a.athanor_generation,
        order_by: [asc: a.attempt],
        limit: ^limit,
        select: {a.execution_id, a.attempt, a.athanor_id, a.athanor_generation}
      )

    if is_nil(cursor), do: query, else: where(query, [a], a.attempt > ^cursor)
  end

  # ---------------------------------------------------------------------------
  # The fenced write
  # ---------------------------------------------------------------------------

  @doc false
  # The grant and check a fenced write was handed: `stored` resolves
  # `grant: :stored` (nil when there is no such attempt, which the write
  # then refuses as it refuses a row it cannot find). Missing either input
  # is `{:error, :missing_grant}`; a malformed grant is the same.
  @spec inputs(keyword() | map(), (-> Prima.ExecutionGrant.t() | nil)) ::
          {:ok, Prima.ExecutionGrant.t() | nil, verify()} | {:error, :missing_grant}
  def inputs(opts, stored) when is_function(stored, 0) do
    get = fn key -> if is_map(opts), do: Map.get(opts, key), else: Keyword.get(opts, key) end

    case {get.(:grant), get.(:verify)} do
      {:stored, verify} when is_function(verify, 1) ->
        {:ok, stored.(), verify}

      {%Prima.ExecutionGrant{} = grant, verify} when is_function(verify, 1) ->
        if Prima.ExecutionGrant.valid?(grant),
          do: {:ok, grant, verify},
          else: {:error, :missing_grant}

      _missing ->
        {:error, :missing_grant}
    end
  end

  @doc false
  @spec verify!(Prima.ExecutionGrant.t(), verify()) :: :ok
  # Ask the caller's check over `grant`, first in the caller's locking
  # transaction; a refusal rolls it back with its reason.
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  def verify!(%Prima.ExecutionGrant{} = grant, verify) when is_function(verify, 1) do
    case verify.(grant) do
      :ok -> :ok
      {:error, reason} -> Arca.Repo.rollback(reason)
    end
  end

  @doc false
  @spec stored(Prima.Actor.t() | :any, String.t()) :: Prima.ExecutionGrant.t() | nil
  # The stamp attempt `attempt` of an execution carries, read without a
  # lock — the input a `grant: :stored` write verifies before it locks the
  # row and matches the stamp again. Read in the actor's athanor, or by id
  # alone (`:any`) for the sweeps and a runner's own attempt, whose ids
  # come from trusted runtime state; the stamp names its own athanor
  # either way.
  # arca:db-raise-ok called inside its caller's rescue.
  def stored(%Prima.Actor{athanor_id: athanor_id}, attempt)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(attempt) do
    from(a in ExecutionAttempt,
      join: e in Arca.Schemas.Execution,
      on: e.id == a.execution_id and e.athanor_id == a.athanor_id,
      where: a.athanor_id == ^athanor_id and a.attempt == ^attempt,
      select: {a.athanor_id, a.athanor_generation}
    )
    |> Arca.Repo.one()
    |> grant()
  end

  # arca:unscoped-ok by attempt id alone, for the sweeps and a runner's own
  # attempt, whose ids come from trusted runtime state, never a request.
  # arca:db-raise-ok called inside its caller's rescue.
  def stored(:any, attempt) when is_binary(attempt) do
    from(a in ExecutionAttempt,
      join: e in Arca.Schemas.Execution,
      on: e.id == a.execution_id and e.athanor_id == a.athanor_id,
      where: a.attempt == ^attempt,
      select: {a.athanor_id, a.athanor_generation}
    )
    |> Arca.Repo.one()
    |> grant()
  end

  @doc false
  @spec stored_of_execution(Prima.Actor.t(), String.t()) :: Prima.ExecutionGrant.t() | nil
  # The stamp the current attempt of `execution_id` carries, read without
  # a lock: the grant a child of it, or a successor of it, inherits.
  # arca:db-raise-ok called inside its caller's rescue.
  def stored_of_execution(%Prima.Actor{athanor_id: athanor_id}, execution_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(execution_id) do
    from(a in ExecutionAttempt,
      join: e in Arca.Schemas.Execution,
      on: e.id == a.execution_id and e.current_attempt == a.attempt,
      where: a.athanor_id == ^athanor_id and e.athanor_id == ^athanor_id,
      where: e.id == ^execution_id,
      select: {a.athanor_id, a.athanor_generation}
    )
    |> Arca.Repo.one()
    |> grant()
  end

  defp grant({athanor_id, generation}) do
    case Prima.ExecutionGrant.new(athanor_id, generation) do
      {:ok, grant} -> grant
      {:error, :invalid_grant} -> nil
    end
  end

  defp grant(nil), do: nil
end
