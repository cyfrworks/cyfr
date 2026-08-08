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
      Context.build(authenticated: false, scope: :project),
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

  describe "Tenancy.user_active_in_org?/2" do
    test "true for any owner when no auth provider is configured" do
      assert Sanctum.Tenancy.user_active_in_org?("anyone", "any_org")
      assert Sanctum.Tenancy.user_active_in_org?(nil, "any_org")
    end

    test "membership-checked when an auth provider is configured" do
      Application.put_env(:cyfr, :auth_provider, Sanctum.Auth.OIDC)
      on_exit(fn -> Application.delete_env(:cyfr, :auth_provider) end)

      # Orphaned or missing owners are inactive
      refute Sanctum.Tenancy.user_active_in_org?(nil, "org_x")
      refute Sanctum.Tenancy.user_active_in_org?("", "org_x")
      refute Sanctum.Tenancy.user_active_in_org?("departed-user", "org_x")

      # An org membership grants its org, not others
      {:ok, _} = Sanctum.Tenancy.Orgs.create(%{id: "org_x", name: "Org X", slug: "org-x"})

      {:ok, _} =
        Sanctum.Tenancy.Memberships.ensure("member-user", scope: "org", org_id: "org_x")

      assert Sanctum.Tenancy.user_active_in_org?("member-user", "org_x")
      refute Sanctum.Tenancy.user_active_in_org?("member-user", "org_other")

      # A platform membership grants every org
      {:ok, _} = Sanctum.Tenancy.Memberships.ensure("admin-user", scope: "platform")
      assert Sanctum.Tenancy.user_active_in_org?("admin-user", "org_x")
      assert Sanctum.Tenancy.user_active_in_org?("admin-user", "org_other")
    end
  end
end
