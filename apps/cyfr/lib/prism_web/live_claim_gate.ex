# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LiveClaimGate do
  @moduledoc """
  LiveView on_mount hook that gates dashboard access on personal-namespace
  claim status.

  Runs AFTER `PrismWeb.LiveAuth.:require_auth` (which populates
  `socket.assigns.current_user`). Consults `PersonalNamespaceCache` (30s TTL
  ETS) — on miss, calls `CredentialStore.list_for_user/2` and checks for any
  bare-namespace entry. If absent, redirects the LiveSocket to
  `/claim-namespace` (cross-endpoint; EmissaryWeb serves the gate page).

  Positive-only caching: once a user has claimed, subsequent mounts within
  30s hit the ETS cache. Self-healing across multi-session — no pub/sub
  invalidation needed.
  """

  import Phoenix.LiveView

  alias EmissaryWeb.Plugs.PersonalNamespaceCache

  def on_mount(:require_claim, _params, _session, socket) do
    case socket.assigns[:current_user] do
      %{id: user_id} when is_binary(user_id) and user_id != "" ->
        registry = registry_url()

        case PersonalNamespaceCache.claimed?(user_id, registry) do
          :hit ->
            {:cont, socket}

          :miss ->
            check_credential_store(socket, user_id, registry)
        end

      _ ->
        # No authenticated user — LiveAuth should have caught this. Let the
        # request continue; LiveAuth's own redirect will handle it.
        {:cont, socket}
    end
  end

  defp check_credential_store(socket, user_id, registry) do
    if Compendium.Registry.CredentialStore.has_personal?(user_id, registry) do
      PersonalNamespaceCache.put_claimed(user_id, registry)
      {:cont, socket}
    else
      {:halt, redirect(socket, external: claim_gate_url())}
    end
  end

  defp registry_url, do: Compendium.Registry.canonical_host()

  # The claim-gate page lives under EmissaryWeb, not PrismWeb. Use the
  # EmissaryWeb endpoint url so this works across dev/prod.
  defp claim_gate_url do
    emissary_base = EmissaryWeb.Endpoint.url()
    emissary_base <> "/claim-namespace"
  rescue
    _ -> "/claim-namespace"
  end
end