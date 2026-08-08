# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HttpHandlerEnforcementTest do
  use ExUnit.Case, async: false

  alias Opus.HttpHandler
  alias Opus.Test.EdgeFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp rows_for(ctx, component_ref) do
    [org_id: ctx.org_id, project_id: ctx.project_id, limit: 50]
    |> Arca.PolicyLog.list()
    |> Enum.filter(&(&1.component_ref == component_ref))
  end

  test "blocked egress domain records a domain_blocked enforcement row", %{ctx: ctx} do
    edge = EdgeFixtures.edge(domains: ["api.example.com"], methods: ["GET"])
    ref = "catalyst:local.audited-egress:1.0.0"

    request = Jason.encode!(%{"method" => "GET", "url" => "https://evil.example.net/data"})
    result = HttpHandler.execute(request, edge, EdgeFixtures.limits(), ctx, ref)

    assert %{"error" => %{"type" => "domain_blocked"}} = Jason.decode!(result)

    assert [row] = rows_for(ctx, ref)
    assert row.event_type == "domain_blocked"
    assert row.decision == "denied"
    assert row.component_type == "catalyst"
  end

  test "blocked egress method records a method_blocked enforcement row", %{ctx: ctx} do
    edge = EdgeFixtures.edge(domains: ["api.example.com"], methods: ["GET"])
    ref = "catalyst:local.audited-method:1.0.0"

    request = Jason.encode!(%{"method" => "DELETE", "url" => "https://api.example.com/data"})
    result = HttpHandler.execute(request, edge, EdgeFixtures.limits(), ctx, ref)

    assert %{"error" => %{"type" => "method_blocked"}} = Jason.decode!(result)

    assert [row] = rows_for(ctx, ref)
    assert row.event_type == "method_blocked"
    assert row.decision == "denied"
  end

  test "transport-level failures record nothing", %{ctx: ctx} do
    edge = EdgeFixtures.edge(domains: ["*"], methods: ["GET"])
    ref = "catalyst:local.audited-dns:1.0.0"

    request =
      Jason.encode!(%{"method" => "GET", "url" => "https://nonexistent.invalid/data"})

    result = HttpHandler.execute(request, edge, EdgeFixtures.limits(), ctx, ref)

    assert %{"error" => %{"type" => type}} = Jason.decode!(result)
    assert type in ["dns_error", "http_error"]
    assert rows_for(ctx, ref) == []
  end
end
