# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.FirstBootTest do
  @moduledoc """
  A first boot on a SQLite file that does not exist yet, as the boot
  migrates it: `Arca.Repo` started on a pool of two connections, then the
  migrator. The repository opens the file through one connection before
  the pool opens its two (`Arca.Repo.init/2`), so no connection of the pool
  changes the file's journal mode, which takes an exclusive lock.

  The contention is made deterministic: another connection of the node
  holds a read transaction on the file from the moment the repository has
  initialized until the migration ends. A pool whose connections had to
  change the journal mode under that reader could open none, and the
  migrator's first request would be dropped from its queue. A file already
  in WAL lets a connection open while another holds the write lock, which
  is what each later start of the repository meets. PostgreSQL has no
  journal mode, so the file runs on SQLite only.
  """

  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3

  @moduletag :sqlite

  setup do
    dir =
      Path.join(
        Path.dirname(Arca.Repo.config()[:database]),
        "first-boot-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: Path.join(dir, "cyfr.db")}
  end

  test "a fresh database migrates while another connection reads it", %{path: path} do
    refute File.exists?(path)
    name = __MODULE__.Fresh
    {:ok, holder} = Agent.start_link(fn -> nil end)
    handler = {__MODULE__, name}

    # The reader is taken as the repository's supervisor initializes,
    # before its pool opens a connection.
    :ok =
      :telemetry.attach(
        handler,
        [:ecto, :repo, :init],
        fn _event, _measurements, %{opts: opts}, _config ->
          if opts[:name] == name do
            {:ok, db} = Sqlite3.open(path)
            :ok = Sqlite3.execute(db, "BEGIN; SELECT * FROM sqlite_master;")
            Agent.update(holder, fn _ -> db end)
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, repo} = start_repo(name, path)

    try do
      assert Agent.get(holder, & &1), "the reader was not taken before the pool opened"
      assert [_ | _] = migrate(name)

      assert %{rows: [["wal"]]} =
               Ecto.Adapters.SQL.query!(name, "PRAGMA journal_mode", [], timeout: 10_000)
    after
      Agent.get(holder, fn db -> Sqlite3.close(db) end)
      Supervisor.stop(repo)
    end
  end

  test "a database in WAL opens while another connection holds its write lock", %{path: path} do
    {:ok, writer} = Sqlite3.open(path)
    :ok = Sqlite3.execute(writer, "PRAGMA journal_mode = wal;")
    :ok = Sqlite3.execute(writer, "BEGIN IMMEDIATE;")

    try do
      name = __MODULE__.Held
      {:ok, repo} = start_repo(name, path)

      try do
        assert %{rows: [[1]]} = Ecto.Adapters.SQL.query!(name, "SELECT 1", [], timeout: 10_000)
      after
        Supervisor.stop(repo)
      end
    after
      Sqlite3.close(writer)
    end
  end

  # The repository as the boot starts it to migrate: the suite's settings
  # on a pool of two, outside the sandbox, on the file at `path`.
  defp start_repo(name, path) do
    Application.fetch_env!(:arca, Arca.Repo)
    |> Keyword.merge(
      name: name,
      database: path,
      pool: DBConnection.ConnectionPool,
      pool_size: 2
    )
    |> Arca.Repo.start_link()
  end

  defp migrate(name) do
    Arca.Repo.put_dynamic_repo(name)

    try do
      Ecto.Migrator.run(Arca.Repo, Arca.Repo.migrations_path(), :up, all: true, log: false)
    after
      Arca.Repo.put_dynamic_repo(Arca.Repo)
    end
  end
end
