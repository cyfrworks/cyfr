# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# Arca's own configuration, read by a build that holds the contracts and
# Arca alone. An umbrella build reads the root application's instead,
# which declares the same keys — this file is what makes the persistence
# layer bootable and testable without anything above it.
import Config

# The one CYFR_DATABASE parse, shared with the umbrella root: Ecto binds
# its adapter at compile time, so the choice cannot be made at runtime and
# must not be spelled twice.
Code.require_file("../../../config/database_choice.exs", __DIR__)

config :arca, ecto_repos: [Arca.Repo]

case Cyfr.ConfigEnv.DatabaseChoice.choice!() do
  :sqlite ->
    config :arca, :repo_adapter, Ecto.Adapters.SQLite3

    # Every transaction takes the write lock at BEGIN. A deferred
    # transaction that reads and then writes fails with
    # SQLITE_BUSY_SNAPSHOT when another write committed in between, which
    # would surface as a lost write.
    config :arca, Arca.Repo,
      database: Path.expand("data/arca.db"),
      pool_size: 20,
      journal_mode: :wal,
      busy_timeout: 5_000,
      default_transaction_mode: :immediate

  :postgres ->
    config :arca, :repo_adapter, Ecto.Adapters.Postgres
    config :arca, Arca.Repo, []
end

# The filesystem adapter over two sibling roots: all tenant storage under
# `base_path`, and the shipped seed tree, read in place through the
# overlay, under `seed_path`.
config :arca,
  storage_adapter: Arca.Adapters.Local,
  base_path: Path.expand("data"),
  seed_path: Path.expand("seed")

# Recursive file and byte ceilings for public-profile guest writes.
config :arca, :public_storage_quota, %{max_bytes: 26_214_400, max_files: 200}

# Concurrent object reads in the shared subtree dump
# (`Arca.Storage.read_subtree_via/4`) — bounded so a wide tree cannot open
# unbounded connections on the object-store path.
config :arca, :read_subtree_concurrency, 10

# The shared-cache sweeper's budgets: raw binaries held (bytes) and
# compiled components pinned (count).
config :arca, :cache_max_binary_bytes, 256 * 1024 * 1024
config :arca, :cache_max_compiled_components, 32

if config_env() == :test do
  # A sandboxed pool over a database keyed by checkout, out of the
  # repository's own tree: a run that dies mid-suite must not leave a
  # database that poisons the next one inside the working tree.
  case Cyfr.ConfigEnv.DatabaseChoice.choice!() do
    :sqlite ->
      config :arca, Arca.Repo,
        database:
          Path.join([
            System.tmp_dir!(),
            "arca_test_db_#{:erlang.phash2(Path.expand("."))}",
            "test.db"
          ]),
        pool: Ecto.Adapters.SQL.Sandbox,
        pool_size: 20,
        ownership_timeout: 60_000,
        queue_target: 500,
        queue_interval: 5_000,
        journal_mode: :wal,
        busy_timeout: 20_000

    :postgres ->
      config :arca, Arca.Repo,
        url:
          System.get_env("CYFR_DATABASE_URL") ||
            "postgres://cyfr:cyfr@localhost:5432/arca_test",
        pool: Ecto.Adapters.SQL.Sandbox,
        pool_size: 20,
        ownership_timeout: 60_000,
        queue_target: 500,
        queue_interval: 5_000
  end

  # The mix alias migrates; the boot must not race it.
  config :arca, auto_migrate: false

  # Throwaway sibling roots, the topology dev and prod use.
  test_run = "arca_test_#{System.system_time(:millisecond)}"

  config :arca,
    base_path: Path.join(System.tmp_dir!(), "#{test_run}_data"),
    seed_path: Path.join(System.tmp_dir!(), "#{test_run}_seed")

  # Bookkeeping rows are written in the caller: the sandbox connection is
  # the test's, and every assertion reads the row right after the call.
  config :arca, record_sink_inline: true

  config :logger, level: :warning
end
