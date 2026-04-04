defmodule Arca.TinctureData.DB do
  @moduledoc """
  SQLite connection management for tincture sandbox databases.

  Uses `Exqlite.Sqlite3` directly (no Ecto, no pool). Connections are
  opened and closed per operation — tincture DB operations are infrequent
  (writes from formula executions, reads from query endpoints with caching).
  WAL mode handles concurrency.
  """

  @busy_timeout_ms 5_000
  @default_query_timeout_ms 2_000
  @default_max_rows 1_000
  @max_db_size_bytes 50 * 1024 * 1024

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Open a SQLite connection, call `fun`, and ensure it is closed.

  Mode `:readonly` opens with SQLITE_OPEN_READONLY (kernel-level write rejection).
  Mode `:readwrite` opens with full access.
  """
  @spec with_connection(String.t(), :readwrite | :readonly, (reference() -> term())) ::
          {:ok, term()} | {:error, term()}
  def with_connection(db_path, mode \\ :readwrite, fun) do
    flags = open_flags(mode)

    case Exqlite.Sqlite3.open(db_path, flags) do
      {:ok, conn} ->
        try do
          configure_pragmas(conn, mode)
          result = fun.(conn)
          {:ok, result}
        rescue
          e -> {:error, Exception.message(e)}
        after
          Exqlite.Sqlite3.close(conn)
        end

      {:error, reason} ->
        {:error, "failed to open database: #{inspect(reason)}"}
    end
  end

  @doc """
  Execute a SQL statement with no result set (DDL, DML).
  """
  @spec execute(reference(), String.t()) :: :ok | {:error, term()}
  def execute(conn, sql) do
    case Exqlite.Sqlite3.execute(conn, sql) do
      :ok -> :ok
      {:error, reason} -> {:error, "execute failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Execute a parameterized SQL statement with no result set.
  """
  @spec execute(reference(), String.t(), [term()]) :: :ok | {:error, term()}
  def execute(conn, sql, params) do
    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        try do
          with :ok <- Exqlite.Sqlite3.bind(stmt, params) do
            step_until_done(conn, stmt)
          else
            {:error, reason} -> {:error, "execute failed: #{inspect(reason)}"}
          end
        after
          Exqlite.Sqlite3.release(conn, stmt)
        end

      {:error, reason} ->
        {:error, "execute failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Execute a query and return results. Enforces max row count.
  """
  @spec query(reference(), String.t(), [term()]) ::
          {:ok, %{columns: [String.t()], rows: [[term()]]}} | {:error, term()}
  def query(conn, sql, params \\ []) do
    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        try do
          with :ok <- Exqlite.Sqlite3.bind(stmt, params),
               {:ok, columns} <- Exqlite.Sqlite3.columns(conn, stmt) do
            collect_rows(conn, stmt, columns)
          else
            {:error, reason} -> {:error, "query failed: #{inspect(reason)}"}
          end
        after
          Exqlite.Sqlite3.release(conn, stmt)
        end

      {:error, reason} ->
        {:error, "query failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Execute a function inside a transaction (BEGIN IMMEDIATE / COMMIT / ROLLBACK).
  """
  @spec transaction(reference(), (reference() -> term())) :: {:ok, term()} | {:error, term()}
  def transaction(conn, fun) do
    with :ok <- execute(conn, "BEGIN IMMEDIATE") do
      try do
        result = fun.(conn)
        :ok = execute(conn, "COMMIT")
        {:ok, result}
      rescue
        e ->
          execute(conn, "ROLLBACK")
          {:error, Exception.message(e)}
      catch
        kind, reason ->
          execute(conn, "ROLLBACK")
          {:error, "transaction failed: #{inspect({kind, reason})}"}
      end
    end
  end

  @doc """
  Resolve the data.db path for a tincture.

  Uses ComponentPath to build the version directory path and appends "data.db".
  The `version_dir` is resolved by looking up the tincture in the registry.
  """
  @spec db_path(String.t()) :: String.t()
  def db_path(version_dir) do
    Path.join(version_dir, "data.db")
  end

  @doc """
  Check if a database file exceeds the maximum size limit.
  """
  @spec check_db_size(String.t()) :: :ok | {:error, String.t()}
  def check_db_size(db_path) do
    max_mb = div(@max_db_size_bytes, 1024 * 1024)

    case File.stat(db_path) do
      {:ok, %{size: size}} when size > @max_db_size_bytes ->
        {:error, "database size (#{div(size, 1024 * 1024)}MB) exceeds limit (#{max_mb}MB)"}

      {:ok, _} ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, "cannot stat database: #{inspect(reason)}"}
    end
  end

  @doc "Maximum database size in bytes."
  def max_db_size_bytes, do: @max_db_size_bytes

  @doc "Default query timeout in milliseconds."
  def default_query_timeout_ms, do: @default_query_timeout_ms

  @doc "Default maximum rows returned by a query."
  def default_max_rows, do: @default_max_rows

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp open_flags(:readonly), do: [:readonly]
  defp open_flags(:readwrite), do: [:readwrite, :create]

  defp configure_pragmas(conn, mode) do
    Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
    Exqlite.Sqlite3.execute(conn, "PRAGMA busy_timeout=#{@busy_timeout_ms}")
    Exqlite.Sqlite3.execute(conn, "PRAGMA foreign_keys=ON")

    if mode == :readonly do
      Exqlite.Sqlite3.execute(conn, "PRAGMA query_only=ON")
    end
  end

  defp step_until_done(conn, stmt) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      :done -> :ok
      {:row, _row} -> step_until_done(conn, stmt)
      {:error, reason} -> {:error, "step failed: #{inspect(reason)}"}
    end
  end

  defp collect_rows(conn, stmt, columns) do
    deadline = System.monotonic_time(:millisecond) + @default_query_timeout_ms
    collect_rows(conn, stmt, columns, [], 0, deadline)
  end

  defp collect_rows(_conn, _stmt, columns, rows, count, _deadline)
       when count >= @default_max_rows do
    {:ok, %{columns: columns, rows: Enum.reverse(rows), truncated: true}}
  end

  defp collect_rows(conn, stmt, columns, rows, count, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, "query timeout exceeded (#{@default_query_timeout_ms}ms)"}
    else
      case Exqlite.Sqlite3.step(conn, stmt) do
        {:row, row} ->
          collect_rows(conn, stmt, columns, [row | rows], count + 1, deadline)

        :done ->
          {:ok, %{columns: columns, rows: Enum.reverse(rows)}}

        {:error, reason} ->
          {:error, "query step failed: #{inspect(reason)}"}
      end
    end
  end
end
