# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Cluster.Observer do
  @moduledoc """
  What the control node sees of the cell, read through a Postgrex
  connection of its own.

  Every assertion about ownership is made against the rows, from outside
  both members. That is the point: "the holder is not on my node" is never
  evidence, so a case that asked a member what it believed would be
  asking a party to the race. It also keeps every assertion available
  when both members are dead, which is exactly when a case about process
  death has something to say.

  The connection is deliberately raw SQL rather than `Arca.Repo`: the
  control node's repo is the suite's own, pooled through the Ecto sandbox
  and pointed at whatever database the single-node run uses. An observer
  that shared it would roll back with a case, or worse, would not.
  """

  @name __MODULE__

  # The cell's clock as the lease columns hold it: UTC, without a zone.
  @now "timezone('UTC', clock_timestamp())"

  @doc "Open the observer's connection, once for the run."
  @spec start!() :: pid()
  def start! do
    {:ok, _started} = Application.ensure_all_started(:postgrex)

    case Process.whereis(@name) do
      nil ->
        {:ok, pid} =
          Postgrex.start_link(Cyfr.Cluster.Store.url_options() ++ [name: @name, pool_size: 2])

        pid

      pid ->
        pid
    end
  end

  @doc "Run `sql` and answer its rows as lists."
  @spec query!(String.t(), [term()]) :: [[term()]]
  def query!(sql, params \\ []) do
    %Postgrex.Result{rows: rows} = Postgrex.query!(@name, sql, params)
    rows
  end

  @doc "Run `sql` and answer its rows as maps keyed by column name."
  @spec rows!(String.t(), [term()]) :: [map()]
  def rows!(sql, params \\ []) do
    %Postgrex.Result{rows: rows, columns: columns} = Postgrex.query!(@name, sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end

  @doc "One row, or nil."
  @spec row(String.t(), [term()]) :: map() | nil
  def row(sql, params \\ []), do: sql |> rows!(params) |> List.first()

  @doc """
  The database's own clock — the instant every member's lease is judged
  against.

  Read as `timezone('UTC', clock_timestamp())`, which is what the lease
  columns hold: they are `timestamp without time zone` carrying UTC, so a
  bare `clock_timestamp()` would be compared against them through the
  session's own zone and make every lease read a day out.
  """
  @spec now() :: NaiveDateTime.t()
  def now do
    [[now]] = query!("SELECT " <> @now)
    now
  end

  # ---------------------------------------------------------------------------
  # The cell
  # ---------------------------------------------------------------------------

  @doc "Every `cell_leases` row, newest slot first."
  @spec slots() :: [map()]
  def slots, do: rows!("SELECT * FROM cell_leases ORDER BY node")

  @doc "One member's slot row."
  @spec slot(node() | String.t()) :: map() | nil
  def slot(node), do: row("SELECT * FROM cell_leases WHERE node = $1", [to_string(node)])

  @doc """
  The cell's live roster as the database reads it right now: the node
  names whose lease still stands on `clock_timestamp()`.
  """
  @spec roster() :: [String.t()]
  def roster do
    "SELECT node FROM cell_leases WHERE lease_until > #{@now} ORDER BY node"
    |> query!()
    |> Enum.map(&hd/1)
  end

  @doc "Whether `node`'s slot is takeable — its lease has run out on the cell's clock."
  @spec takeable?(node() | String.t()) :: boolean()
  def takeable?(node) do
    case row(
           "SELECT lease_until <= #{@now} AS takeable FROM cell_leases WHERE node = $1",
           [to_string(node)]
         ) do
      %{"takeable" => takeable} -> takeable
      nil -> false
    end
  end

  # ---------------------------------------------------------------------------
  # The claimed jobs
  # ---------------------------------------------------------------------------

  @doc "One `job_claims` row."
  @spec claim(String.t(), String.t()) :: map() | nil
  def claim(kind, key),
    do: row("SELECT * FROM job_claims WHERE kind = $1 AND key = $2", [kind, key])

  @doc "Every claim of a kind."
  @spec claims(String.t()) :: [map()]
  def claims(kind), do: rows!("SELECT * FROM job_claims WHERE kind = $1 ORDER BY key", [kind])

  @doc """
  The fence of `(kind, key)`, or 0 where no row exists. A case that wants
  to say a member "did not write at all" reads this before and after: the
  fence rises on every write, so an unchanged fence is the evidence.
  """
  @spec fence(String.t(), String.t()) :: non_neg_integer()
  def fence(kind, key) do
    case claim(kind, key) do
      nil -> 0
      %{"fence" => fence} -> fence
    end
  end

  @doc "Forget a claim entirely, so a case starts from a subject nobody has ever held."
  @spec forget_claim(String.t(), String.t()) :: :ok
  def forget_claim(kind, key) do
    Postgrex.query!(@name, "DELETE FROM job_claims WHERE kind = $1 AND key = $2", [kind, key])
    :ok
  end
end
