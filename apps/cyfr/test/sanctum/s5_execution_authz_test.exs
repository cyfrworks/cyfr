# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.S5ExecutionAuthzTest do
  @moduledoc """
  The execution-events controller delegates to the single authorization
  chokepoint `Sanctum.Context.authorize(ctx, :read, {:execution, exec})`. This
  pins the exact decision the controller relies on: the :storage_read
  permission gate + per-record `verify_tenant` (org/project equality). There is
  no owner gate — project members are interchangeable, so any same-tenant member
  with :storage_read may read the record; cross-tenant access is still rejected.
  Opus-free (the HTTP route itself is :requires_opus).
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

  test "non-owner in the same tenant is authorized (members are interchangeable)" do
    other = ctx([:storage_read], user_id: "intruder")
    assert Context.authorize(other, :read, {:execution, @exec}) == :ok
  end

  test "wildcard (:*) is fully authorized (satisfies the storage_read gate)" do
    assert Context.authorize(ctx([:*], user_id: "y"), :read, {:execution, @exec}) == :ok
  end

  test ":admin still requires the storage_read permission gate" do
    # require_permission(:storage_read) runs first, so :admin alone (no
    # storage_read, not :*) is refused — the permission gate is independent of
    # any role and of ownership.
    assert {:error, _} =
             Context.authorize(ctx([:admin], user_id: "x"), :read, {:execution, @exec})

    # With storage_read present, any member of the tenant is authorized.
    assert Context.authorize(
             ctx([:admin, :storage_read], user_id: "x"),
             :read,
             {:execution, @exec}
           ) ==
             :ok
  end

  test "unauthenticated context is refused" do
    unauth = %Context{authenticated: false, user_id: "owner-1"}
    assert {:error, _} = Context.authorize(unauth, :read, {:execution, @exec})
  end

  test "cross-tenant owner is refused under the strict policy (per-record verify_tenant)" do
    # Same user_id, different org: ownership alone must not grant access —
    fn ->
      # verify_tenant runs before the ownership check.
      foreign = %{user_id: "owner-1", org_id: "org_b", project_id: "default"}
      assert {:error, _} = Context.authorize(ctx([:storage_read]), :read, {:execution, foreign})
    end
  end
end
