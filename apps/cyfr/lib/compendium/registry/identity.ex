# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Registry.Identity do
  @moduledoc """
  Resolves registry identity for the configured OCI registry via cyfr.run's
  push-token model.

  Two hosts are in play; with the default cyfr.run topology they are not the same:

  - `:cyfr, :oci_registry_url` (default `"registry.cyfr.run"`) — the OCI
    Distribution gateway where `/v2/*` push/pull runs. CredentialStore keys
    use this host because tokens were minted for it.
  - `:cyfr, :registry_url` (default `"cyfr.run"`) — the REST API host where
    `/v1/*` endpoints (probe, namespaces, members, tokens) live. This
    module's `confirm_namespace/2` call targets that host.

  Return shape:

      %{
        authenticated: boolean(),
        user_id: String.t() | nil,
        personal_namespace: %{slug: String.t(), last_used_at: String.t()} | nil,
        memberships: [%{slug: String.t(), role: String.t(), last_used_at: String.t()}]
      }

  `authenticated: true` iff the user holds at least one push token for this
  registry (personal + memberships combined). A user with only a personal
  namespace has `memberships: []`. A user who has claimed no personal
  namespace but holds publisher-namespace memberships has
  `personal_namespace: nil` and a non-empty `memberships` list.

  Consumed by `Compendium.MCP.registry.whoami`. Not exposed via
  `Sanctum.MCP.session.whoami` — that action is local-user-only, so the
  auth sliver stays Compendium-free.
  """

  require Logger

  alias Compendium.Registry.CredentialStore

  @whoami_timeout_ms 3_000

  @doc """
  Build the registry identity summary for a context.

  Iterates each stored push token (one per namespace the user belongs to),
  calls `GET /v1/namespaces/{slug}` per token to confirm the namespace still
  exists and collect `last_used_at`, then assembles personal + memberships.
  """
  @spec identity(Sanctum.Context.t()) :: map()
  def identity(%Sanctum.Context{} = ctx) do
    # OCI host keys the CredentialStore (tokens were issued for that host);
    # REST host receives the whoami confirmation call. Distinct in the default
    # cyfr.run topology; some self-hosted deployments collapse them.
    oci_host = Compendium.Registry.canonical_host()
    rest_host = rest_host()

    case list_user_credentials(ctx, oci_host) do
      [] ->
        %{authenticated: false, user_id: ctx.user_id, personal_namespace: nil, memberships: []}

      creds ->
        # Parallelize per-token HTTP confirmation so whoami latency stays
        # bounded by the slowest single call (3s) rather than N×3s. Users
        # with many publisher memberships feel this most — a 10-membership
        # whoami used to serialize up to ~30s of timeouts; now it's ~3s.
        #
        # `max_concurrency: 8` tunes for typical Finch pool size without
        # flooding the cyfr.run REST tier. `ordered: false` lets the stream
        # return as results arrive. `on_timeout: :kill_task` caps stragglers
        # at @whoami_timeout_ms + 500ms grace. `:exit` tuples are dropped —
        # same as the per-call `nil` return for revoked tokens (see
        # confirm_namespace/2 below).
        entries =
          creds
          |> Task.async_stream(&confirm_namespace(rest_host, &1),
            max_concurrency: 8,
            timeout: @whoami_timeout_ms + 500,
            on_timeout: :kill_task,
            ordered: false
          )
          |> Enum.flat_map(fn
            {:ok, nil} -> []
            {:ok, entry} -> [entry]
            {:exit, _} -> []
          end)

        {personal, memberships} = split_personal(entries)

        %{
          authenticated: personal != nil or memberships != [],
          user_id: ctx.user_id,
          personal_namespace: personal,
          memberships: memberships
        }
    end
  rescue
    e in [ArgumentError, MatchError, ErlangError, Jason.DecodeError, CaseClauseError] ->
      Logger.error("[Registry.Identity] identity check failed: #{Exception.message(e)}")
      %{authenticated: false, user_id: ctx.user_id, personal_namespace: nil, memberships: []}
  end

  # ============================================================================
  # Internal
  # ============================================================================

  # Prefer the org's tenant credential; fall back to the user's personal
  # credentials. The same path serves every deployment — a single-operator
  # install resolves to the seeded "local" org and its personal creds.
  defp list_user_credentials(%Sanctum.Context{} = ctx, oci_host) do
    resolve_tenant_credentials(ctx, oci_host)
  end

  defp resolve_local_credentials(%Sanctum.Context{user_id: user_id}, oci_host)
       when is_binary(user_id) and user_id != "" do
    CredentialStore.list_for_user(user_id, oci_host)
  end

  defp resolve_local_credentials(_ctx, _oci_host), do: []

  # Tenant-cred path. Tenant creds are stored in Arca.SecretStorage as JSON
  # with {token, namespace}. Single-cred semantics today; multi-namespace
  # tenant creds are not yet supported. Falls back to personal creds.
  defp resolve_tenant_credentials(%Sanctum.Context{org_id: org_id} = ctx, oci_host) do
    tenant_cred =
      if is_binary(org_id) and org_id != "" do
        case Arca.SecretStorage.get_secret("registry_credentials", "global", org_id) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, %{"token" => token, "namespace" => ns}}
              when is_binary(token) and is_binary(ns) ->
                [
                  %{
                    type: :push_token,
                    token: token,
                    namespace: ns,
                    issued_at: nil,
                    label: "tenant"
                  }
                ]

              _ ->
                []
            end

          {:error, _} ->
            []
        end
      else
        []
      end

    case tenant_cred do
      [] -> resolve_local_credentials(ctx, oci_host)
      _ -> tenant_cred
    end
  end

  # Best-effort per-token probe. Transient errors keep the entry with nil
  # `last_used_at`; 401/403 drops it (token revoked or namespace ownership
  # lost). Uses Finch (shared pool) for consistency with Registry.Client.
  defp confirm_namespace(rest_host, %{token: token, namespace: slug})
       when is_binary(token) and is_binary(slug) do
    url = "https://#{rest_host}/v1/namespaces/#{URI.encode(slug)}"

    headers = [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/json"}
    ]

    req = Finch.build(:get, url, headers)

    case Finch.request(req, Compendium.Finch, receive_timeout: @whoami_timeout_ms) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} when is_map(data) ->
            %{
              slug: slug,
              role: data["role"] || "member",
              last_used_at: data["last_used_at"] || data["verified_at"],
              kind: classify(slug)
            }

          _ ->
            %{slug: slug, role: "member", last_used_at: nil, kind: classify(slug)}
        end

      {:ok, %Finch.Response{status: status}} when status in 401..403 ->
        # Token revoked or namespace ownership lost — drop this entry.
        nil

      _ ->
        # Transient error: keep the entry but mark it with no last_used_at.
        %{slug: slug, role: "member", last_used_at: nil, kind: classify(slug)}
    end
  end

  defp confirm_namespace(_rest_host, _cred), do: nil

  defp classify(slug) do
    if String.contains?(slug, "."), do: :publisher, else: :personal_or_reserved
  end

  defp split_personal(entries) do
    {personal_entries, publisher_entries} =
      Enum.split_with(entries, fn e -> e.kind == :personal_or_reserved end)

    personal =
      case personal_entries do
        [%{slug: slug, last_used_at: last_used_at} | _] ->
          %{slug: slug, last_used_at: last_used_at}

        _ ->
          nil
      end

    memberships =
      publisher_entries
      |> Enum.sort_by(& &1.slug)
      |> Enum.map(fn e ->
        %{slug: e.slug, role: e.role, last_used_at: e.last_used_at}
      end)

    {personal, memberships}
  end

  # REST API host (e.g. "cyfr.run"). Distinct from the OCI gateway host
  # (e.g. "registry.cyfr.run") in the default cyfr.run topology;
  # `Compendium.Application.validate_*!/0` pins both at boot. Delegates to
  # `Compendium.Registry.canonical_rest_host/0` so Identity + Client share
  # one source of truth.
  defp rest_host do
    Compendium.Registry.canonical_rest_host()
  end
end