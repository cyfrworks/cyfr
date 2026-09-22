# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Cluster.Store do
  @moduledoc """
  The one database and the one object store a cell's members share.

  Both are what refusals 1 and 2 of `Cyfr.Cell.refusals/1` insist on, and
  neither is a stand-in: the database is a real Postgres, so
  `Arca.ServerMetaStorage.now!/0` is `clock_timestamp()` and every member
  reads one instant however its own clock has drifted; the object store is
  a real S3 implementation, so an estate written by one member is read by
  the other rather than by a copy of it.

  | Variable | Default |
  |---|---|
  | `CYFR_CLUSTER_DATABASE_URL` | `postgres://cyfr:cyfr@localhost:5432/cyfr_cluster_test` |

  The database is **not** `cyfr_test`. A cluster member holds no sandbox
  connection — it runs the real pool, writes committed rows and keeps
  running between cases — so it must not share a database with a run that
  expects a sandbox to roll its writes back.

  The object store is `Arca.Test.S3Env`'s, under a prefix of this run's
  own so two runs against one bucket never meet.
  """

  @default_url "postgres://cyfr:cyfr@localhost:5432/cyfr_cluster_test"

  @doc "The cluster database's URL."
  @spec database_url() :: String.t()
  def database_url, do: System.get_env("CYFR_CLUSTER_DATABASE_URL", @default_url)

  @doc "The object store every member of this run writes through."
  @spec s3_config() :: keyword()
  def s3_config, do: Arca.Test.S3Env.config(prefix: prefix())

  @doc """
  The prefix this run's estates live under, minted once so a failed run
  leaves nothing a later one will read.
  """
  @spec prefix() :: String.t()
  def prefix do
    case :persistent_term.get({__MODULE__, :prefix}, nil) do
      nil ->
        minted = "cluster-#{System.system_time(:millisecond)}"
        :persistent_term.put({__MODULE__, :prefix}, minted)
        minted

      minted ->
        minted
    end
  end

  @doc """
  Refuse the run before a member is started if either store is missing,
  naming which and how to get it. A cell that cannot form is not a
  failure worth debugging through a member's boot log.
  """
  @spec ready!() :: :ok
  def ready! do
    database!()
    bucket!()
    seed_tree!()
    :ok
  end

  defp database! do
    {:ok, _started} = Application.ensure_all_started(:postgrex)
    {:ok, connection} = Postgrex.start_link(url_options() ++ [pool_size: 1])

    try do
      {:ok, _} = Postgrex.query(connection, "SELECT 1", [])

      case Postgrex.query(connection, "SELECT value FROM server_meta WHERE key = 'schema_fingerprint'", []) do
        {:ok, %{rows: [[_fingerprint]]}} ->
          :ok

        _unmigrated ->
          raise """
          the cluster database #{database_url()} has no schema.

          Create and migrate it before the suite:

              CYFR_DATABASE=postgres CYFR_DATABASE_URL=#{database_url()} mix ecto.create
              CYFR_DATABASE=postgres CYFR_DATABASE_URL=#{database_url()} mix ecto.migrate
          """
      end
    after
      GenServer.stop(connection)
    end
  rescue
    e in DBConnection.ConnectionError ->
      reraise """
              the cluster database #{database_url()} could not be reached (#{Exception.message(e)}).

              The two-node suite needs a Postgres of its own: a member holds no
              sandbox connection, so it must not share a database with a run that
              expects one. Set CYFR_CLUSTER_DATABASE_URL, or start one at the
              default address.
              """,
              __STACKTRACE__
  end

  defp bucket! do
    previous = Arca.Test.S3Env.configure!(prefix: prefix())

    try do
      Arca.Test.S3Env.create_bucket!()
    rescue
      e ->
        reraise """
                the object store could not be reached (#{Exception.message(e)}).

                CYFR_CLUSTER=1 refuses local storage, so the two-node suite needs a
                real one. The `s3-minio` job's container serves it; start the same
                image, or point CYFR_TEST_S3_ENDPOINT at another.
                """,
                __STACKTRACE__
    after
      Arca.Test.S3Env.restore(previous)
    end
  end

  # Seed media is pinned to the Local adapter whatever the storage adapter
  # is (`Arca.Storage.seed_roots/0`), so it stays a directory on each
  # member's own filesystem. The members of this suite share a machine, so
  # they share the one the suite's own helper laid.
  defp seed_tree! do
    seed = Application.fetch_env!(:arca, :seed_path)

    unless File.dir?(Path.join(seed, "aqua")) do
      raise "the seed tree at #{seed} has no aqua/: the suite's test_helper lays it"
    end

    :ok
  end

  @doc "Postgrex options for the cluster database."
  @spec url_options() :: keyword()
  def url_options, do: Keyword.new(Ecto.Repo.Supervisor.parse_url(database_url()))
end
