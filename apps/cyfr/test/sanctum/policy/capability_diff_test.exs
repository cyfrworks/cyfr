# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Policy.CapabilityDiffTest do
  use ExUnit.Case, async: true

  alias Sanctum.Policy.CapabilityDiff

  describe "diff/2" do
    test "nil old to new returns all new capability keys" do
      new = %{
        "allowed_domains" => ["api.stripe.com"],
        "allowed_methods" => ["GET"]
      }

      assert CapabilityDiff.diff(nil, new) == ["allowed_domains", "allowed_methods"]
    end

    test "old to new with added keys returns only new keys" do
      old = %{"allowed_domains" => ["api.stripe.com"]}

      new = %{
        "allowed_domains" => ["api.stripe.com"],
        "allowed_paths" => ["data/"],
        "allowed_methods" => ["GET", "POST"]
      }

      assert CapabilityDiff.diff(old, new) == ["allowed_methods", "allowed_paths"]
    end

    test "same keys returns empty list" do
      policy = %{
        "allowed_domains" => ["api.stripe.com"],
        "allowed_methods" => ["GET"]
      }

      assert CapabilityDiff.diff(policy, policy) == []
    end

    test "fewer keys in new returns empty list" do
      old = %{
        "allowed_domains" => ["api.stripe.com"],
        "allowed_methods" => ["GET"],
        "allowed_paths" => ["data/"]
      }

      new = %{"allowed_domains" => ["api.stripe.com"]}

      assert CapabilityDiff.diff(old, new) == []
    end

    test "nil new returns empty list" do
      old = %{"allowed_domains" => ["api.stripe.com"]}
      assert CapabilityDiff.diff(old, nil) == []
    end

    test "both nil returns empty list" do
      assert CapabilityDiff.diff(nil, nil) == []
    end

    test "ignores non-capability keys" do
      old = %{"timeout" => "30s"}
      new = %{"timeout" => "60s", "custom_field" => "value"}

      assert CapabilityDiff.diff(old, new) == []
    end

    test "detects all capability field types" do
      old = %{}

      new = %{
        "allowed_domains" => [],
        "allowed_methods" => [],
        "allowed_paths" => [],
        "allowed_actions" => [],
        "allowed_private_ips" => [],
        "allowed_tools" => [],
        "batch_timeout" => "5m",
        "max_concurrent_tasks" => 10
      }

      result = CapabilityDiff.diff(old, new)

      assert "allowed_domains" in result
      assert "allowed_methods" in result
      assert "allowed_paths" in result
      assert "allowed_actions" in result
      assert "allowed_private_ips" in result
      assert "allowed_tools" in result
      assert "batch_timeout" in result
      assert "max_concurrent_tasks" in result
    end
  end
end
