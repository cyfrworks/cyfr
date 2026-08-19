# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.AuthTenantResolutionTest do
  @moduledoc """
  Regression: every auth path that produces a `Sanctum.Context` from a fresh
  login must call `Sanctum.Tenancy.resolve_into/2` with `force: true` so the
  caller's scope/athanor is resolved from their memberships before any
  tenant-scoped operation runs.

  `Sanctum.Context.build/1` leaves `athanor_id` nil when none is supplied, so an
  unresolved context is rejected by the tenant gate — the auth path is
  responsible for resolving it.
  """
  # async: false — global :tenancy_resolver_override mutation.
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.Tenancy
  alias Sanctum.Tenancy.Members

  setup do
    # Isolate from other tests' committed membership rows: resolve_into reads
    # the memberships table.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    original_override = Application.get_env(:cyfr, :tenancy_resolver_override)
    original_admins = Application.get_env(:cyfr, :platform_admin_emails)
    # Membership-based resolution must not be short-circuited by a leaked
    # admin-email bootstrap from another test.
    Application.put_env(:cyfr, :platform_admin_emails, [])

    on_exit(fn ->
      if original_override,
        do: Application.put_env(:cyfr, :tenancy_resolver_override, original_override),
        else: Application.delete_env(:cyfr, :tenancy_resolver_override)

      if original_admins,
        do: Application.put_env(:cyfr, :platform_admin_emails, original_admins),
        else: Application.delete_env(:cyfr, :platform_admin_emails)
    end)

    :ok
  end

  describe "resolve_into/2 with force: true" do
    test "resolves a freshly-built (athanor-less) context via the resolver" do
      Application.put_env(:cyfr, :tenancy_resolver_override, Sanctum.Test.OtherAthanorResolver)

      # Same shape as the contexts produced by OAuth.authenticate/1 and
      # DeviceFlow's create_session/2 — Context.build/1 leaves athanor_id nil.
      ctx = oauth_shaped_context()
      assert ctx.athanor_id == nil, "Context.build/1 should leave athanor_id unresolved"

      result = Tenancy.resolve_into(ctx, force: true)
      assert result.athanor_id == "ath_other"
    end

    test "without force, no-ops when ctx already carries an athanor_id (per-request safety net)" do
      Application.put_env(:cyfr, :tenancy_resolver_override, Sanctum.Test.OtherAthanorResolver)

      # A context whose athanor was already resolved at session-create time.
      ctx = %{oauth_shaped_context() | athanor_id: "ath_acme"}

      result = Tenancy.resolve_into(ctx)
      assert result.athanor_id == "ath_acme"
    end

    test "with force and no membership, the athanor stays unresolved (nil)" do
      Application.delete_env(:cyfr, :tenancy_resolver_override)

      ctx = oauth_shaped_context()
      result = Tenancy.resolve_into(ctx, force: true)
      assert result.athanor_id == nil
    end

    test "OAuth.authenticate/1 force-resolves before returning" do
      Application.put_env(:cyfr, :tenancy_resolver_override, Sanctum.Test.OtherAthanorResolver)
      configure_github_test_credentials!()

      auth_params = %{
        provider: :github,
        uid: "12345",
        info: %{email: "verified@example.com"},
        extra: %{raw_info: %{user: %{"email_verified" => true}}}
      }

      assert {:ok, %Context{} = ctx} = Sanctum.Auth.OAuth.authenticate(auth_params)
      assert ctx.athanor_id == "ath_other"
    end
  end

  describe "the operator list is applied at sign-in, not by resolution" do
    test "a CYFR_PLATFORM_ADMIN_EMAILS-listed email gets the capability on first sign-in" do
      ctx = oauth_shaped_context()
      Application.put_env(:cyfr, :platform_admin_emails, [String.downcase(ctx.email)])

      # Resolution alone mints nothing.
      assert Tenancy.resolve_into(ctx, force: true).platform_admin == false
      assert Members.list_by_user(ctx.user_id) == []

      # The door admits the operator; sign-in records it; resolution reads it.
      assert {:ok, :admin} = Sanctum.Door.admit(ctx.user_id, ctx.email, true)

      assert {:ok, _} =
               Sanctum.SignIn.admitted(
                 %{id: ctx.user_id, provider: "github", email: ctx.email, verified: true},
                 :admin
               )

      result = Tenancy.resolve_into(ctx, force: true)
      assert result.platform_admin
      assert result.scope == :athanor
      assert Enum.any?(Members.list_by_user(ctx.user_id), &(&1.scope == "platform"))
    end

    test "an unlisted, unmembered user stays unresolved with no membership row" do
      # :platform_admin_emails is [] (setup) and no membership exists for this user.
      ctx = oauth_shaped_context()

      result = Tenancy.resolve_into(ctx, force: true)

      assert result.athanor_id == nil
      assert Members.list_by_user(ctx.user_id) == []
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp oauth_shaped_context do
    Context.build(
      user_id: Sanctum.Auth.Identity.builtin_user_id(:github, "12345"),
      email: "tester@example.com",
      provider: "github",
      namespace: "testns",
      # Athanor-less, like the real OAuth/OIDC providers — resolved via memberships.
      athanor_id: nil,
      permissions: [:*]
    )
  end

  # OAuth.authenticate/1 short-circuits if neither GitHub nor Google is
  # configured. Inject test credentials so the provider-check passes.
  defp configure_github_test_credentials! do
    original =
      Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)

    Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth,
      client_id: "test_client_id",
      client_secret: "test_client_secret"
    )

    on_exit(fn ->
      if original,
        do: Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth, original),
        else: Application.delete_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)
    end)
  end
end
