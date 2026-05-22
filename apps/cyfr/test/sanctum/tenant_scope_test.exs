# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TenantScopeTest do
  use ExUnit.Case, async: true

  alias Sanctum.Context
  alias Sanctum.TenantScope

  # Characterization of the single tenant-scope chokepoint that Secrets and
  # OAuth delegate to. `Sanctum.TenantPolicy` rejects nil/"" org_id; an
  # org-bearing context resolves to its {scope, org, project} triple.

  describe "extract/1 — resolved-tenant path" do
    test "TestContext.local/0 yields {\"project\", \"local\", \"default\"}" do
      # local/0 carries org_id "local", project_id "default", scope :project.
      assert TenantScope.extract(Sanctum.TestContext.local()) == {"project", "local", "default"}
    end

    test "nil project_id defaults to \"default\"" do
      ctx = %Context{scope: :project, org_id: "o", project_id: nil}
      assert TenantScope.extract(ctx) == {"project", "o", "default"}
    end

    test "present project_id passes through unchanged" do
      ctx = %Context{scope: :project, org_id: "o", project_id: "p"}
      assert TenantScope.extract(ctx) == {"project", "o", "p"}
    end

    test "scope is stringified (:org)" do
      ctx =
        Context.build(
          user_id: "u",
          namespace: "ns",
          org_id: "acme",
          scope: :org,
          authenticated: true
        )

      assert {"org", "acme", "default"} = TenantScope.extract(ctx)
    end

    test "platform context: scope \"platform\", org_id stays nil" do
      assert TenantScope.extract(Sanctum.system_context()) == {"platform", nil, "default"}
    end
  end

  describe "extract/1 — contradictory shape" do
    test "scope: :org with nil org_id raises ArgumentError" do
      ctx = %Context{scope: :org, org_id: nil, project_id: "p"}

      assert_raise ArgumentError, ~r/org_id cannot be nil when scope is :org/, fn ->
        TenantScope.extract(ctx)
      end
    end
  end

  describe "extract/1 — platform mode (strict tenant policy)" do
    test "org-less non-platform context fails closed (UnauthorizedError)" do
      (fn ->         assert_raise Sanctum.UnauthorizedError, fn ->
          TenantScope.extract(Sanctum.TestContext.local())
        end
      end)
    end

    test "platform scope still bypasses the strict gate" do
      (fn ->         assert TenantScope.extract(Sanctum.system_context()) == {"platform", nil, "default"}
      end)
    end

    test "a resolved org passes the strict gate" do
      (fn ->         ctx =
          Context.build(
            user_id: "u",
            namespace: "ns",
            org_id: "acme",
            project_id: "p",
            scope: :project,
            authenticated: true
          )

        assert TenantScope.extract(ctx) == {"project", "acme", "p"}
      end)
    end
  end
end
