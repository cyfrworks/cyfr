# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LiveClaimGateTest do
  @moduledoc """
  Unit tests for the LiveView `on_mount` gate that redirects users without a
  claimed personal namespace to `/claim-namespace`.

  Tests invoke `on_mount/4` directly with a synthetic socket so LiveSocket
  plumbing isn't required. This mirrors the pattern recommended by
  `Phoenix.LiveView` docs for testing on_mount hooks in isolation.
  """
  use ExUnit.Case, async: false

  alias EmissaryWeb.Plugs.PersonalNamespaceCache
  alias PrismWeb.LiveClaimGate

  defp unique_user, do: "gate-test-user-#{System.unique_integer([:positive])}"

  # Synthetic LiveView socket with the minimal assigns the hook touches.
  defp socket_with(assigns), do: %Phoenix.LiveView.Socket{assigns: assigns}

  # PrismWeb.LiveAuth assigns a real %Sanctum.Context{}, which keys its
  # identity as :user_id. A bare %{id: ...} map here once let the gate's
  # never-matching :id clause look correct in tests while it passed everyone
  # through in production.
  defp context_for(user_id) do
    Sanctum.Context.build(
      user_id: user_id,
      permissions: [:*],
      auth_method: :oidc,
      authenticated: true
    )
  end

  setup do
    # Each test uses a unique user_id so the process-global cache can't
    # leak state between cases. The shared SQL sandbox is needed because
    # CredentialStore calls Arca.Repo on cache miss.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  describe "on_mount/4 :require_claim" do
    test "continues when no current_user (deferred to LiveAuth)" do
      socket = socket_with(%{})

      assert {:cont, ^socket} = LiveClaimGate.on_mount(:require_claim, %{}, %{}, socket)
    end

    test "continues when cache reports :hit" do
      user = unique_user()
      registry = Application.get_env(:cyfr, :oci_registry_url, "registry.cyfr.run")

      PersonalNamespaceCache.put_claimed(user, registry)
      socket = socket_with(%{current_user: context_for(user)})

      assert {:cont, _} = LiveClaimGate.on_mount(:require_claim, %{}, %{}, socket)
    end

    test "redirects to /claim-namespace when cache empty and no stored credential" do
      user = unique_user()
      socket = socket_with(%{current_user: context_for(user)})

      {:halt, returned_socket} = LiveClaimGate.on_mount(:require_claim, %{}, %{}, socket)

      # Redirect target is /claim-namespace (possibly with EmissaryWeb URL prefix
      # in prod; either way the path segment is present).
      assert %Phoenix.LiveView.Socket{redirected: {:redirect, %{external: target}}} =
               returned_socket

      assert target =~ "/claim-namespace"
    end

    test "continues when cache empty but CredentialStore has a bare-slug entry" do
      user = unique_user()
      registry = Application.get_env(:cyfr, :oci_registry_url, "registry.cyfr.run")

      # Seed a personal-namespace credential (bare slug = no dot).
      :ok =
        Compendium.Registry.CredentialStore.put(user, registry, "gate-test-alice", %{
          type: :push_token,
          token: "cyfr_pt_fake",
          namespace: "gate-test-alice",
          role: "personal",
          issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          label: "test"
        })

      socket = socket_with(%{current_user: context_for(user)})

      assert {:cont, _} = LiveClaimGate.on_mount(:require_claim, %{}, %{}, socket)
      # Second mount should hit the cache; proves put_claimed was called.
      assert PersonalNamespaceCache.claimed?(user, registry) == :hit
    end

    test "redirects when CredentialStore has ONLY a publisher entry (dotted slug)" do
      user = unique_user()
      registry = Application.get_env(:cyfr, :oci_registry_url, "registry.cyfr.run")

      # Seed a publisher-namespace credential (contains a dot → not personal).
      :ok =
        Compendium.Registry.CredentialStore.put(user, registry, "stripe.example", %{
          type: :push_token,
          token: "cyfr_pt_fake",
          namespace: "stripe.example",
          role: "admin",
          issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          label: "test"
        })

      socket = socket_with(%{current_user: context_for(user)})

      assert {:halt, _} = LiveClaimGate.on_mount(:require_claim, %{}, %{}, socket)
    end
  end
end
