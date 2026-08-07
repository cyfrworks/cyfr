# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Mix.Tasks.Cyfr.MigrateProviderCreds do
  @moduledoc """
  Copy OAuth provider client credentials out of the `secrets` table into the
  dedicated provider-credential store, then delete the legacy secret rows.

  Walks every registered component whose manifest declares an `oauth` block,
  resolves each provider's legacy `client_id_secret`/`client_secret_secret`
  names in that component's tenant (cascading the project → org → platform
  scope partitions the way the runtime fallback does), seals a hit into
  `oauth_provider_credentials`, and — with `--apply` — deletes the legacy
  rows so a client secret never has two live copies to rotate.

  Idempotent: providers already present in the store are skipped (their
  legacy rows are still deleted with `--apply`).

  ## Usage

      mix cyfr.migrate_provider_creds          # preview (dry run)
      mix cyfr.migrate_provider_creds --apply  # migrate and delete legacy rows

  """
  use Mix.Task

  import Ecto.Query

  @shortdoc "Move OAuth provider client credentials into their dedicated store"

  @impl Mix.Task
  def run(args) do
    apply? = "--apply" in args

    Mix.Task.run("app.start")

    components =
      Arca.Repo.all(
        from(c in Arca.Schemas.Component,
          select: %{org_id: c.org_id, project_id: c.project_id, manifest: c.manifest}
        )
      )

    oauth_targets =
      components
      |> Enum.flat_map(fn row ->
        manifest = Compendium.Manifest.decode(row.manifest)

        case manifest["oauth"] do
          oauth when is_map(oauth) and map_size(oauth) > 0 ->
            Enum.map(oauth, fn {provider, config} ->
              {row.org_id, row.project_id, provider, config}
            end)

          _ ->
            []
        end
      end)
      |> Enum.uniq_by(fn {org, project, provider, _config} -> {org, project, provider} end)

    Mix.shell().info(
      "Found #{length(oauth_targets)} (tenant, provider) pair(s) with oauth blocks."
    )

    Enum.each(oauth_targets, fn {org, project, provider, config} ->
      legacy = {config["client_id_secret"], config["client_secret_secret"]}
      migrate_one(org, project, provider, legacy, apply?)
    end)

    unless apply? do
      Mix.shell().info("\nDry run - re-run with --apply to migrate and delete legacy rows.")
    end
  end

  defp migrate_one(org, project, provider, {id_name, secret_name} = legacy, apply?) do
    label = "#{org}/#{project} provider=#{provider}"

    # fetch_for_oauth copies a legacy hit forward into the store by itself;
    # the task's job is to force that copy eagerly and then delete legacy.
    case Sanctum.ProviderCredentials.fetch_for_oauth(org, project, provider, legacy) do
      {:ok, _creds} ->
        Mix.shell().info("  #{label}: credentials available (store or legacy copy-forward)")

        if apply? do
          delete_legacy(org, project, [id_name, secret_name])
          Mix.shell().info("  #{label}: legacy secret rows deleted")
        end

      {:error, reason} ->
        Mix.shell().info("  #{label}: nothing to migrate (#{reason})")
    end
  end

  # Revoke grants before deleting: a surviving grant on a missing secret
  # makes resolve_granted_secrets/2 fail closed for the granted component.
  # Goes through the Sanctum.Secrets domain API so partition handling stays
  # symmetric with how the rows were written.
  defp delete_legacy(org, project, names) do
    names = Enum.filter(names, &is_binary/1)

    for scope <- [:project, :org, :platform], name <- names do
      ctx =
        Sanctum.Context.internal(
          user_id: "system:provider_creds_migration",
          org_id: org,
          project_id: project,
          scope: scope,
          permissions: [:secrets_read, :secrets_write]
        )

      case Sanctum.Secrets.list_grants(ctx, name) do
        {:ok, granted_refs} ->
          Enum.each(granted_refs, fn ref ->
            if is_binary(ref), do: Sanctum.Secrets.revoke(ctx, name, ref)
          end)

        _ ->
          :ok
      end

      Sanctum.Secrets.delete(ctx, name)
    end

    :ok
  end
end
