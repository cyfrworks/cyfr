# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TenancyTest do
  # async: false — global :tenancy_resolver_override / :platform_admin_emails mutation.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Sanctum.Context
  alias Sanctum.Tenancy
  alias Sanctum.Tenancy.Memberships

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

    test "is a no-op when ctx already carries an org_id" do
      ctx = %Context{user_id: "u1", org_id: "acme", project_id: "p1"}
      assert Tenancy.resolve_into(ctx) == ctx
    end

    test "merges resolver result when ctx has no org_id" do
      Application.put_env(:cyfr, :tenancy_resolver_override, Sanctum.Test.OtherOrgResolver)

      ctx = %Context{user_id: "u1", org_id: nil}
      result = Tenancy.resolve_into(ctx)
      assert result.org_id == "other_org"
    end

    test "logs and returns ctx unchanged when the override resolver errors" do
      Application.put_env(:cyfr, :tenancy_resolver_override, Sanctum.Test.FailingResolver)

      ctx = %Context{user_id: "u1", org_id: nil}

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

    test "no membership leaves org_id unresolved" do
      ctx = %Context{user_id: "nobody-#{System.unique_integer([:positive])}", org_id: nil}
      assert Tenancy.resolve_into(ctx, force: true).org_id == nil
    end

    test "a single project membership resolves scope/org/project" do
      uid = "u-proj-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Memberships.create(%{
          user_id: uid,
          scope: "project",
          org_id: "local",
          project_id: "default"
        })

      result = Tenancy.resolve_into(%Context{user_id: uid, org_id: nil}, force: true)
      assert result.scope == :project
      assert result.org_id == "local"
      assert result.project_id == "default"
    end

    test "highest scope wins (platform > org > project)" do
      uid = "u-multi-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Memberships.create(%{
          user_id: uid,
          scope: "project",
          org_id: "local",
          project_id: "default"
        })

      {:ok, _} = Memberships.ensure(uid, scope: "platform")

      result = Tenancy.resolve_into(%Context{user_id: uid, org_id: nil}, force: true)
      assert result.scope == :platform
      # A platform membership has no org row; it resolves to the concrete local
      # sentinel workspace (never an empty/nil org downstream).
      assert result.org_id == "local"
      assert result.project_id == "default"
    end

    test "an email in CYFR_PLATFORM_ADMIN_EMAILS is bootstrapped to platform scope" do
      Application.put_env(:cyfr, :platform_admin_emails, ["admin@example.com"])
      uid = "u-admin-#{System.unique_integer([:positive])}"

      ctx = %Context{user_id: uid, org_id: nil, email: "admin@example.com"}
      result = Tenancy.resolve_into(ctx, force: true)

      assert result.scope == :platform
      assert Enum.any?(Memberships.list_by_user(uid), &(&1.scope == "platform"))
    end

    test "bootstrap is idempotent across repeated sign-ins" do
      Application.put_env(:cyfr, :platform_admin_emails, ["admin2@example.com"])
      uid = "u-admin2-#{System.unique_integer([:positive])}"
      ctx = %Context{user_id: uid, org_id: nil, email: "admin2@example.com"}

      Tenancy.resolve_into(ctx, force: true)
      Tenancy.resolve_into(ctx, force: true)

      assert [_one] = Memberships.list_by_user(uid)
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
      {:ok, _} = Memberships.ensure(uid, scope: "platform")

      ctx = %Context{
        user_id: uid,
        org_id: "local",
        project_id: "default",
        scope: :platform,
        authenticated: true
      }

      assert Tenancy.revalidate(ctx).scope == :platform
    end

    test "drops a stale platform scope after the platform membership is revoked" do
      uid = "u-reval-revoke-#{System.unique_integer([:positive])}"
      {:ok, _} = Memberships.ensure(uid, scope: "platform")

      ctx = %Context{
        user_id: uid,
        org_id: "local",
        project_id: "default",
        scope: :platform,
        authenticated: true
      }

      # Reach is intact while the membership exists.
      assert Tenancy.revalidate(ctx).scope == :platform

      # Revoke it.
      [m] = Memberships.list_by_user(uid)
      {:ok, _} = Memberships.remove(m)

      # The stale :platform scope must NOT survive — no memberships → org-less,
      # and the tenant gate then rejects tenant-scoped routes.
      revalidated = Tenancy.revalidate(ctx)
      refute revalidated.scope == :platform
      assert revalidated.org_id == nil
    end

    test "downgrade platform -> org drops the elevated scope but keeps a granted workspace" do
      uid = "u-reval-down-#{System.unique_integer([:positive])}"
      {:ok, _} = Memberships.create(%{user_id: uid, scope: "org", org_id: "local", project_id: nil})

      # A session previously resolved as :platform, viewing a project in its org.
      ctx = %Context{
        user_id: uid,
        org_id: "local",
        project_id: "p1",
        scope: :platform,
        authenticated: true
      }

      revalidated = Tenancy.revalidate(ctx)
      assert revalidated.scope == :org
      # Org membership grants the whole org, so the selected project is kept.
      assert revalidated.org_id == "local"
      assert revalidated.project_id == "p1"
    end

    test "falls back to the broadest membership when the selected workspace is no longer granted" do
      uid = "u-reval-switch-#{System.unique_integer([:positive])}"
      {:ok, _} = Memberships.create(%{user_id: uid, scope: "org", org_id: "local", project_id: nil})

      # Session points at an org the user is NOT a member of.
      ctx = %Context{
        user_id: uid,
        org_id: "other-org",
        project_id: "p9",
        scope: :org,
        authenticated: true
      }

      revalidated = Tenancy.revalidate(ctx)
      assert revalidated.scope == :org
      assert revalidated.org_id == "local"
    end
  end

  describe "list_workspaces/1" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
      :ok
    end

    test "platform admin sees the seeded local/default workspace" do
      ctx = %Context{user_id: "admin-#{System.unique_integer([:positive])}", scope: :platform}

      assert Enum.any?(
               Tenancy.list_workspaces(ctx),
               &(&1.org_id == "local" and &1.project_id == "default")
             )
    end

    test "a project member sees the workspace their membership grants" do
      uid = "u-ws-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Memberships.create(%{
          user_id: uid,
          scope: "project",
          org_id: "local",
          project_id: "default"
        })

      ctx = %Context{user_id: uid, scope: :project, org_id: "local", project_id: "default"}

      assert Enum.any?(
               Tenancy.list_workspaces(ctx),
               &(&1.org_id == "local" and &1.project_id == "default")
             )
    end

    test "a user with no membership sees no workspaces" do
      ctx = %Context{user_id: "nobody-#{System.unique_integer([:positive])}", scope: :project}
      assert Tenancy.list_workspaces(ctx) == []
    end

    test "each workspace carries string display names" do
      ctx = %Context{user_id: "admin-#{System.unique_integer([:positive])}", scope: :platform}

      assert Enum.all?(Tenancy.list_workspaces(ctx), fn w ->
               is_binary(w.org_name) and is_binary(w.project_name)
             end)
    end
  end

  defp restore(k, nil), do: Application.delete_env(:cyfr, k)
  defp restore(k, v), do: Application.put_env(:cyfr, k, v)
end
