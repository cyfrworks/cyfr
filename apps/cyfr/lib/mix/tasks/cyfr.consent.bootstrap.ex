# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Mix.Tasks.Cyfr.Consent.Bootstrap do
  @shortdoc "Mint owner profiles and consents mirroring today's effective policy"

  @moduledoc """
  Bootstrap consents for every executable local component in every tenant
  that has components.

  Idempotent; components that already carry an owner profile are skipped.
  See `Sanctum.Consent.Bootstrap` for exactly what a minted consent
  grants.
  """

  use Mix.Task

  import Ecto.Query

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    tenants =
      Arca.Repo.all(
        from c in Arca.Schemas.Component,
          distinct: true,
          select: {c.org_id, c.project_id}
      )

    Enum.each(tenants, fn {org_id, project_id} ->
      ctx = Sanctum.Context.internal(org_id: org_id, project_id: project_id, scope: :project)

      {:ok, result} = Sanctum.Consent.Bootstrap.run(ctx)

      Mix.shell().info(
        "#{org_id}/#{project_id}: minted #{length(result.minted)}, " <>
          "skipped #{length(result.skipped)}"
      )

      Enum.each(result.skipped, fn {ref, reason} ->
        Mix.shell().info("  skipped #{ref}: #{inspect(reason)}")
      end)
    end)
  end
end
