# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.AnonymousIngressTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp anonymous_exec_ctx do
    # Exactly what a public tincture invocation mints
    Sanctum.build_tincture_context(
      Context.build(authenticated: false, scope: :athanor),
      %{publisher: "alice", name: "widget"}
    )
  end

  describe "credential plane denies anonymous contexts" do
    # Retired with the legacy secrets plane: by-name secret access,
    # empty-map resolution for secret-less components, and the loud
    # preload failure for granted components. The surviving property —
    # anonymous execution never receives credential material — is pinned
    # on the vault path (credentialed_ingress_gate_test + the VaultReader
    # anonymity denials here and in vault_reader_test).

    test "delegated OAuth tokens are never dispensed anonymously" do
      anon = anonymous_exec_ctx()

      resource = %{
        entry_id: "vlt_anon_probe",
        binding_digest: "sha256:x",
        projection: %{fields: [], scopes: []}
      }

      assert {:error, reason} = Sanctum.VaultReader.oauth_token(anon, resource, "google")
      assert reason == :anonymous_denied or match?({:anonymous_denied, _}, reason)
    end

    test "an authenticated invoker's tincture context is not anonymous", %{ctx: ctx} do
      invoked = Sanctum.build_tincture_context(ctx, %{publisher: "alice", name: "widget"})

      refute invoked.anonymous
      assert invoked.authenticated
      # Carries the invoker's own identity and permission set, not a minted one.
      assert invoked.user_id == ctx.user_id
      assert MapSet.equal?(invoked.permissions, ctx.permissions)
    end
  end

  describe "Tenancy.channel_active?/2" do
    test "a standing channel needs an active athanor and a creator who is not denied" do
      {:ok, athanor} =
        Sanctum.Tenancy.Athanors.create(%{
          kind: "group",
          name: "Athanor X",
          slug: "athanor-x-#{System.unique_integer([:positive])}",
          created_by: "system"
        })

      # Whoever created it — a member who left, a synthetic principal, nobody
      # in particular — the channel belongs to the athanor and keeps running.
      assert Sanctum.Tenancy.channel_active?(athanor.id, "departed-user")
      assert Sanctum.Tenancy.channel_active?(athanor.id, "webhook:hook")
      assert Sanctum.Tenancy.channel_active?(athanor.id, nil)

      # An archived athanor closes every channel it owns.
      {:ok, _} = Sanctum.Tenancy.Athanors.archive(athanor)
      refute Sanctum.Tenancy.channel_active?(athanor.id, "departed-user")

      # And no channel survives without an athanor.
      refute Sanctum.Tenancy.channel_active?(nil, "anyone")
    end
  end
end
