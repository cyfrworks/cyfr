# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AthanorCensus do
  @moduledoc """
  The one server-wide lock a count of active athanors is taken under.

  `CYFR_MAX_ATHANORS` bounds how many athanors are active at once, and
  every write that can raise that number counts it inside the transaction
  that writes: a mint (`Arca.Athanors.mint/2`), and the two transitions
  that reopen an archived athanor (`Arca.SecurityTransitions`
  `allow_user/3` and `unarchive_athanor/3`). Row locks cannot serialize
  them, because two mints hold no row in common and a count reads rows
  nobody locks, so each takes this lock before it counts and two writers
  at the last place cannot both count the place free.

  On PostgreSQL it is a transaction-level advisory lock, released when the
  transaction commits or rolls back. On SQLite every transaction that
  writes already holds the database's one write lock from its start
  (`Arca.Repo.locking_transaction/2`), so the lock takes no statement.

  It is the last lock its caller takes before the count: after the rows
  the caller already holds (the people a mint holds, the person or
  athanor a transition locks), and no row is locked after it that another
  holder of the lock takes before it.

  Internal to the Arca boundary: it is not exported, so only Arca's own
  writers take it.
  """

  # Fixed at compile time: one key for the server, shared by every node of
  # a cell through the one database.
  @key :erlang.phash2("arca:athanor_census")

  @doc """
  Take the census lock for the rest of the enclosing transaction. Raises
  outside a transaction, where a lock would end with its own statement
  and serialize nothing.
  """
  @spec lock() :: :ok
  # arca:unscoped-ok an advisory lock on a server-wide key; no table, no tenant.
  # arca:db-raise-ok a step inside the caller's transaction, which must roll back if it fails.
  def lock do
    unless Arca.Repo.in_transaction?() do
      raise "Arca.AthanorCensus.lock/0 called outside a transaction"
    end

    case Arca.Repo.adapter() do
      Ecto.Adapters.Postgres ->
        Arca.Repo.query!("SELECT pg_advisory_xact_lock($1)", [@key])
        :ok

      _sqlite ->
        :ok
    end
  end
end
