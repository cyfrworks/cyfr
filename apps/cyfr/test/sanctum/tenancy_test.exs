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

  defp restore(k, nil), do: Application.delete_env(:cyfr, k)
  defp restore(k, v), do: Application.put_env(:cyfr, k, v)
end
