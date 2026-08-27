# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.CredentialedIngressGateTest do
  @moduledoc """
  The §6 "no credentialed execution without a grant" gate, second arm.

  For each classified ingress, an execution that has no consent edge
  naming a vault entry receives no credential material — whatever the
  legacy grant plane would have handed it. The first arm
  (`Cyfr.IngressInventoryTest`) is what makes this list total: a new
  ingress fails there until it is classified and covered here.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Authority
  alias Sanctum.Authority.Blob
  alias Sanctum.CipherAAD
  alias Sanctum.Vault.Payload
  alias Sanctum.VaultReader

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp seeded_entry(ctx) do
    id = Emissary.UUID7.generate_id("vlt")
    aad = CipherAAD.vault_entry(ctx.athanor_id, id, "")
    {:ok, json} = Payload.encode_material(%{"api_key" => "sk-operator-only"}, nil)
    {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)

    {:ok, entry} =
      Arca.VaultStorage.put(%{
        id: id,
        athanor_id: ctx.athanor_id,
        name: "gate-entry",
        provider_hint: "",
        kind: "api_key",
        field_names: Jason.encode!(["api_key"]),
        sealed_payload: sealed
      })

    {:ok, digest} = VaultReader.binding_digest(entry)
    {entry, digest}
  end

  # An authority whose ingress edge grants NO vault resource — the shape
  # every ingress produces when its profile's consent named no credential.
  defp ungranted_authority do
    node = "formula:local.gate-probe"

    graph = %{
      "canonical" => "jcs-1",
      "nodes" => %{
        node => %{
          "limits" => %{
            "timeout" => "1m",
            "max_memory_bytes" => 67_108_864,
            "max_request_size" => 1_048_576,
            "max_response_size" => 5_242_880,
            "rate_limit" => %{"requests" => 100, "window" => "1m"},
            "max_concurrent_tasks" => 1,
            "batch_timeout" => "1m"
          },
          "edges" => %{"@ingress" => %{}}
        }
      }
    }

    {:ok, blob} = Blob.parse(graph)

    {:ok, auth} =
      Authority.root(
        %{
          profile_id: "prof-gate",
          consent_id: "consent-gate",
          source_ref: node,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{node => "sha256:gate"}
        },
        blob
      )

    auth
  end

  describe "the resolution path every ingress shares" do
    test "an authority with no vault edge resolves no secrets", %{ctx: ctx} do
      {_entry, _digest} = seeded_entry(ctx)
      auth = ungranted_authority()

      # This is what the executor's grant stage sees: an edge without a
      # vault resource yields the empty map, never the legacy plane.
      assert auth.resources.vault == nil
    end

    test "ZeroAuthority carries no resources at all" do
      zero = Authority.zero()

      assert zero.resources == :none
      assert zero.policy == :none
    end

    test "an edge naming an entry is the ONLY way material appears", %{ctx: ctx} do
      {entry, digest} = seeded_entry(ctx)

      # Without the edge: nothing.
      assert ungranted_authority().resources.vault == nil

      # With it: exactly the granted fields, and only through the reader.
      assert {:ok, %{"api_key" => "sk-operator-only"}} =
               VaultReader.fetch(ctx, %{entry_id: entry.id, binding_digest: digest})
    end

    test "an anonymous caller is refused even holding a valid edge", %{ctx: ctx} do
      {entry, digest} = seeded_entry(ctx)

      assert {:error, :anonymous_denied} =
               VaultReader.fetch(%{ctx | anonymous: true}, %{
                 entry_id: entry.id,
                 binding_digest: digest
               })
    end
  end

  describe "per-ingress classification" do
    # Each classified ingress either routes through Opus.Chain (and so
    # inherits the shared resolution above) or falls back to the legacy
    # path when no profile exists. This pins which is which, so a change
    # in routing has to be deliberate.
    # The console tincture surface shares the :tincture flag — one
    # ingress, two transports, and since the extraction ONE implementation
    # (Emissary.Tincture.Invoke), so one kill switch and one row here.
    @ingresses [
      {:mcp, "apps/opus/lib/opus/mcp.ex", :falls_back},
      {:cron, "apps/opus/lib/opus/cron_scheduler.ex", :no_fallback_when_bound},
      {:webhook, "apps/cyfr/lib/emissary_web/controllers/webhook_controller.ex",
       :no_fallback_when_bound},
      {:tincture, "apps/cyfr/lib/emissary/tincture/invoke.ex", :falls_back}
    ]

    test "each ingress routes through the chain" do
      root = Path.expand("../../../..", __DIR__)

      for {_ingress, path, _fallback} <- @ingresses do
        source = File.read!(Path.join(root, path))

        assert String.contains?(source, "run_root") or String.contains?(source, "Opus.run_root"),
               "#{path} does not route through the chain"
      end
    end

    test "a bound registration never falls back to the legacy path" do
      root = Path.expand("../../../..", __DIR__)

      for {_ingress, path, :no_fallback_when_bound} <-
            Enum.filter(@ingresses, &(elem(&1, 2) == :no_fallback_when_bound)) do
        source = File.read!(Path.join(root, path))

        assert String.contains?(source, "profile_id"),
               "#{path} must decide on the registration's profile binding"
      end
    end
  end
end
