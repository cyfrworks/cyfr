# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Errors do
  @moduledoc """
  Database-adapter-aware error handling for rescue clauses.

  Uses the same `:repo_adapter` compile-env key as `Arca.Repo` to determine
  which driver error modules to include. This centralizes the adapter
  swap point so individual call sites don't need to know about Exqlite vs
  Postgrex.
  """

  # config:compile-runtime-ok — must match what `Arca.Repo` compiled against.
  @adapter Application.compile_env(:arca, :repo_adapter, Ecto.Adapters.SQLite3)

  @doc """
  Returns the list of database error modules for use in rescue clauses:
  the driver's own, and `Arca.Repo.BusyTimeoutError` for a transaction
  that could not take SQLite's write lock in time.

  ## Example

      rescue
        e in Arca.Repo.Errors.db_errors() ->
          handle_db_error(e)
  """
  defmacro db_errors do
    errors =
      case @adapter do
        Ecto.Adapters.Postgres ->
          [
            Ecto.QueryError,
            DBConnection.ConnectionError,
            Postgrex.Error,
            Arca.Repo.BusyTimeoutError
          ]

        _ ->
          [
            Ecto.QueryError,
            DBConnection.ConnectionError,
            Exqlite.Error,
            Arca.Repo.BusyTimeoutError
          ]
      end

    Macro.escape(errors)
  end

  @doc """
  Run `fun`, mapping any database-adapter error to
  `{:error, :database_error}` — the one row-plane spelling of "the store
  could not answer" at a storage entry point. `tag` names the caller in
  the log line.
  """
  @spec with_db_rescue(String.t(), (-> result)) :: result | {:error, :database_error}
        when result: term()
  def with_db_rescue(tag, fun) when is_binary(tag) and is_function(fun, 0) do
    fun.()
  rescue
    e in db_errors() ->
      require Logger
      Logger.error("[#{tag}] database error: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Like `with_db_rescue/2`, but answers `default` instead of
  `{:error, :database_error}` when the store cannot answer.

  Default-returning reads may produce an empty result during an outage.
  Document the effect of that fallback at the call site. Reads governing
  admission, caps, or archival must use `with_db_rescue/2` and refuse.
  """
  @spec with_db_rescue(String.t(), default, (-> result)) :: result | default
        when result: term(), default: term()
  def with_db_rescue(tag, default, fun) when is_binary(tag) and is_function(fun, 0) do
    fun.()
  rescue
    e in db_errors() ->
      require Logger
      Logger.error("[#{tag}] database error: #{Exception.message(e)}")
      default
  end

  @doc """
  Returns true if the exception represents a unique constraint violation.

  Works across both SQLite (`UNIQUE constraint failed`) and Postgres
  (`duplicate key value violates unique constraint`).
  """
  @spec unique_constraint_violation?(Exception.t()) :: boolean()
  def unique_constraint_violation?(exception) do
    message = Exception.message(exception)

    String.contains?(message, "UNIQUE constraint failed") or
      String.contains?(message, "duplicate key value violates unique constraint")
  end
end

defmodule Arca.Repo.BusyTimeoutError do
  @moduledoc """
  A SQLite transaction that could not take the database's one write lock
  before the pool's busy timeout ran out.

  Raised at the transaction's start, before any of the caller's work
  runs, so it rolls back nothing but the attempt. The message names the
  deadline and never the statement.
  """

  defexception [:deadline_ms]

  @impl true
  def message(%__MODULE__{deadline_ms: deadline_ms}),
    do: "the database write lock was not acquired within #{deadline_ms} ms"
end
