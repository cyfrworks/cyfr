# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Opus.AuthorityShimTest do
  use ExUnit.Case, async: true

  alias Opus.AuthorityShim
  alias Sanctum.Authority
  alias Sanctum.Authority.Transition
  alias Sanctum.Test.AuthorityFixtures, as: Fixtures

  describe "policy_from_edge/1" do
    test "a root's ingress edge maps to its resources under its node limits" do
      auth = Fixtures.root!()
      policy = AuthorityShim.policy_from_edge(auth)

      assert policy.allowed_tools == ["storage.read"]
      # The ingress edge grants no egress or storage: everything denies,
      # including schemes — an edge-derived policy is never nil-scheme.
      assert policy.allowed_domains == []
      assert policy.allowed_schemes == []
      assert policy.allowed_paths == []
      assert policy.allowed_actions == []
      assert policy.timeout == "15m"
      assert policy.max_concurrent_tasks == 30
      refute policy.is_public
    end

    test "a bound child runs under the edge's resources and the callee's limits" do
      auth = Fixtures.root!()

      {:child, child} =
        Transition.step(
          auth,
          :call,
          Fixtures.invoke(Fixtures.catalyst_ref(),
            need: "source",
            declared_needs: Fixtures.formula_needs()
          )
        )

      policy = AuthorityShim.policy_from_edge(child)

      assert policy.allowed_domains == ["prod.supabase.co"]
      assert policy.allowed_schemes == ["https"]
      assert policy.allowed_tools == ["storage.read", "storage.write"]
      # The callee node's own limits, not the caller's.
      assert policy.timeout == "30s"
    end

    test "a zero authority denies everything under the zero limits" do
      policy = AuthorityShim.policy_from_edge(Authority.zero())

      assert policy.allowed_domains == []
      assert policy.allowed_methods == []
      assert policy.allowed_schemes == []
      assert policy.allowed_paths == []
      assert policy.allowed_actions == []
      assert policy.allowed_tools == []
      assert policy.timeout == "30s"
      assert policy.max_concurrent_tasks == 1
      assert policy.rate_limit == %{requests: 100, window: "1m"}
    end
  end

  describe "scheme enforcement through the HTTP handler" do
    test "a scheme outside the edge's allowlist is blocked before any I/O" do
      policy = %Sanctum.Policy{
        allowed_methods: ["GET"],
        allowed_domains: ["example.com"],
        allowed_schemes: ["https"]
      }

      ctx = %Sanctum.Context{user_id: "shim_test", org_id: "local", project_id: "default"}

      response =
        Opus.HttpHandler.execute(
          ~s({"method":"GET","url":"http://example.com/"}),
          policy,
          ctx,
          "catalyst:local.shim-test"
        )

      assert %{"error" => %{"type" => "scheme_blocked"}} = Jason.decode!(response)
    end

    test "a nil scheme allowlist keeps legacy behavior (no scheme check)" do
      # Domain not in the allowlist: the request must die at domain_blocked,
      # proving the scheme check passed it through.
      policy = %Sanctum.Policy{allowed_methods: ["GET"], allowed_domains: ["example.com"]}
      ctx = %Sanctum.Context{user_id: "shim_test", org_id: "local", project_id: "default"}

      response =
        Opus.HttpHandler.execute(
          ~s({"method":"GET","url":"ftp://other.example/"}),
          policy,
          ctx,
          "catalyst:local.shim-test"
        )

      assert %{"error" => %{"type" => "domain_blocked"}} = Jason.decode!(response)
    end
  end
end
