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

    test "a platform admin keeps :athanor scope with the capability; works in the first athanor" do
      uid = "u-multi-#{System.unique_integer([:positive])}"
      athanor = group!("home-b")
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: athanor.id})
      {:ok, _} = Members.ensure(uid, scope: "platform")

      result = Tenancy.resolve_into(%Context{user_id: uid, athanor_id: nil}, force: true)
      assert result.scope == :athanor
      assert result.platform_admin
      assert result.athanor_id == athanor.id
    end

    test "a platform admin with no athanor membership works in Home" do
      uid = "u-plat-only-#{System.unique_integer([:positive])}"
      {:ok, _} = Members.ensure(uid, scope: "platform")

      result = Tenancy.resolve_into(%Context{user_id: uid, athanor_id: nil}, force: true)
      assert result.scope == :athanor
      assert result.platform_admin
      assert result.athanor_id == Athanors.home!().id
    end

    test "resolution never mints anything — the operator list is applied at sign-in only" do
      Application.put_env(:cyfr, :platform_admin_emails, ["admin@example.com"])
      uid = "u-admin-#{System.unique_integer([:positive])}"

      ctx = %Context{user_id: uid, athanor_id: nil, email: "admin@example.com"}
      result = Tenancy.resolve_into(ctx, force: true)

      refute result.platform_admin
      assert Members.list_by_user(uid) == []
    end

    test "an archived athanor is never chosen" do
      uid = "u-archived-#{System.unique_integer([:positive])}"
      a = group!("arch-a")
      b = group!("arch-b")
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: a.id})
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: b.id})
      {:ok, _} = Athanors.archive(a)

      result = Tenancy.resolve_into(%Context{user_id: uid, athanor_id: a.id}, force: true)
      assert result.athanor_id == b.id
    end
  end

  describe "revalidate/1" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
      :ok
    end

    test "keeps the capability while the platform membership exists" do
      uid = "u-reval-keep-#{System.unique_integer([:positive])}"
      {:ok, _} = Members.ensure(uid, scope: "platform")

      ctx = %Context{
        user_id: uid,
        athanor_id: Athanors.home!().id,
        scope: :athanor,
        authenticated: true
      }

      out = Tenancy.revalidate(ctx)
      assert out.platform_admin
      assert out.scope == :athanor
    end

    test "drops the capability once the platform membership is revoked" do
      uid = "u-reval-revoke-#{System.unique_integer([:positive])}"
      {:ok, _} = Members.ensure(uid, scope: "platform")

      ctx = %Context{
        user_id: uid,
        athanor_id: Athanors.home!().id,
        scope: :athanor,
        platform_admin: true,
        authenticated: true
      }

      assert Tenancy.revalidate(ctx).platform_admin

      [m] = Members.list_by_user(uid)
      {:ok, _} = Members.remove(m)

      # No memberships → no capability, no athanor; the tenant gate then
      # rejects tenant-scoped routes.
      revalidated = Tenancy.revalidate(ctx)
      refute revalidated.platform_admin
      assert revalidated.athanor_id == nil
    end

    test "a stale capability on the context does not survive revalidation" do
      uid = "u-reval-down-#{System.unique_integer([:positive])}"
      athanor = group!("home-c")
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: athanor.id})

      ctx = %Context{
        user_id: uid,
        athanor_id: athanor.id,
        scope: :athanor,
        platform_admin: true,
        authenticated: true
      }

      revalidated = Tenancy.revalidate(ctx)
      refute revalidated.platform_admin
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

      assert Tenancy.list_athanors(%Context{user_id: uid, scope: :athanor, platform_admin: true}) ==
               []
    end

    test "a user with no membership sees no athanors" do
      ctx = %Context{user_id: "nobody-#{System.unique_integer([:positive])}", scope: :athanor}
      assert Tenancy.list_athanors(ctx) == []
    end
  end

  describe "channel_active?/2" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
      :ok
    end

    test "true while the athanor is active and the creator is not denied" do
      athanor = group!("chan-a")
      uid = "u-chan-#{System.unique_integer([:positive])}"

      {:ok, user} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: uid,
          provider: "github",
          email: "chan@example.com",
          verified: true
        })

      assert Tenancy.channel_active?(athanor.id, uid)
      # a creator who merely leaves (or never was a member) leaves the channel running
      assert Tenancy.channel_active?(athanor.id, "someone-else")
      # synthetic principals are never denied
      assert Tenancy.channel_active?(athanor.id, "webhook:abc")
      assert Tenancy.channel_active?(athanor.id, nil)

      {:ok, _} = Sanctum.Tenancy.Users.deny(user)
      refute Tenancy.channel_active?(athanor.id, uid)

      {:ok, _} = Athanors.archive(athanor)
      refute Tenancy.channel_active?(athanor.id, "someone-else")
    end

    test "false for a missing or unknown athanor" do
      refute Tenancy.channel_active?(nil, "u")
      refute Tenancy.channel_active?("", "u")
      refute Tenancy.channel_active?("ath_ghost", "u")
    end
  end

  defp restore(k, nil), do: Application.delete_env(:cyfr, k)
  defp restore(k, v), do: Application.put_env(:cyfr, k, v)
end
