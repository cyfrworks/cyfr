# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.S5ExecutionAuthzTest do
  @moduledoc """
  Phase 2 S5: the execution-events controller now delegates to the single
  authorization chokepoint `Sanctum.Context.authorize(ctx, :read,
  {:execution, exec})` instead of a hand-rolled owner-or-admin check. This
  pins the exact decision the controller relies on, including the new
  hardening (storage_read permission + per-record verify_tenant) that the old
  inline check skipped. Opus-free (the HTTP route itself is :requires_opus).
  """
  use ExUnit.Case, async: false


  alias Sanctum.Context

  defp ctx(perms, opts \\ []) do
    Context.build(
      [
        user_id: "owner-1",
        namespace: "ns",
        org_id: "org_a",
        project_id: "default",
        permissions: perms,
        scope: :project,
        auth_method: :oidc,
        authenticated: true
      ]
      |> Keyword.merge(opts)
    )
  end

  @exec %{user_id: "owner-1", org_id: "org_a", project_id: "default"}

  test "owner with :storage_read is authorized" do
    assert Context.authorize(ctx([:storage_read]), :read, {:execution, @exec}) == :ok
  end

  test "owner WITHOUT :storage_read is now refused (the S5 hardening)" do
    assert {:error, _} = Context.authorize(ctx([:execute]), :read, {:execution, @exec})
  end

  test "non-owner without admin is refused" do
    other = ctx([:storage_read], user_id: "intruder")
    assert {:error, _} = Context.authorize(other, :read, {:execution, @exec})
  end

  test "wildcard (:*) is fully authorized (satisfies storage_read + ownership override)" do
    assert Context.authorize(ctx([:*], user_id: "y"), :read, {:execution, @exec}) == :ok
  end

  test ":admin overrides ownership only once the storage_read gate is satisfied" do
    # require_permission(:storage_read) runs BEFORE the owner/admin check, so
    # :admin alone (no storage_read, not :*) is refused — the S5 hardening:
    # the old hand-rolled check let :admin bypass the permission gate entirely.
    assert {:error, _} = Context.authorize(ctx([:admin], user_id: "x"), :read, {:execution, @exec})

    # With storage_read present, :admin then overrides ownership for a
    # non-owner (matching every other execution-record consumer).
    assert Context.authorize(ctx([:admin, :storage_read], user_id: "x"), :read, {:execution, @exec}) ==
             :ok
  end

  test "unauthenticated context is refused" do
    unauth = %Context{authenticated: false, user_id: "owner-1"}
    assert {:error, _} = Context.authorize(unauth, :read, {:execution, @exec})
  end

  test "cross-tenant owner is refused under the strict policy (per-record verify_tenant)" do
    (fn ->       # Same user_id, different org: ownership alone must not grant access —
      # verify_tenant runs before the ownership check.
      foreign = %{user_id: "owner-1", org_id: "org_b", project_id: "default"}
      assert {:error, _} = Context.authorize(ctx([:storage_read]), :read, {:execution, foreign})
    end)
  end
end
