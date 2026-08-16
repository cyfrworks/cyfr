# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TenantPolicyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Sanctum.TenantPolicy
  alias Sanctum.Context

  describe "require_athanor/1" do
    test "rejects nil athanor_id" do
      ctx = %Context{user_id: "u1", athanor_id: nil}
      assert {:error, :missing_tenant} = TenantPolicy.require_athanor(ctx)
    end

    test "rejects empty-string athanor_id" do
      ctx = %Context{user_id: "u1", athanor_id: ""}
      assert {:error, :missing_tenant} = TenantPolicy.require_athanor(ctx)
    end

    test "accepts any non-empty athanor_id — Home is an ordinary athanor gated by membership" do
      ctx = %Context{user_id: "u1", athanor_id: "ath_home"}
      assert :ok = TenantPolicy.require_athanor(ctx)
    end
  end

  describe "verify/2" do
    test ":platform scope bypasses (cross-tenant ops e.g. retention sweeps)" do
      ctx = Context.build(user_id: "u1", scope: :platform)
      assert :ok = TenantPolicy.verify(ctx, %{athanor_id: "any"})
    end

    test "rejects nil athanor_id even outside :platform scope" do
      ctx = %Context{user_id: "u1", athanor_id: nil}

      assert {:error, "Unauthorized: a resolved athanor_id is required"} =
               TenantPolicy.verify(ctx, %{athanor_id: "ath_acme"})
    end

    test "enforces tenant equality when athanor_id is set" do
      ctx = Context.build(user_id: "u1", athanor_id: "ath_acme")

      # Match → :ok
      assert :ok = TenantPolicy.verify(ctx, %{athanor_id: "ath_acme"})

      # Mismatch → error
      assert {:error, "Unauthorized: tenant mismatch"} =
               TenantPolicy.verify(ctx, %{athanor_id: "ath_evil"})
    end

    test "a record without an athanor is malformed and refused, never treated as a match" do
      ctx = Context.build(user_id: "u1", athanor_id: "ath_acme")

      log =
        capture_log(fn ->
          assert {:error, "Unauthorized: malformed record (no athanor)"} =
                   TenantPolicy.verify(ctx, %{id: "x"})

          assert {:error, "Unauthorized: malformed record (no athanor)"} =
                   TenantPolicy.verify(ctx, %{athanor_id: nil})

          assert {:error, "Unauthorized: malformed record (no athanor)"} =
                   TenantPolicy.verify(ctx, %{athanor_id: ""})
        end)

      assert log =~ "Record without an athanor refused"
    end
  end
end
