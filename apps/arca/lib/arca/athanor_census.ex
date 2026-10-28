# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AthanorCensus do
  @moduledoc """
  The one server-wide lock a count of active athanors is taken under.

  `CYFR_MAX_ATHANORS` bounds how many athanors are active at once, and
  every write that can raise that number counts it inside the transaction
  that writes: a mint (`Arca.Athanors.mint/2`), an admission counting
  before the person whose athanor it mints (`Arca.Athanors.within_caps/2`),
  and the two transitions
  that reopen an archived athanor (`Arca.SecurityTransitions`
  `allow_user/3` and `unarchive_athanor/3`). Row locks cannot serialize
  them, because two mints hold no row in common and a count reads rows
  nobody locks, so each takes this lock before it counts and two writers
  at the last place cannot both count the place free.

  On PostgreSQL it is a transaction-level advisory lock, released when the
  transaction commits or rolls back. On SQLite every transaction that
  writes already holds the database's one write lock from its start
  (`Arca.Repo.locking_transaction/2`), so the lock takes no statement.
  `Arca.Repo.transaction_lock/1` spells both, as the one home of the
  adapters' locking statements (`Arca.LockingSeamTest`).

  It is the last lock its caller takes before the count: after the rows
  the caller already holds (the people a mint holds, the person or
  athanor a transition locks), and no row is locked after it that another
  holder of the lock takes before it. An admission takes it before its
  person's row, which no other holder can take before it commits.

  Under the SQL sandbox a test's writes run inside one transaction that
  lasts the whole test, so a test that mints, reopens or allows holds the
  lock until it ends, and async tests that do so wait for each other on
  PostgreSQL. A refused sandboxed mint gives the lock back when its
  savepoint rolls back; one that lands keeps it. A test must not mint
  both inside its sandbox and on a connection of its own
  (`unboxed_run`): the unboxed mint blocks behind the sandbox's lock, the
  test cannot end while it blocks, and the mint fails at its own query
  timeout.

  Internal to the Arca boundary: it is not exported, so only Arca's own
  writers take it.
  """

  # Fixed at compile time: one key for the server, shared by every node of
  # a cell through the one database.
  @key :erlang.phash2("arca:athanor_census")

  @doc """
  Take the census lock for the rest of the enclosing transaction
  (`Arca.Repo.transaction_lock/1`). Raises outside a transaction, where a
  lock would end with its own statement and serialize nothing.
  """
  @spec lock() :: :ok
  # arca:db-raise-ok raises outside a transaction, as its doc says; its caller holds one
  def lock, do: Arca.Repo.transaction_lock(@key)
end
