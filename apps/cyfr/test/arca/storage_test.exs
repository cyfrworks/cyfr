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

  describe "physical_segments/2" do
    defp ath_ctx do
      Context.build(user_id: "u", athanor_id: "ath_x", authenticated: true)
    end

    test "everything an athanor owns lives under athanors/{id} — the context's id" do
      assert Storage.physical_segments(ath_ctx(), ["components", "tinctures"]) ==
               ["athanors", "ath_x", "components", "tinctures"]

      assert Storage.physical_segments(ath_ctx(), ["notes", "a.txt"]) ==
               ["athanors", "ath_x", "data", "notes", "a.txt"]
    end

    test "the guest data scope nests under the athanor's data root" do
      # ["data" | rest] is a tenant-relative prefix like any other, so it
      # lands at athanors/{id}/data/data/… — collapsing that nesting would
      # alias the guest scope onto the whole data root (aqua/, config/, …).
      assert Storage.physical_segments(ath_ctx(), ["data", "notes.txt"]) ==
               ["athanors", "ath_x", "data", "data", "notes.txt"]
    end

    test "the empty path is the athanor's data root, disjoint from components" do
      # Caps.data_bytes/1 walks []; the trailing "data" keeps that walk from
      # double-counting the components subtree.
      assert Storage.physical_segments(ath_ctx(), []) == ["athanors", "ath_x", "data"]
    end

    test "globals stay at the storage root" do
      assert Storage.physical_segments(ath_ctx(), ["cache", "oci", "d"]) == ["cache", "oci", "d"]

      assert Storage.physical_segments(ath_ctx(), ["system", "health", ".write_probe"]) ==
               ["system", "health", ".write_probe"]
    end

    test "the seed bundle is not tenant storage" do
      assert_raise ArgumentError, ~r/bundle/, fn ->
        Storage.physical_segments(ath_ctx(), ["components", "_bundle", "x"])
      end
    end

    test "the bare components root is the athanor's own components subtree" do
      assert Storage.physical_segments(ath_ctx(), ["components"]) ==
               ["athanors", "ath_x", "components"]
    end

    test "a context without an athanor cannot name a component path (fail closed)" do
      ctx = Context.build(user_id: "op", scope: :platform, athanor_id: nil, authenticated: true)

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        Storage.physical_segments(ctx, ["components", "tinctures"])
      end
    end
  end

  describe "global_prefixes/0" do
    test "returns expected prefixes" do
      prefixes = Storage.global_prefixes()
      assert "cache" in prefixes
      assert "system" in prefixes
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
    test "an athanor's component tree is its own — the path is tenant-relative" do
      ctx = Context.build(user_id: "u", athanor_id: "ath_a", authenticated: true)
      assert :ok = Storage.authorize_path(ctx, ["components", "catalysts", "local"])
      assert :ok = Storage.authorize_path(ctx, ["components"])
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
