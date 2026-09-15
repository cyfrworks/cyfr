# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SchemaFingerprint do
  @moduledoc """
  Which schema this database was built from.

  The schema is one baseline migration that every schema change edits, so
  a database created from an earlier version of it still records the
  baseline as applied and would otherwise run stale. The fingerprint is the
  digest of the migration sources this release carries. The baseline
  records it in `server_meta` as it builds the schema; `verify!/0` compares
  that record with this release's and refuses a database built from any
  other version. There is no upgrade path: the refusal names the database
  to recreate.

  Verified on every boot, whether the boot migrated or an operator did
  (`Check`, with the tenant-table roster), by `Cyfr.Release.migrate/0`,
  and by the test suite before it touches the database.
  """

  @key "schema_fingerprint"
  @migrations_dir Path.expand("../../priv/repo/migrations", __DIR__)
  # arca:bypass-ok=C — compile-time read of the tracked migration sources.
  @migrations @migrations_dir |> Path.join("*.exs") |> Path.wildcard() |> Enum.sort()

  for path <- @migrations, do: @external_resource(path)

  # arca:bypass-ok=C — compile-time read of the tracked migration sources.
  @fingerprint @migrations
               |> Enum.map_join(fn path -> Path.basename(path) <> "\n" <> File.read!(path) end)
               |> Cyfr.Digest.sha256_hex()

  @doc "The `server_meta` key the fingerprint is recorded under."
  @spec key() :: String.t()
  def key, do: @key

  @doc "The fingerprint of the migrations this release carries."
  @spec current() :: String.t()
  def current, do: @fingerprint

  @doc """
  Compare the database's recorded fingerprint with this release's.

  `:ok` when they agree; `{:error, message}` when the database was built
  from a different schema, records none, or cannot be read. The message
  is the refusal.
  """
  @spec verify() :: :ok | {:error, String.t()}
  def verify do
    case Arca.ServerMetaStorage.get(@key) do
      {:ok, @fingerprint} -> :ok
      {:ok, recorded} -> {:error, refusal("was built from a different schema (#{recorded})")}
      {:error, :not_found} -> {:error, refusal("records no schema fingerprint")}
      {:error, reason} -> {:error, refusal("could not be read (#{inspect(reason)})")}
    end
  end

  @doc "`verify/0`, raising the refusal."
  @spec verify!() :: :ok
  def verify! do
    case verify() do
      :ok -> :ok
      {:error, message} -> raise message
    end
  end

  defmodule Check do
    @moduledoc false
    # The boot step: the schema fingerprint, then the tenant-table roster
    # against that schema, then `:ignore` — the supervisor proceeds only
    # once both hold, and no process lingers.
    use GenServer

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts) do
      Arca.SchemaFingerprint.verify!()
      Arca.TenantTables.verify_roster!()
      :ignore
    end
  end

  defp refusal(what) do
    database = Application.get_env(:cyfr, Arca.Repo, [])[:database] || "the database"

    "[Arca] FATAL: #{database} #{what}; this release's schema is #{@fingerprint}. " <>
      "There is no upgrade path. Delete the database (the SQLite file and its -wal/-shm " <>
      "siblings, or DROP DATABASE on Postgres) and restart so it is created fresh."
  end
end
