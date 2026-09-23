# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ServerMetaStorage do
  @moduledoc """
  The server's own facts, one row per key (`Arca.Schemas.ServerMeta`), and
  the clock every lease in this database is compared against.

  No tenant and no cache: every reader wants the row as it is now, and
  the writers that matter — the schema and keyring fingerprints at boot —
  need the write to be conditional. `put_new/2` records a fact only if
  nobody has; `compare_and_put/3` replaces it only if it still reads what
  the caller saw. Both are one statement, so two boots racing the same row
  cannot both believe they wrote it.

  ## The lease clock

  `now!/0` is the one clock a lease decision in this cell is taken on.
  Every member of a cell reads the same instant from it, so a member whose
  own clock has drifted cannot decide that a peer's live lease has run out,
  nor keep believing in its own after it has. Members' local clocks are for
  bounded local timers — how long a node waits before asking again, how
  long it goes on believing an answer it already has — and for nothing that
  decides who holds a row.
  """

  import Ecto.Query

  alias Arca.Schemas.ServerMeta

  # config:compile-runtime-ok — must match what `Arca.Repo` compiled
  # against, exactly as `Arca.ProvisioningClaims` and `Arca.TenantTables` do.
  @adapter Application.compile_env(:arca, :repo_adapter, Ecto.Adapters.SQLite3)

  @doc "The value under `key`, or `{:error, :not_found}`."
  @spec get(String.t()) :: {:ok, String.t()} | {:error, :not_found | :database_error}
  def get(key) when is_binary(key) do
    Arca.Repo.Errors.with_db_rescue("Arca.ServerMetaStorage.get", fn ->
      case Arca.Repo.get(ServerMeta, key) do
        nil -> {:error, :not_found}
        %ServerMeta{value: value} -> {:ok, value}
      end
    end)
    |> Arca.Data.project()
  end

  @doc "Record `value` under `key` only if no row exists yet."
  @spec put_new(String.t(), String.t()) :: {:ok, :recorded} | {:error, :exists | :database_error}
  def put_new(key, value) when is_binary(key) and is_binary(value) do
    Arca.Repo.Errors.with_db_rescue("Arca.ServerMetaStorage.put_new", fn ->
      row = %{key: key, value: value, updated_at: DateTime.utc_now()}

      case Arca.Repo.insert_all(ServerMeta, [row], on_conflict: :nothing) do
        {1, _} -> {:ok, :recorded}
        {0, _} -> {:error, :exists}
      end
    end)
    |> Arca.Data.project()
  end

  @doc "Replace the value under `key` only if it still reads `expected`."
  @spec compare_and_put(String.t(), String.t(), String.t()) ::
          :ok | {:error, :stale | :database_error}
  def compare_and_put(key, expected, value)
      when is_binary(key) and is_binary(expected) and is_binary(value) do
    Arca.Repo.Errors.with_db_rescue("Arca.ServerMetaStorage.compare_and_put", fn ->
      now = DateTime.utc_now()

      {count, _} =
        from(m in ServerMeta, where: m.key == ^key and m.value == ^expected)
        |> Arca.Repo.update_all(set: [value: value, updated_at: now])

      if count == 1, do: :ok, else: {:error, :stale}
    end)
    |> Arca.Data.project()
  end

  @doc """
  The cell's lease clock: the instant every member agrees on.

  Postgres answers its own `clock_timestamp()` — the wall clock, where
  `now()` stands still for the length of a transaction — so every member
  sharing the database reads one clock however its own has drifted. SQLite
  has no server and one writer, so the BEAM's clock is the database's and
  the answer costs nothing.

  Raises when the store cannot answer, so the caller's transaction rolls
  back and its `Arca.Repo.Errors.with_db_rescue/2` reports the refusal: a
  lease decision taken on a clock that could not be read is the one thing
  that must not happen quietly.
  """
  @spec now!() :: DateTime.t()
  if @adapter == Ecto.Adapters.Postgres do
    # arca:unscoped-ok reads the database server's clock; no table, no tenant.
    # arca:db-raise-ok raising IS the contract, see the doc above.
    def now! do
      %{rows: [[now]]} = Arca.Repo.query!("SELECT clock_timestamp()")
      now
    end
  else
    def now!, do: DateTime.utc_now()
  end
end
