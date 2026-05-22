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
    test "Core layout: org_id is nil so namespace fills the org slot" do
      ctx =
        Context.build(
          user_id: "user_1",
          namespace: "alice",
          authenticated: true
        )

      assert Storage.tenant_segments(ctx) == ["alice", "default", "alice"]
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

      assert Storage.tenant_segments(ctx) == ["acme-corp", "widgets", "alice"]
    end

    test "raises when namespace is nil" do
      # Context.build now blocks nil namespace at construction time for
      # authenticated contexts. tenant_segments/1 still has its own guard
      # as defense-in-depth — exercise it by constructing an unauthenticated
      # context (which build allows through) and then calling segments.
      ctx = Context.build(user_id: "user_1", authenticated: false)

      assert_raise ArgumentError, ~r/requires Context.namespace to be set/, fn ->
        Storage.tenant_segments(ctx)
      end
    end

    test "raises when namespace is empty string" do
      ctx = Context.build(user_id: "user_1", namespace: "", authenticated: false)

      assert_raise ArgumentError, ~r/requires Context.namespace to be set/, fn ->
        Storage.tenant_segments(ctx)
      end
    end

    test "rejects path traversal in namespace (defense-in-depth)" do
      ctx =
        Context.build(
          user_id: "user_1",
          namespace: "..",
          authenticated: true
        )

      assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
        Storage.tenant_segments(ctx)
      end
    end

    test "rejects null bytes in namespace" do
      ctx =
        Context.build(
          user_id: "user_1",
          namespace: "alice\0evil",
          authenticated: true
        )

      assert_raise ArgumentError, ~r/null bytes/, fn ->
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

    test "system sentinel namespace passes validation" do
      ctx =
        Context.build(
          user_id: "system",
          namespace: "_system",
          authenticated: true
        )

      assert Storage.tenant_segments(ctx) == ["_system", "default", "_system"]
    end
  end
end
