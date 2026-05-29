# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Mix.Tasks.Cyfr.SeedProjectComponents do
  @moduledoc """
  Seed an existing project with the bundled component set.

  New projects are seeded automatically on creation. Use this task to seed a
  project that predates seeding, or to re-seed after the bundle changes. It is
  idempotent.

  ## Usage

      mix cyfr.seed_project_components --org acme --project proj_x
      mix cyfr.seed_project_components --project proj_x   # org defaults to "local"

  """
  use Mix.Task

  @shortdoc "Seed an existing project with bundled components"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [org: :string, project: :string])

    org = opts[:org] || Arca.Tenant.local_org()

    project =
      opts[:project] ||
        Mix.raise("--project is required (the project_id to seed)")

    Mix.Task.run("app.start")

    case Compendium.ProjectSeeder.seed(%{org_id: org, project_id: project}) do
      :ok ->
        Mix.shell().info("Seeded bundled components into #{org}/#{project}.")

      {:ok, :is_seed_source} ->
        Mix.shell().info("#{org}/#{project} is the bundle source — nothing to seed.")

      {:error, reason} ->
        Mix.shell().error("Seeding failed: #{inspect(reason)}")
    end
  end
end
