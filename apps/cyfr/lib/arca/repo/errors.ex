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

  @adapter Application.compile_env(:cyfr, :repo_adapter, Ecto.Adapters.SQLite3)

  @doc """
  Returns the list of database error modules for use in rescue clauses.

  ## Example

      rescue
        e in Arca.Repo.Errors.db_errors() ->
          handle_db_error(e)

  """
  defmacro db_errors do
    errors =
      case @adapter do
        Ecto.Adapters.Postgres ->
          [Ecto.QueryError, DBConnection.ConnectionError, Postgrex.Error]

        _ ->
          [Ecto.QueryError, DBConnection.ConnectionError, Exqlite.Error]
      end

    Macro.escape(errors)
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