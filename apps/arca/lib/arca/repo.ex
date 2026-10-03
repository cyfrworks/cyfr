# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo do
  @moduledoc """
  The one repository.

  Ecto binds its adapter at compile time, which is why `CYFR_DATABASE` is
  parsed into `:arca, :repo_adapter` by a configuration file rather than
  read at runtime. `adapter/0` reports the value the compiler bound, for
  the callers that must branch on it.

  On SQLite every write takes the one write lock through the lock step
  (`prepare_transaction/2`): a transaction as it starts, and a write run
  outside a transaction (`insert`, `update`, `delete` and their bang
  forms, `insert_or_update`, `insert_all`, `update_all`, `delete_all`) as
  a transaction of its one statement. Such a write that cannot take the
  lock in time raises `Arca.Repo.BusyTimeoutError`, as the transaction
  does, within its own `timeout:` where it names one. One whose connection
  the pool closed under it raises `DBConnection.ConnectionError`, and so
  does an `insert_all`, `update_all` or `delete_all` inside a transaction,
  rather than answering a count of `nil`.

  A write Ecto answers without a statement (an invalid changeset, an
  update with no change and no `force: true`, an `insert_all` of no
  entries) answers as Ecto answers it, taking no lock.
  """

  use Ecto.Repo,
    otp_app: :arca,
    # config:compile-runtime-ok — Ecto binds the adapter at compile time;
    # `adapter/0` reports the same value at runtime.
    adapter: Application.compile_env(:arca, :repo_adapter, Ecto.Adapters.SQLite3)

  # The writes a caller can run outside a transaction, each redefined below
  # to take SQLite's write lock through the lock step (`standalone/4`).
  defoverridable insert: 2,
                 insert!: 2,
                 update: 2,
                 update!: 2,
                 delete: 2,
                 delete!: 2,
                 insert_or_update: 2,
                 insert_or_update!: 2,
                 insert_all: 3,
                 update_all: 3,
                 delete_all: 2

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
  # the driver, the jitter between attempts, the option that marks a read
  # transaction for `prepare_transaction/2`, and the one that carries a
  # writer's kind to the lock step (`Arca.WriteTurn`).
  @quantum_ms 100
  @pause_ms 5..25
  @read_only :arca_read_transaction
  @write_turn :arca_write_turn
  @turn_kinds [:audit, :control_plane]
  @pool_deadline :pool_deadline
  # What must still fit inside a pool deadline once the lock is taken: the
  # last quantum, the pause before it, the caller's writes and the commit.
  # At most half the caller's own `timeout:` (`commit_slack_ms/1`).
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

  `write_turn: :audit | :control_plane` names a writer `Arca.WriteTurn`
  orders on SQLite: the lock step asks for its turn once the connection
  is held and before the lock, within the same deadline, and the turn is
  given back here once the transaction has committed or rolled back,
  whatever it answered or raised. A process that already holds a turn
  keeps it for its outer transaction. PostgreSQL asks for no turn, and
  neither does a SQLite store where turns are off
  (`Arca.WriteTurn.enabled?/0`).
  """
  @spec locking_transaction((-> term()) | (module() -> term()) | Ecto.Multi.t(), keyword()) ::
          {:ok, term()} | {:error, term()} | {:error, term(), term(), map()}
  def locking_transaction(fun_or_multi, opts \\ []) when is_list(opts) do
    case Keyword.pop(opts, :write_turn) do
      {nil, opts} ->
        transaction(fun_or_multi, opts)

      {kind, opts} when kind in @turn_kinds ->
        held? = Arca.WriteTurn.holding?()

        try do
          transaction(fun_or_multi, [{@write_turn, kind} | opts])
        after
          unless held?, do: Arca.WriteTurn.release()
        end
    end
  end

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

  # ---- standalone writes -------------------------------------------------------
  #
  # A write run outside a transaction would wait for SQLite's write lock
  # inside the driver for the whole busy timeout, holding a dirty I/O
  # scheduler while it waits. Enough such waiters hold every one of them,
  # and a transaction that already holds the lock then cannot step its next
  # statement until their waits run out, however long the waiters keep
  # coming: a renewal's among them. So on SQLite each runs as a transaction
  # of its one statement, whose lock step waits inside the driver a quantum
  # at a time (`prepare_transaction/2`). It takes no write turn. Inside a
  # transaction, which already holds the lock, the write is Ecto's own, and
  # so is a write Ecto answers without a statement (`no_statement?/3`); on
  # PostgreSQL every write is.
  #
  # The driver reads a statement's row count off the connection once the
  # statement is done, and reads `nil` from a connection the pool closed
  # meanwhile at its timeout: the close waits for the running statement,
  # then the count is read. So on SQLite a count of `nil` from
  # `insert_all`, `update_all` or `delete_all`, inside a transaction or
  # not, raises the closed connection it is (`counted/2`), which
  # `Arca.Repo.Errors.db_errors/0` names, and is never answered as a count.
  # A connection closed after the count was read leaves the write's own
  # transaction uncommitted, and that raises the same.

  @impl true
  def insert(struct, opts),
    do: standalone(:answer, {:insert, struct}, opts, fn -> super(struct, opts) end)

  @impl true
  def insert!(struct, opts),
    do: standalone(:value, {:insert, struct}, opts, fn -> super(struct, opts) end)

  @impl true
  def update(changeset, opts),
    do: standalone(:answer, {:update, changeset}, opts, fn -> super(changeset, opts) end)

  @impl true
  def update!(changeset, opts),
    do: standalone(:value, {:update, changeset}, opts, fn -> super(changeset, opts) end)

  @impl true
  def delete(struct, opts),
    do: standalone(:answer, {:delete, struct}, opts, fn -> super(struct, opts) end)

  @impl true
  def delete!(struct, opts),
    do: standalone(:value, {:delete, struct}, opts, fn -> super(struct, opts) end)

  @impl true
  def insert_or_update(changeset, opts),
    do:
      standalone(:answer, {:insert_or_update, changeset}, opts, fn -> super(changeset, opts) end)

  @impl true
  def insert_or_update!(changeset, opts),
    do: standalone(:value, {:insert_or_update, changeset}, opts, fn -> super(changeset, opts) end)

  @impl true
  def insert_all(source, entries, opts),
    do: standalone(:count, {:insert_all, entries}, opts, fn -> super(source, entries, opts) end)

  @impl true
  def update_all(queryable, updates, opts),
    do:
      standalone(:count, {:update_all, queryable}, opts, fn -> super(queryable, updates, opts) end)

  @impl true
  def delete_all(queryable, opts),
    do: standalone(:count, {:delete_all, queryable}, opts, fn -> super(queryable, opts) end)

  # `:answer` for a write that answers `{:ok, _}` or `{:error, _}`, which the
  # transaction answers in its place, rolled back on an error; `:value` for
  # one that returns its value or raises; `:count` for one that returns its
  # row count and rows, or raises.
  defp standalone(kind, {operation, subject}, opts, write) do
    cond do
      adapter() != Ecto.Adapters.SQLite3 -> write.()
      no_statement?(operation, subject, opts) -> write.()
      in_transaction?() -> counted(kind, write.())
      true -> one_statement(kind, fn -> counted(kind, write.()) end, one_statement_opts(opts))
    end
  end

  # What Ecto answers without sending a statement, as it answers it: an
  # invalid changeset, refused; an update with no change and no `force:`,
  # answered with its data, whether it comes as an update or as an
  # `insert_or_update` of loaded data; and an `insert_all` of no entries.
  defp no_statement?(_operation, %Ecto.Changeset{valid?: false}, _opts), do: true

  defp no_statement?(:update, %Ecto.Changeset{} = changeset, opts),
    do: unchanged?(changeset, opts)

  defp no_statement?(
         :insert_or_update,
         %Ecto.Changeset{data: %{__meta__: %{state: :loaded}}} = changeset,
         opts
       ),
       do: unchanged?(changeset, opts)

  defp no_statement?(:insert_all, [], _opts), do: true
  defp no_statement?(_operation, _subject, _opts), do: false

  # Ecto reads `force` from the changeset's own repo options under the
  # call's.
  defp unchanged?(%Ecto.Changeset{changes: changes, repo_opts: repo_opts}, opts),
    do: changes == %{} and !Keyword.merge(repo_opts, opts)[:force]

  # The write never asks for a rollback, so `{:error, :rollback}` is the
  # transaction's own: the pool closed its connection after the statement
  # answered, and nothing committed.
  defp one_statement(:answer, write, opts) do
    case transact(write, opts) do
      {:error, :rollback} -> closed!()
      answer -> answer
    end
  end

  defp one_statement(_value_or_count, write, opts) do
    case transaction(write, opts) do
      {:ok, value} -> value
      {:error, :rollback} -> closed!()
    end
  end

  # Raised inside the write's transaction, so it rolls back with it.
  defp counted(:count, {nil, _rows}), do: closed!()
  defp counted(_kind, answer), do: answer

  @spec closed!() :: no_return()
  defp closed!, do: raise(DBConnection.ConnectionError, "connection closed")

  # What the transaction keeps of the write's options: its log level, so
  # the transaction logs nothing the caller silenced, and its pool timeout,
  # which now bounds the whole transaction. The pool closes a connection
  # held past it, so the lock step is told the instant (`:pool_deadline`).
  defp one_statement_opts(opts) do
    kept = Keyword.take(opts, [:log, :timeout])

    case Keyword.get(kept, :timeout) do
      ms when is_integer(ms) ->
        [{@pool_deadline, System.monotonic_time(:millisecond) + ms} | kept]

      _default_or_infinity ->
        kept
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
  `:arca_lock`. A write run outside a transaction is a transaction of its
  one statement here, so it waits the same way.

  A writer `locking_transaction/2` names (`write_turn:`) first asks
  `Arca.WriteTurn` for its turn, holding its connection and within the
  same deadline, so its lock wait begins only once its turn is issued;
  the turn is asked for before any statement, the step's own included.

  Out of time, the step raises `Arca.Repo.BusyTimeoutError` before any of
  the caller's work, which `Arca.Repo.Errors.db_errors/0` names, whether
  the time went waiting for the turn or for the lock; an audit request
  past the turn queue's capacity raises `Arca.WriteTurn.CapacityError`. A
  nested transaction already holds the lock, and a read transaction takes
  none.
  """
  @impl true
  def prepare_transaction(fun_or_multi, opts) do
    case adapter() do
      Ecto.Adapters.SQLite3 ->
        prepare_sqlite(fun_or_multi, opts)

      # The lock step and the turn are SQLite's; the pool deadline and the
      # writer's kind have no reader here and do not reach the driver.
      _postgres ->
        {fun_or_multi, Keyword.drop(opts, [@pool_deadline, @write_turn])}
    end
  end

  defp prepare_sqlite(fun_or_multi, opts) do
    {read_only?, opts} = Keyword.pop(opts, @read_only, false)
    {pool_deadline, opts} = Keyword.pop(opts, @pool_deadline)
    {turn, opts} = Keyword.pop(opts, @write_turn)

    step = {pool_deadline, commit_slack_ms(opts[:timeout]), turn}

    cond do
      in_transaction?() -> {fun_or_multi, opts}
      read_only? -> {fun_or_multi, Keyword.put(opts, :mode, :deferred)}
      true -> {locking(fun_or_multi, step), Keyword.put(opts, :mode, :deferred)}
    end
  end

  # A short pool timeout keeps half of itself for the commit and gives the
  # lock wait the rest, so it still gets its attempt; past twice the fixed
  # slack the slack is the fixed one.
  defp commit_slack_ms(timeout) when is_integer(timeout),
    do: min(@commit_slack_ms, div(timeout, 2))

  defp commit_slack_ms(_default_or_infinity), do: @commit_slack_ms

  defp locking(fun, step) when is_function(fun, 0) do
    fn ->
      take_write_lock!(step)
      fun.()
    end
  end

  defp locking(fun, step) when is_function(fun, 1) do
    fn repo ->
      take_write_lock!(step)
      fun.(repo)
    end
  end

  # Ecto's transaction accepts a fun or a Multi and nothing else, so what is
  # not a fun is the Multi; matching its struct would break its opaque type.
  defp locking(multi, step) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:arca_lock, fn _repo, _changes -> {:ok, take_write_lock!(step)} end)
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
  # commit's fsync all fit inside `@commit_slack_ms`. A caller whose own
  # `timeout:` is under twice that keeps half of it instead, so its attempt
  # still comes. No attempt outlasts the wait: each one's wait inside the
  # driver, and each pause between them, is cut to the time left, so the
  # step has left the driver before the pool can act. A connection closed
  # under a statement still waiting inside the driver can crash the VM, so
  # this is the guarantee the step keeps for any timeout that fits its own
  # statements. Out of the
  # slack before the first attempt — a wait for the connection itself took
  # the time — the step raises at once and touches no lock. The pool's
  # deadline counts from the checkout request, so no fixed margin above the
  # busy timeout could promise this on its own.
  #
  # The turn and the lock share one absolute deadline: time spent waiting
  # for the turn is time the lock wait no longer has.
  defp take_write_lock!({pool_deadline, slack_ms, turn}) do
    config = config()
    deadline_ms = lock_wait_ms(busy_timeout_ms(config), pool_deadline, slack_ms)

    if deadline_ms <= 0,
      do: raise(Arca.Repo.BusyTimeoutError, deadline_ms: 0)

    deadline = System.monotonic_time(:millisecond) + deadline_ms
    take_turn!(turn, deadline, deadline_ms)

    source = config[:migration_source] || "schema_migrations"
    statement = ~s(UPDATE "#{source}" SET version = version WHERE 0)
    query!("PRAGMA busy_timeout = #{@quantum_ms}", [], log: false)

    try do
      attempt_write_lock(statement, deadline, deadline_ms, @quantum_ms)
    after
      query!("PRAGMA busy_timeout = #{busy_timeout_ms(config)}", [], log: false)
    end
  end

  defp take_turn!(nil, _deadline, _deadline_ms), do: :ok

  defp take_turn!(kind, deadline, deadline_ms) do
    if Arca.WriteTurn.enabled?(), do: turn!(kind, deadline, deadline_ms), else: :ok
  end

  defp turn!(kind, deadline, deadline_ms) do
    case Arca.WriteTurn.acquire(kind, deadline) do
      {:ok, _turn} ->
        :ok

      {:error, :timeout} ->
        raise Arca.Repo.BusyTimeoutError, deadline_ms: deadline_ms

      {:error, :capacity} ->
        raise Arca.WriteTurn.CapacityError
    end
  end

  defp lock_wait_ms(busy_ms, nil, _slack_ms), do: busy_ms

  defp lock_wait_ms(busy_ms, pool_deadline, slack_ms) do
    min(busy_ms, pool_deadline - System.monotonic_time(:millisecond) - slack_ms)
  end

  # `quantum` is the connection's busy timeout as this step last set it.
  defp attempt_write_lock(statement, deadline, deadline_ms, quantum) do
    quantum = within_deadline!(quantum, deadline, deadline_ms)

    case query(statement, [], log: false) do
      {:ok, _result} ->
        :acquired

      {:error, %Exqlite.Error{message: message}} when message in @busy ->
        left = time_left!(deadline, deadline_ms)
        Process.sleep(min(Enum.random(@pause_ms), left))
        attempt_write_lock(statement, deadline, deadline_ms, quantum)

      {:error, error} ->
        raise error
    end
  end

  # The attempt's wait inside the driver, cut to the time left when a whole
  # quantum would outlast it, so the attempt has answered before the
  # deadline.
  defp within_deadline!(quantum, deadline, deadline_ms) do
    case time_left!(deadline, deadline_ms) do
      left when left >= quantum ->
        quantum

      left ->
        query!("PRAGMA busy_timeout = #{left}", [], log: false)
        left
    end
  end

  defp time_left!(deadline, deadline_ms) do
    case deadline - System.monotonic_time(:millisecond) do
      left when left > 0 -> left
      _gone -> raise Arca.Repo.BusyTimeoutError, deadline_ms: deadline_ms
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
