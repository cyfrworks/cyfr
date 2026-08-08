# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.PolicyEnforcerTest do
  # Only the %Policy{} predicate half of the enforcer exists: the resolver
  # half (validate_execution/get_policy/build_execution_opts) died with the
  # profile-less execution path. The predicates are consumed by the HTTP
  # stream handler against the authority shim's edge-derived policy.
  use ExUnit.Case, async: false

  alias Opus.PolicyEnforcer
  alias Sanctum.Policy

  describe "check_domain/2" do
    test "allows exact domain match" do
      policy = %Policy{allowed_domains: ["api.stripe.com"]}
      assert :ok = PolicyEnforcer.check_domain(policy, "api.stripe.com")
    end

    test "allows wildcard domain match" do
      policy = %Policy{allowed_domains: ["*.stripe.com"]}
      assert :ok = PolicyEnforcer.check_domain(policy, "api.stripe.com")
    end

    test "rejects unauthorized domains" do
      policy = %Policy{allowed_domains: ["api.stripe.com"]}

      assert {:error, reason} = PolicyEnforcer.check_domain(policy, "evil.com")
      assert reason =~ "Policy violation - domain \"evil.com\" not in allowed_domains"
      assert reason =~ "Allowed: api.stripe.com"
    end

    test "rejects all domains when empty" do
      policy = %Policy{allowed_domains: []}

      assert {:error, _reason} = PolicyEnforcer.check_domain(policy, "any.com")
    end
  end

  describe "check_scheme/2" do
    test "allows a listed scheme" do
      policy = %Policy{allowed_schemes: ["https"]}
      assert :ok = PolicyEnforcer.check_scheme(policy, "https")
    end

    test "rejects an unlisted scheme" do
      policy = %Policy{allowed_schemes: ["https"]}

      assert {:error, reason} = PolicyEnforcer.check_scheme(policy, "http")
      assert reason =~ "scheme \"http\" not in allowed_schemes"
    end
  end

  describe "check_method/2" do
    test "allows a listed method" do
      policy = %Policy{allowed_methods: ["GET", "POST"]}
      assert :ok = PolicyEnforcer.check_method(policy, "GET")
    end

    test "rejects an unlisted method" do
      policy = %Policy{allowed_methods: ["GET"]}

      assert {:error, reason} = PolicyEnforcer.check_method(policy, "DELETE")
      assert reason =~ "method \"DELETE\" not in allowed_methods"
    end
  end

  describe "check_http_request/3" do
    test "requires both domain and method to pass" do
      policy = %Policy{allowed_domains: ["api.stripe.com"], allowed_methods: ["GET"]}

      assert :ok = PolicyEnforcer.check_http_request(policy, "api.stripe.com", "GET")
      assert {:error, _} = PolicyEnforcer.check_http_request(policy, "evil.com", "GET")
      assert {:error, _} = PolicyEnforcer.check_http_request(policy, "api.stripe.com", "DELETE")
    end
  end
end
