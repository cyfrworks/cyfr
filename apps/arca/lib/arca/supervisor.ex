# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Supervisor do
  @moduledoc false

  use Application

  require Logger
  require Arca.Repo.Errors

  @impl true
  def start(_type, _args) do
    # Everything below runs before the pool, in this order: the directory
    # the database file needs, a writability probe that says what a Docker
    # bind mount got wrong, and the migration — DDL on a temporary pool of
    # its own, so no connection of the real pool is held while the schema
    # moves.
    ensure_db_directory!()
    maybe_migrate_before_pool()

    children = [
      Arca.Repo,
      # The write-behind for bookkeeping rows (allowed policy lines, MCP
      # log completions, vault last-used); right after the repo so it
      # drains before the repo goes down.
      Arca.RecordSink,
      # The shared cache table's one owner. A crash here flushes the
      # table, harmlessly for a read-through cache — but the catalogues
      # written into it are rebuilt by their own owners, which watch this
      # process (`Arca.Cache.monitor_owner/0`).
      Arca.Cache.Sweeper
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: __MODULE__,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  defp ensure_db_directory! do
    config = Application.get_env(:arca, Arca.Repo, [])

    if db_path = config[:database] do
      # arca:bypass-ok=B — pre-Arca bootstrap; runs before Arca.Repo starts.
      # SQLite-only path; Postgres builds skip this branch (db_path is nil).
      db_path |> Path.dirname() |> File.mkdir_p!()
    end
  end

  # Run migrations before the connection pool starts to avoid concurrent
  # DDL and database-lock errors. CYFR_AUTO_MIGRATE=false leaves migration
  # to the operator via Cyfr.Release.migrate/0; either way the boot's
  # database checks run once the pool is up.
  defp maybe_migrate_before_pool do
    if Application.get_env(:arca, :auto_migrate, true) do
      config = Application.get_env(:arca, Arca.Repo, [])
      verify_db_writable!(config[:database])
      # A temporary repo just for migrations, of two connections: on
      # Postgres the migrator holds its lock on one and migrates on the
      # other, and refuses a pool of one.
      {:ok, repo_pid} = Arca.Repo.start_link(Keyword.put(config, :pool_size, 2))
      Ecto.Migrator.run(Arca.Repo, Arca.Repo.migrations_path(), :up, all: true)
      configure_database()
      # Stop the temporary repo so the supervisor can start the real one
      Supervisor.stop(repo_pid)
    end
  end

  defp verify_db_writable!(nil), do: :ok

  defp verify_db_writable!(path) do
    dir = Path.dirname(path)
    test_file = Path.join(dir, ".cyfr_write_test")

    # arca:bypass-ok=B — pre-Arca bootstrap probe used to surface friendly
    # Docker UID errors before the Repo pool tries to open the DB.
    case File.touch(test_file) do
      :ok ->
        File.rm(test_file)

      {:error, reason} ->
        {uid, 0} = System.cmd("id", ["-u"])
        uid = String.trim(uid)

        raise """
        [Arca] Cannot write to database directory: #{dir} (#{reason})

        If running in Docker with bind mounts (e.g. ./data:/app/data),
        the host directory must be writable by the container user (UID #{uid}).

        Fix: on the host, run:
          sudo chown -R #{uid} #{dir}
        """
    end
  end

  defp configure_database do
    case Arca.Repo.adapter() do
      Ecto.Adapters.SQLite3 ->
        Arca.Repo.query!("PRAGMA journal_mode=WAL")
        Arca.Repo.query!("PRAGMA busy_timeout=#{Arca.Repo.busy_timeout_ms()}")

      _ ->
        :ok
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.warning("[Arca] Database configuration failed: #{Exception.message(e)}")
      :ok
  end
end
