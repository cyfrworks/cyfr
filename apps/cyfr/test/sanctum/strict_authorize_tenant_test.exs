# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.StrictAuthorizeTenantTest do
  @moduledoc """
  `Sanctum.Context.authorize/3` is the authoritative tenant check. A
  cross-tenant record must be denied *at authorize/3* (not only later by the
  storage backstop) for every recognized resource shape.
  """
  use ExUnit.Case, async: true

  alias Sanctum.Context

  setup do
    ctx =
      Context.build(
        user_id: "u1",
        namespace: "u1",
        athanor_id: "ath_a",
        scope: :athanor,
        permissions: [:*],
        authenticated: true
      )

    %{ctx: ctx}
  end

  describe "authorize/3 enforces the record's athanor" do
    test "{:tenant, record} — same athanor passes, cross-athanor denied", %{ctx: ctx} do
      assert :ok = Context.authorize(ctx, :read, {:tenant, %{athanor_id: "ath_a"}})
      assert {:error, _} = Context.authorize(ctx, :read, {:tenant, %{athanor_id: "ath_b"}})
    end

    test "{:execution, record} — cross-athanor denied before the ownership check",
         %{ctx: ctx} do
      # ctx owns it (same user_id) and holds :* — but a foreign athanor must
      # still be rejected by verify_tenant, which runs before ownership.
      assert {:error, _} =
               Context.authorize(ctx, :read, {:execution, %{user_id: "u1", athanor_id: "ath_b"}})

      assert :ok =
               Context.authorize(ctx, :read, {:execution, %{user_id: "u1", athanor_id: "ath_a"}})
    end

    test "{:execution, record} — cross-athanor denied", %{ctx: ctx} do
      assert {:error, _} =
               Context.authorize(ctx, :read, {:execution, %{user_id: "u1", athanor_id: "ath_b"}})
    end

    test "a record that names no athanor is malformed, never a same-tenant match", %{ctx: ctx} do
      assert {:error, msg} = Context.authorize(ctx, :read, {:tenant, %{id: "x"}})
      assert msg =~ "malformed record"

      assert {:error, msg} = Context.authorize(ctx, :read, {:execution, %{user_id: "u1"}})
      assert msg =~ "malformed record"
    end

    test "permission-only (nil) — athanor-less context denied by tenant presence" do
      unresolved =
        Context.build(
          user_id: "u2",
          namespace: "u2",
          athanor_id: nil,
          scope: :athanor,
          permissions: [:*],
          authenticated: true
        )

      # An explicit athanor-less context is rejected by the tenant policy as
      # missing_tenant.
      assert unresolved.athanor_id == nil
      assert {:error, _} = Context.authorize(unresolved, :read, nil)
    end

    test "unauthenticated context is always denied", %{ctx: ctx} do
      assert {:error, _} =
               Context.authorize(
                 %{ctx | authenticated: false},
                 :read,
                 {:tenant, %{athanor_id: "ath_a"}}
               )
    end
  end
end
