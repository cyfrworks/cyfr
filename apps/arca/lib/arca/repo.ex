# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo do
  @moduledoc """
  The one repository.

  Ecto binds its adapter at compile time, which is why `CYFR_DATABASE` is
  parsed into `:arca, :repo_adapter` by a configuration file rather than
  read at runtime. `adapter/0` reports the value the compiler bound, for
  the callers that must branch on it.
  """

  use Ecto.Repo,
    otp_app: :arca,
    # config:compile-runtime-ok — Ecto binds the adapter at compile time;
    # `adapter/0` reports the same value at runtime.
    adapter: Application.compile_env(:arca, :repo_adapter, Ecto.Adapters.SQLite3)

  @doc """
  The adapter this build was compiled against, read at runtime.

  Read from configuration rather than answered as `__adapter__/0`, so a
  caller that branches on it still has two branches to write: the value is
  the deployment's, fixed at compile time, and a build's own adapter is not
  a fact about the code.
  """
  # config:compile-runtime-ok — the same key the adapter above is bound
  # from, read at runtime by the callers that branch on it.
  @spec adapter() :: module()
  def adapter, do: Application.get_env(:arca, :repo_adapter, Ecto.Adapters.SQLite3)

  # SQLite's write lock: how long one lock-taking statement may wait inside
  # the driver, the jitter between attempts, and the option that marks a
  # read transaction for `prepare_transaction/2`.
  @quantum_ms 100
  @pause_ms 5..25
  @read_only :arca_read_transaction
  @pool_deadline :pool_deadline
  # What must still fit inside a pool deadline once the lock is taken: the
  # last quantum, the pause before it, the caller's writes and the commit.
  @commit_slack_ms 500
  @default_busy_timeout_ms 5_000
  # A busy answer to a statement, in the driver's two spellings.
  @busy ["Database busy", "database is locked"]

  @doc """
  Run `fun_or_multi` as a transaction that reads rows it is about to
  change under a lock. It is `transaction/2`, named for the locking
  contracts that cite it.

  On SQLite every transaction takes the one write lock at its start
  (`prepare_transaction/2`), so a second one waits there and then reads
  what the first committed. PostgreSQL locks the rows one by one through
  `Arca.QueryHelpers.for_update/1`, in the order the caller's contract
  states.
  """
  @spec locking_transaction((-> term()) | (module() -> term()) | Ecto.Multi.t(), keyword()) ::
          {:ok, term()} | {:error, term()} | {:error, term(), term(), map()}
  def locking_transaction(fun_or_multi, opts \\ []) when is_list(opts),
    do: transaction(fun_or_multi, opts)

  @doc """
  Run `fun` as a transaction for reads that must see one consistent state
  and write nothing, beside `locking_transaction/2` for the writes.

  On SQLite it is the one transaction that takes no write lock: it waits
  behind no writer and reads a snapshot. PostgreSQL opens an ordinary
  transaction, whose `Arca.QueryHelpers.for_share/1` reads a writer waits
  for. Answers `{:ok, value}`, or `{:error, reason}` for a rollback.
  Nested inside another transaction it runs in that transaction.
  """
  @spec read_transaction((-> term())) :: {:ok, term()} | {:error, term()}
  def read_transaction(fun) when is_function(fun, 0) do
    case adapter() do
      Ecto.Adapters.SQLite3 -> transaction(fun, [{@read_only, true}])
      _postgres -> transaction(fun)
    end
  end

  @doc """
  The one place a SQLite transaction takes the write lock; the identity
  on PostgreSQL.

  SQLite's driver waits out a busy lock inside the NIF with the
  connection's mutex held, and finalizing a statement of that connection
  from another process parks that process's scheduler on the same mutex:
  a waiter can starve the very holder it waits for. So a transaction that
  is neither nested nor a `read_transaction/1` opens deferred and its
  first step takes the lock with a write that touches no row, waiting
  inside the driver at most #{@quantum_ms} ms at a time and between
  attempts in Elixir, until `busy_timeout_ms/0` has passed. The
  connection's busy timeout is back to the pool's before the caller's
  work runs. An `Ecto.Multi` gets the step as its first operation,
  `:arca_lock`.

  Out of time, the step raises `Arca.Repo.BusyTimeoutError` before any of
  the caller's work, which `Arca.Repo.Errors.db_errors/0` names. A nested
  transaction already holds the lock, and a read transaction takes none.
  """
  @impl true
  def prepare_transaction(fun_or_multi, opts) do
    case adapter() do
      Ecto.Adapters.SQLite3 -> prepare_sqlite(fun_or_multi, opts)
      # The lock step is SQLite's; the pool deadline it takes has no
      # reader here and does not reach the driver.
      _postgres -> {fun_or_multi, Keyword.delete(opts, @pool_deadline)}
    end
  end

  defp prepare_sqlite(fun_or_multi, opts) do
    {read_only?, opts} = Keyword.pop(opts, @read_only, false)
    {pool_deadline, opts} = Keyword.pop(opts, @pool_deadline)

    cond do
      in_transaction?() -> {fun_or_multi, opts}
      read_only? -> {fun_or_multi, Keyword.put(opts, :mode, :deferred)}
      true -> {locking(fun_or_multi, pool_deadline), Keyword.put(opts, :mode, :deferred)}
    end
  end

  defp locking(fun, pool_deadline) when is_function(fun, 0) do
    fn ->
      take_write_lock!(pool_deadline)
      fun.()
    end
  end

  defp locking(fun, pool_deadline) when is_function(fun, 1) do
    fn repo ->
      take_write_lock!(pool_deadline)
      fun.(repo)
    end
  end

  # Ecto's transaction accepts a fun or a Multi and nothing else, so what is
  # not a fun is the Multi; matching its struct would break its opaque type.
  defp locking(multi, pool_deadline) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:arca_lock, fn _repo, _changes -> {:ok, take_write_lock!(pool_deadline)} end)
    |> Ecto.Multi.append(multi)
  end

  # The write lands on Ecto's migrations table: the migrator creates it
  # before it opens the first migration's transaction, so it is there for
  # every transaction this hook sees, the baseline migration's included.
  # `WHERE 0` touches no row, and SQLite takes the lock before planning it.
  #
  # A caller whose connection the pool will close at an absolute deadline
  # (`:pool_deadline`, in `System.monotonic_time(:millisecond)`) names it,
  # and the wait is cut so that it ends, with the caller's own writes and
  # the commit, before the pool acts: a lock quantum, the pause and the
  # commit's fsync all fit inside `@commit_slack_ms`. Out of that slack
  # before the first attempt — a wait for the connection itself took the
  # time — the step raises at once and touches no lock. The pool's deadline
  # counts from the checkout request, so no fixed margin above the busy
  # timeout could promise this on its own.
  defp take_write_lock!(pool_deadline) do
    config = config()
    deadline_ms = lock_wait_ms(busy_timeout_ms(config), pool_deadline)

    if deadline_ms <= 0,
      do: raise(Arca.Repo.BusyTimeoutError, deadline_ms: 0)

    source = config[:migration_source] || "schema_migrations"
    statement = ~s(UPDATE "#{source}" SET version = version WHERE 0)
    started = System.monotonic_time(:millisecond)
    query!("PRAGMA busy_timeout = #{@quantum_ms}", [], log: false)

    try do
      attempt_write_lock(statement, started, deadline_ms)
    after
      query!("PRAGMA busy_timeout = #{busy_timeout_ms(config)}", [], log: false)
    end
  end

  defp lock_wait_ms(busy_ms, nil), do: busy_ms

  defp lock_wait_ms(busy_ms, pool_deadline) do
    min(busy_ms, pool_deadline - System.monotonic_time(:millisecond) - @commit_slack_ms)
  end

  defp attempt_write_lock(statement, started, deadline_ms) do
    case query(statement, [], log: false) do
      {:ok, _result} ->
        :acquired

      {:error, %Exqlite.Error{message: message}} when message in @busy ->
        if System.monotonic_time(:millisecond) - started >= deadline_ms,
          do: raise(Arca.Repo.BusyTimeoutError, deadline_ms: deadline_ms)

        Process.sleep(Enum.random(@pause_ms))
        attempt_write_lock(statement, started, deadline_ms)

      {:error, error} ->
        raise error
    end
  end

  @doc """
  How long a SQLite transaction waits for the write lock before it
  raises: the pool's configured `:busy_timeout`, which is also each
  connection's own wait for a statement outside a transaction.
  """
  @spec busy_timeout_ms() :: pos_integer()
  def busy_timeout_ms, do: busy_timeout_ms(config())

  defp busy_timeout_ms(config), do: config[:busy_timeout] || @default_busy_timeout_ms

  @doc "Where this application's migrations live."
  @spec migrations_path() :: String.t()
  def migrations_path, do: Application.app_dir(:arca, "priv/repo/migrations")
end
