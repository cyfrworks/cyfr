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
    test "single-user layout: org 'local' → data/local/default (namespace not in path)" do
      ctx =
        Context.build(
          user_id: "user_1",
          namespace: "alice",
          authenticated: true
        )

      # org_id defaults to the seeded "local" sentinel; namespace is identity-only.
      assert Storage.tenant_segments(ctx) == ["local", "default"]
    end

    test "multi-tenant layout: real org_id and project_id flow through" do
      ctx =
        Context.build(
          user_id: "user_1",
          namespace: "alice",
          org_id: "acme-corp",
          project_id: "widgets",
          authenticated: true
        )

      # namespace ("alice") is identity-only and does NOT appear in the path.
      assert Storage.tenant_segments(ctx) == ["acme-corp", "widgets"]
    end

    test "namespace is ignored — org/project alone determine the path" do
      with_ns =
        Context.build(user_id: "u", namespace: "alice", org_id: "acme", authenticated: true)

      without_ns = Context.build(user_id: "u", org_id: "acme", authenticated: true)

      assert Storage.tenant_segments(with_ns) == Storage.tenant_segments(without_ns)
      assert Storage.tenant_segments(with_ns) == ["acme", "default"]
    end

    test "raises when org_id is org-less (fail closed)" do
      # A resolved org_id is required to name a tenant directory; a nil means a
      # caller bypassed the Sanctum.Context.require_tenant! chokepoint.
      ctx = Context.build(user_id: "user_1", org_id: nil, authenticated: false)

      assert_raise ArgumentError, ~r/a resolved org_id is required/, fn ->
        Storage.tenant_segments(ctx)
      end
    end

    test "rejects path traversal in org_id" do
      ctx =
        Context.build(
          user_id: "user_1",
          namespace: "alice",
          org_id: "..",
          project_id: "widgets",
          authenticated: true
        )

      assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
        Storage.tenant_segments(ctx)
      end
    end

    test "rejects path traversal in project_id" do
      ctx =
        Context.build(
          user_id: "user_1",
          namespace: "alice",
          org_id: "acme",
          project_id: "..",
          authenticated: true
        )

      assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
        Storage.tenant_segments(ctx)
      end
    end

    test "system-style context resolves by org/project, ignoring namespace" do
      ctx =
        Context.build(
          user_id: "system",
          namespace: "_system",
          authenticated: true
        )

      # org defaults to "local"; the "_system" namespace is identity-only.
      assert Storage.tenant_segments(ctx) == ["local", "default"]
    end
  end
end
