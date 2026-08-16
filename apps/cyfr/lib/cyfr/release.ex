# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Release do
  @moduledoc """
  Release tasks — the operator's hands on the database when the server is
  not the one to touch it.

  By default the server migrates on boot (`CYFR_AUTO_MIGRATE=true`); one node
  fronting one database wants exactly that. Several nodes sharing a
  Postgres, or an operator who wants the schema step in their own hands,
  set `CYFR_AUTO_MIGRATE=false` and run these from the release:

      bin/cyfr eval "Cyfr.Release.migrate()"
      bin/cyfr eval "Cyfr.Release.rollback(Arca.Repo, 20260815000000)"

  Both start only what a migration needs (no endpoint, no supervisors) and
  stop it again.
  """

  @app :cyfr

  @doc "Run every pending migration."
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Roll `repo` back to `version` (the migration's timestamp)."
  @spec rollback(module(), pos_integer()) :: :ok
  def rollback(repo, version) when is_integer(version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  @doc "The migrations the repo has not run yet — `[]` when the schema is current."
  @spec pending() :: [{integer(), String.t()}]
  def pending do
    load_app()

    Enum.flat_map(repos(), fn repo ->
      {:ok, pending, _} =
        Ecto.Migrator.with_repo(repo, fn r ->
          r
          |> Ecto.Migrator.migrations()
          |> Enum.filter(fn {status, _version, _name} -> status == :down end)
          |> Enum.map(fn {_status, version, name} -> {version, name} end)
        end)

      pending
    end)
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.ensure_loaded(@app)
    Application.ensure_all_started(:ssl)
  end
end
