# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StorageTest do
  use ExUnit.Case, async: true

  alias Arca.Storage
  alias Sanctum.Context

  describe "validate_path!/1" do
    test "accepts valid path segments" do
      assert :ok = Storage.validate_path!(["executions", "exec_123", "started.json"])
    end

    test "accepts single segment" do
      assert :ok = Storage.validate_path!(["components"])
    end

    test "accepts empty list" do
      assert :ok = Storage.validate_path!([])
    end

    test "rejects path traversal with .." do
      assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
        Storage.validate_path!(["executions", "..", "..", "etc", "passwd"])
      end
    end

    test "rejects .. even as first segment" do
      assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
        Storage.validate_path!(["..", "secret"])
      end
    end

    test "rejects .. as only segment" do
      assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
        Storage.validate_path!([".."])
      end
    end

    test "allows single dot segment" do
      assert :ok = Storage.validate_path!([".", "file.txt"])
    end

    test "allows segments containing .. in names" do
      assert :ok = Storage.validate_path!(["file..bak", "test"])
    end
  end

  describe "global_prefixes/0" do
    test "returns expected prefixes" do
      prefixes = Storage.global_prefixes()
      assert "cache" in prefixes
      refute "mcp_logs" in prefixes
    end

    test "returns a list" do
      assert is_list(Storage.global_prefixes())
    end
  end

  describe "tenant_segments/1" do
    test "the athanor id names the tenant directory (namespace not in path)" do
      ctx =
        Context.build(
          user_id: "user_1",
          namespace: "alice",
          athanor_id: "ath_acme",
          authenticated: true
        )

      # namespace ("alice") is identity-only and does NOT appear in the path.
      assert Storage.tenant_segments(ctx) == ["ath_acme"]
    end

    test "namespace is ignored — the athanor alone determines the path" do
      with_ns =
        Context.build(
          user_id: "u",
          namespace: "alice",
          athanor_id: "ath_acme",
          authenticated: true
        )

      without_ns = Context.build(user_id: "u", athanor_id: "ath_acme", authenticated: true)

      assert Storage.tenant_segments(with_ns) == Storage.tenant_segments(without_ns)
      assert Storage.tenant_segments(with_ns) == ["ath_acme"]
    end

    test "raises when the context has no athanor (fail closed)" do
      # A resolved athanor is required to name a tenant directory; a nil means
      # a caller bypassed the Sanctum.Context.require_tenant! chokepoint.
      ctx = Context.build(user_id: "user_1", athanor_id: nil, authenticated: false)

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        Storage.tenant_segments(ctx)
      end
    end

    test "raises for a platform context with no athanor too" do
      ctx =
        Context.build(user_id: "system", scope: :platform, athanor_id: nil, authenticated: true)

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        Storage.tenant_segments(ctx)
      end
    end

    test "rejects path traversal in athanor_id" do
      ctx =
        Context.build(
          user_id: "user_1",
          namespace: "alice",
          athanor_id: "..",
          authenticated: true
        )

      assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
        Storage.tenant_segments(ctx)
      end
    end
  end

  describe "authorize_path/2" do
    test "an athanor reaches its own component tree" do
      ctx = Context.build(user_id: "u", athanor_id: "ath_a", authenticated: true)
      assert :ok = Storage.authorize_path(ctx, ["components", "ath_a", "catalysts", "local"])
    end

    test "an athanor is refused another athanor's component tree" do
      ctx = Context.build(user_id: "u", athanor_id: "ath_a", authenticated: true)

      assert {:error, :forbidden} =
               Storage.authorize_path(ctx, ["components", "ath_b", "catalysts", "local"])
    end

    test "a bare components listing is platform-only" do
      member = Context.build(user_id: "u", athanor_id: "ath_a", authenticated: true)

      platform =
        Context.build(user_id: "op", scope: :platform, athanor_id: nil, authenticated: true)

      assert {:error, :forbidden} = Storage.authorize_path(member, ["components"])
      assert :ok = Storage.authorize_path(platform, ["components"])
      assert :ok = Storage.authorize_path(platform, ["components", "ath_b", "tinctures"])
    end

    test "the seed bundle is readable only by server-internal contexts" do
      member = Context.build(user_id: "u", athanor_id: "ath_a", authenticated: true)

      platform =
        Context.build(user_id: "op", scope: :platform, athanor_id: nil, authenticated: true)

      seed = Sanctum.internal_context(user_id: "_seed", athanor_id: "ath_a", scope: :athanor)

      assert {:error, :forbidden} = Storage.authorize_path(member, ["components", "_bundle"])
      assert {:error, :forbidden} = Storage.authorize_path(platform, ["components", "_bundle"])
      assert :ok = Storage.authorize_path(seed, ["components", "_bundle", "catalysts"])
    end

    test "tenant-prefixed paths are not gated here; the global roots are the server's" do
      ctx = Context.build(user_id: "u", athanor_id: "ath_a", authenticated: true)
      assert :ok = Storage.authorize_path(ctx, ["builds", "b1", "started.json"])
      assert {:error, :forbidden} = Storage.authorize_path(ctx, ["cache", "oci", "x"])
      assert {:error, :forbidden} = Storage.authorize_path(ctx, ["system", "health"])
      assert :ok = Storage.authorize_path(Sanctum.system_context(), ["cache", "oci", "x"])
      assert :ok = Storage.authorize_path(Sanctum.system_context(), ["system", "health"])
    end
  end
end
