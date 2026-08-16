# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TenancyTest do
  # async: false — global :tenancy_resolver_override / :platform_admin_emails mutation.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Sanctum.Context
  alias Sanctum.Tenancy
  alias Sanctum.Tenancy.{Athanors, Members}

  defp group!(name) do
    {:ok, athanor} =
      Athanors.create(%{
        kind: "group",
        name: name,
        slug: "#{name}-#{System.unique_integer([:positive])}",
        created_by: "system"
      })

    athanor
  end

  describe "resolve_into/2 — override seam" do
    setup do
      original = Application.get_env(:cyfr, :tenancy_resolver_override)

      on_exit(fn ->
        if original,
          do: Application.put_env(:cyfr, :tenancy_resolver_override, original),
          else: Application.delete_env(:cyfr, :tenancy_resolver_override)
      end)

      :ok
    end

    test "is a no-op when ctx already carries an athanor_id" do
      ctx = %Context{user_id: "u1", athanor_id: "ath_acme"}
      assert Tenancy.resolve_into(ctx) == ctx
    end

    test "merges resolver result when ctx has no athanor_id" do
      Application.put_env(:cyfr, :tenancy_resolver_override, Sanctum.Test.OtherAthanorResolver)

      ctx = %Context{user_id: "u1", athanor_id: nil}
      result = Tenancy.resolve_into(ctx)
      assert result.athanor_id == "ath_other"
      assert result.scope == :athanor
    end

    test "logs and returns ctx unchanged when the override resolver errors" do
      Application.put_env(:cyfr, :tenancy_resolver_override, Sanctum.Test.FailingResolver)

      ctx = %Context{user_id: "u1", athanor_id: nil}

      log =
        capture_log(fn ->
          assert Tenancy.resolve_into(ctx) == ctx
        end)

      assert log =~ "[Sanctum.Tenancy] resolve override failed"
      assert log =~ "resolve_failed"
    end
  end

  describe "resolve_into/2 — membership resolution" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

      orig_admins = Application.get_env(:cyfr, :platform_admin_emails)
      orig_override = Application.get_env(:cyfr, :tenancy_resolver_override)
      # Membership resolution must run, not the override seam.
      Application.delete_env(:cyfr, :tenancy_resolver_override)

      on_exit(fn ->
        restore(:platform_admin_emails, orig_admins)
        restore(:tenancy_resolver_override, orig_override)
      end)

      :ok
    end

    test "no membership leaves athanor_id unresolved" do
      ctx = %Context{user_id: "nobody-#{System.unique_integer([:positive])}", athanor_id: nil}
      assert Tenancy.resolve_into(ctx, force: true).athanor_id == nil
    end

    test "an athanor membership resolves scope and athanor" do
      uid = "u-ath-#{System.unique_integer([:positive])}"
      athanor = group!("home-a")
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: athanor.id})

      result = Tenancy.resolve_into(%Context{user_id: uid, athanor_id: nil}, force: true)
      assert result.scope == :athanor
      assert result.athanor_id == athanor.id
    end

    test "platform wins the scope; the working athanor is the first athanor membership" do
      uid = "u-multi-#{System.unique_integer([:positive])}"
      athanor = group!("home-b")
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: athanor.id})
      {:ok, _} = Members.ensure(uid, scope: "platform")

      result = Tenancy.resolve_into(%Context{user_id: uid, athanor_id: nil}, force: true)
      assert result.scope == :platform
      assert result.athanor_id == athanor.id
    end

    test "a platform admin with no athanor membership works in Home" do
      uid = "u-plat-only-#{System.unique_integer([:positive])}"
      {:ok, _} = Members.ensure(uid, scope: "platform")

      result = Tenancy.resolve_into(%Context{user_id: uid, athanor_id: nil}, force: true)
      assert result.scope == :platform
      assert result.athanor_id == Athanors.home!().id
    end

    test "an email in CYFR_PLATFORM_ADMIN_EMAILS is bootstrapped to platform scope" do
      Application.put_env(:cyfr, :platform_admin_emails, ["admin@example.com"])
      uid = "u-admin-#{System.unique_integer([:positive])}"

      ctx = %Context{user_id: uid, athanor_id: nil, email: "admin@example.com"}
      result = Tenancy.resolve_into(ctx, force: true)

      assert result.scope == :platform
      assert Enum.any?(Members.list_by_user(uid), &(&1.scope == "platform"))
    end

    test "bootstrap is idempotent across repeated sign-ins" do
      Application.put_env(:cyfr, :platform_admin_emails, ["admin2@example.com"])
      uid = "u-admin2-#{System.unique_integer([:positive])}"
      ctx = %Context{user_id: uid, athanor_id: nil, email: "admin2@example.com"}

      Tenancy.resolve_into(ctx, force: true)
      Tenancy.resolve_into(ctx, force: true)

      assert [_one] = Members.list_by_user(uid)
    end

    test "minting platform scope emits an audit event exactly once" do
      # The widest grant in the system, keyed only on an email address that a
      # generic OIDC issuer may assert without verifying — it must not be silent,
      # and it must not re-fire on every subsequent sign-in.
      Application.put_env(:cyfr, :platform_admin_emails, ["admin3@example.com"])
      uid = "u-admin3-#{System.unique_integer([:positive])}"
      ctx = %Context{user_id: uid, athanor_id: nil, email: "admin3@example.com"}

      handler_id = "test-platform-bootstrap-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:cyfr, :sanctum, :tenancy, :platform_admin_bootstrap],
        fn _event, measurements, metadata, _cfg ->
          send(test_pid, {:bootstrap_audited, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Tenancy.resolve_into(ctx, force: true)
      assert_receive {:bootstrap_audited, %{count: 1}, metadata}
      assert metadata.user_id == uid
      assert metadata.email == "admin3@example.com"

      # Second sign-in finds the membership already present.
      Tenancy.resolve_into(ctx, force: true)
      refute_receive {:bootstrap_audited, _, _}, 100
    end

    test "no audit event when the email is not an admin" do
      Application.put_env(:cyfr, :platform_admin_emails, ["someone-else@example.com"])
      uid = "u-plain-#{System.unique_integer([:positive])}"

      handler_id = "test-no-bootstrap-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:cyfr, :sanctum, :tenancy, :platform_admin_bootstrap],
        fn _e, m, md, _c -> send(test_pid, {:bootstrap_audited, m, md}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Tenancy.resolve_into(%Context{user_id: uid, athanor_id: nil, email: "plain@example.com"},
        force: true
      )

      refute_receive {:bootstrap_audited, _, _}, 100
    end
  end

  describe "revalidate/1" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
      :ok
    end

    test "keeps platform scope while the platform membership exists" do
      uid = "u-reval-keep-#{System.unique_integer([:positive])}"
      {:ok, _} = Members.ensure(uid, scope: "platform")

      ctx = %Context{
        user_id: uid,
        athanor_id: Athanors.home!().id,
        scope: :platform,
        authenticated: true
      }

      assert Tenancy.revalidate(ctx).scope == :platform
    end

    test "drops a stale platform scope after the platform membership is revoked" do
      uid = "u-reval-revoke-#{System.unique_integer([:positive])}"
      {:ok, _} = Members.ensure(uid, scope: "platform")

      ctx = %Context{
        user_id: uid,
        athanor_id: Athanors.home!().id,
        scope: :platform,
        authenticated: true
      }

      # Reach is intact while the membership exists.
      assert Tenancy.revalidate(ctx).scope == :platform

      # Revoke it.
      [m] = Members.list_by_user(uid)
      {:ok, _} = Members.remove(m)

      # The stale :platform scope must NOT survive — no memberships → no
      # athanor, and the tenant gate then rejects tenant-scoped routes.
      revalidated = Tenancy.revalidate(ctx)
      refute revalidated.scope == :platform
      assert revalidated.athanor_id == nil
    end

    test "downgrade platform -> athanor drops the elevated scope but keeps a granted athanor" do
      uid = "u-reval-down-#{System.unique_integer([:positive])}"
      athanor = group!("home-c")
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: athanor.id})

      # A session previously resolved as :platform, working in an athanor it
      # is a member of.
      ctx = %Context{user_id: uid, athanor_id: athanor.id, scope: :platform, authenticated: true}

      revalidated = Tenancy.revalidate(ctx)
      assert revalidated.scope == :athanor
      assert revalidated.athanor_id == athanor.id
    end

    test "falls back to the broadest membership when the athanor is no longer granted" do
      uid = "u-reval-switch-#{System.unique_integer([:positive])}"
      athanor = group!("home-d")
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: athanor.id})

      # Session points at an athanor the user is NOT a member of.
      ctx = %Context{user_id: uid, athanor_id: "ath_other", scope: :athanor, authenticated: true}

      revalidated = Tenancy.revalidate(ctx)
      assert revalidated.scope == :athanor
      assert revalidated.athanor_id == athanor.id
    end
  end

  describe "list_athanors/1" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
      :ok
    end

    test "a member sees the athanors their memberships grant" do
      uid = "u-list-#{System.unique_integer([:positive])}"
      a = group!("list-a")
      b = group!("list-b")
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: a.id})
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: b.id})

      ids = Tenancy.list_athanors(%Context{user_id: uid, scope: :athanor}) |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([a.id, b.id])
    end

    test "a platform admin sees their own memberships only, not every athanor" do
      uid = "u-list-plat-#{System.unique_integer([:positive])}"
      _other = group!("list-other")
      {:ok, _} = Members.ensure(uid, scope: "platform")

      assert Tenancy.list_athanors(%Context{user_id: uid, scope: :platform}) == []
    end

    test "a user with no membership sees no athanors" do
      ctx = %Context{user_id: "nobody-#{System.unique_integer([:positive])}", scope: :athanor}
      assert Tenancy.list_athanors(ctx) == []
    end
  end

  describe "user_active?/1" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

      original = Application.get_env(:cyfr, :auth_provider)
      Application.put_env(:cyfr, :auth_provider, Sanctum.Auth.OAuth)
      on_exit(fn -> restore(:auth_provider, original) end)
      :ok
    end

    test "true while the user holds any membership; false once none remain" do
      uid = "u-active-#{System.unique_integer([:positive])}"
      refute Tenancy.user_active?(uid)

      {:ok, m} = Members.ensure(uid, scope: "platform")
      assert Tenancy.user_active?(uid)

      {:ok, _} = Members.remove(m)
      refute Tenancy.user_active?(uid)
    end

    test "false for a missing user id" do
      refute Tenancy.user_active?(nil)
      refute Tenancy.user_active?("")
    end
  end

  defp restore(k, nil), do: Application.delete_env(:cyfr, k)
  defp restore(k, v), do: Application.put_env(:cyfr, k, v)
end
