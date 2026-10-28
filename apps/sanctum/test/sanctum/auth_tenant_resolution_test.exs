# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.AuthTenantResolutionTest do
  @moduledoc """
  Fresh login contexts must resolve membership with force: true before tenant-scoped operations.

  `Sanctum.Context.build/1` leaves `athanor_id` nil when none is supplied, so an
  unresolved context is rejected by the tenant gate — the auth path is
  responsible for resolving it.
  """
  # async: false — global :tenancy_resolver_override mutation.
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.Tenancy
  alias Sanctum.Tenancy.Members

  setup tags do
    # Isolate from other tests' committed membership rows: resolve_status reads
    # the memberships table.
    Arca.Test.Sandbox.setup!(tags)

    original_override = Application.get_env(:sanctum, :tenancy_resolver_override)

    on_exit(fn ->
      if original_override,
        do: Application.put_env(:sanctum, :tenancy_resolver_override, original_override),
        else: Application.delete_env(:sanctum, :tenancy_resolver_override)
    end)

    :ok
  end

  describe "resolve_status/2 with force: true" do
    test "resolves a freshly-built (athanor-less) context via the resolver" do
      Application.put_env(:sanctum, :tenancy_resolver_override, Sanctum.Test.OtherAthanorResolver)

      # Same shape as the contexts produced by OIDC.authenticate/1 and
      # DeviceFlow's create_session/2 — Context.build/1 leaves athanor_id nil.
      ctx = oauth_shaped_context()
      assert ctx.athanor_id == nil, "Context.build/1 should leave athanor_id unresolved"

      {:ok, result} = Tenancy.resolve_status(ctx, force: true)
      assert result.athanor_id == "ath_other"
    end

    test "without force, no-ops when ctx already carries an athanor_id (per-request safety net)" do
      Application.put_env(:sanctum, :tenancy_resolver_override, Sanctum.Test.OtherAthanorResolver)

      # A context whose athanor was already resolved at session-create time.
      ctx = %{oauth_shaped_context() | athanor_id: "ath_acme"}

      {:ok, result} = Tenancy.resolve_status(ctx)
      assert result.athanor_id == "ath_acme"
    end

    test "with force and no membership, the athanor stays unresolved (nil)" do
      Application.delete_env(:sanctum, :tenancy_resolver_override)

      ctx = oauth_shaped_context()
      {:ok, result} = Tenancy.resolve_status(ctx, force: true)
      assert result.athanor_id == nil
    end

    test "OIDC.authenticate/1 names the identity and nothing more: the athanor comes after the door" do
      Application.put_env(:sanctum, :tenancy_resolver_override, Sanctum.Test.OtherAthanorResolver)
      Application.put_env(:sanctum, :oidc_issuer, "https://auth.example.com")
      on_exit(fn -> Application.delete_env(:sanctum, :oidc_issuer) end)

      auth = %{
        __struct__: Ueberauth.Auth,
        provider: :oidcc,
        uid: "12345",
        info: %{email: "verified@example.com"},
        extra: %{raw_info: %{userinfo: %{"email_verified" => true}}}
      }

      assert {:ok, %Context{} = ctx} = Sanctum.Auth.OIDC.authenticate(auth)
      assert ctx.user_id == "oidcc|https://auth.example.com|12345"
      assert ctx.athanor_id == nil
    end
  end

  describe "the platform grant is the first person's, and resolution only reads it" do
    test "the installation's first person holds the capability; resolution mints nothing" do
      Application.delete_env(:sanctum, :tenancy_resolver_override)
      ctx = oauth_shaped_context()

      # Resolution alone mints nothing.
      assert {:ok, %{platform_admin: false}} = Tenancy.resolve_status(ctx, force: true)
      assert rows!(Members.list_by_user(ctx.user_id)) == []

      # The setup admission's mint writes the grant with the first person.
      first = Sanctum.Test.People.first!()

      {:ok, result} = Tenancy.resolve_status(%{ctx | user_id: first.id}, force: true)
      assert result.platform_admin
      assert result.scope == :athanor
      assert Enum.any?(rows!(Members.list_by_user(first.id)), &(&1.scope == "platform"))

      # Everyone after them is admitted without it.
      {:ok, later} =
        Sanctum.Test.People.linked(%{
          id: ctx.user_id,
          provider: "github",
          email: ctx.email,
          verified: true
        })

      {:ok, result} = Tenancy.resolve_status(%{ctx | user_id: later.id}, force: true)
      refute result.platform_admin
      refute Enum.any?(rows!(Members.list_by_user(later.id)), &(&1.scope == "platform"))
    end

    test "an unmembered user stays unresolved with no membership row" do
      Application.delete_env(:sanctum, :tenancy_resolver_override)
      ctx = oauth_shaped_context()

      {:ok, result} = Tenancy.resolve_status(ctx, force: true)

      assert result.athanor_id == nil
      assert rows!(Members.list_by_user(ctx.user_id)) == []
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp oauth_shaped_context do
    Context.build(
      user_id: Sanctum.Auth.Identity.builtin_key(:github, "12345"),
      email: "tester@example.com",
      provider: "github",
      namespace: "testns",
      # Athanor-less, as device flow and the OIDC provider build it — resolved via memberships.
      athanor_id: nil,
      permissions: [:*]
    )
  end

  defp rows!({:ok, rows}), do: rows
end
