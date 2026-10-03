# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HttpHandlerEnforcementTest do
  @moduledoc """
  A runner reports each refusal of its egress checks through its attempt's
  host client, which holds no context of its own. CYFR records the policy
  decisions among them for the audit trail, in the attempt's athanor and
  for the attempt's component: its own edge checks and, since the engine
  resolves nothing, the pin the control plane refuses for a name that does
  not resolve. It records nothing for a malformed request.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Test.AttemptFixtures
  alias Opus.HttpHandler
  alias Opus.Test.EdgeFixtures

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    :ok
  end

  # A real attached attempt for `component_ref` and its host client.
  # The control plane's own domain check runs before any resolution, so the
  # attempt's authority must allow every host these requests name for the
  # engine's edge, the resolver and the method check to be what decides.
  defp attached(component_ref) do
    egress = %{domains: ["*"], methods: [], schemes: [], private_ips: []}

    attempt =
      AttemptFixtures.attached!(
        ctx: Sanctum.TestContext.local(:api),
        component_ref: component_ref,
        authority: %{
          Prima.Authority.zero()
          | resources: %Prima.Authority.Blob.Edge{egress: egress}
        }
      )

    {attempt,
     Opus.HostClient.new(attempt.keys, attempt.runner, attempt.boot, %{
       member: attempt.member,
       host_url: Cyfr.Test.OpusService.host_url()
     })}
  end

  defp rows_for(attempt) do
    [athanor_id: attempt.athanor_id, limit: 50]
    |> Arca.PolicyLog.list()
    |> then(fn {:ok, rows} -> rows end)
    |> Enum.filter(&(&1.component_ref == attempt.component_ref))
  end

  test "blocked egress domain records a domain_blocked enforcement row" do
    edge = EdgeFixtures.edge(domains: ["api.example.com"], methods: ["GET"])
    {attempt, host} = attached("catalyst:local.audited-egress:1.0.0")

    request = Jason.encode!(%{"method" => "GET", "url" => "https://evil.example.net/data"})
    result = HttpHandler.execute(request, edge, EdgeFixtures.limits(), host, "catalyst:any")

    assert %{"error" => %{"type" => "domain_blocked"}} = Jason.decode!(result)

    assert [row] = rows_for(attempt)
    assert row.event_type == "domain_blocked"
    assert row.decision == "denied"
    assert row.component_type == "catalyst"
    assert row.decision_reason =~ "evil.example.net"
  end

  test "blocked egress method records a method_blocked enforcement row" do
    edge = EdgeFixtures.edge(domains: ["api.example.com"], methods: ["GET"])
    {attempt, host} = attached("catalyst:local.audited-method:1.0.0")

    request = Jason.encode!(%{"method" => "DELETE", "url" => "https://api.example.com/data"})

    result =
      HttpHandler.execute(request, edge, EdgeFixtures.limits(), host, attempt.component_ref)

    assert %{"error" => %{"type" => "method_blocked"}} = Jason.decode!(result)

    assert [row] = rows_for(attempt)
    assert row.event_type == "method_blocked"
    assert row.decision == "denied"
  end

  test "a malformed request records nothing, and a name the control plane cannot pin is its denial" do
    edge = EdgeFixtures.edge(domains: ["*"], methods: ["GET"])
    {attempt, host} = attached("catalyst:local.audited-dns:1.0.0")

    malformed = HttpHandler.execute("not json", edge, EdgeFixtures.limits(), host, "ref")
    assert %{"error" => %{"type" => "invalid_json"}} = Jason.decode!(malformed)
    assert rows_for(attempt) == []

    # `.test` is reserved and never resolves (RFC 6761): the pin the engine
    # asks the control plane for is refused as a resolution failure, which
    # the guest sees as a DNS error and the control plane records as the
    # attempt's denial, naming the host.
    request = Jason.encode!(%{"method" => "GET", "url" => "https://nonexistent.test/data"})

    result =
      HttpHandler.execute(request, edge, EdgeFixtures.limits(), host, attempt.component_ref)

    assert %{"error" => %{"type" => "dns_error", "message" => message}} = Jason.decode!(result)
    assert message =~ "nonexistent.test"

    assert [row] = rows_for(attempt)
    assert row.decision == "denied"
    assert row.decision_reason =~ "nonexistent.test"
  end

  test "a refusal reported for an attempt that is no longer held records nothing" do
    {attempt, host} = attached("catalyst:local.audited-closed:1.0.0")
    assert {:ok, %{cancelled: true}} = Crucible.cancel(attempt.ctx, attempt.execution_id)

    assert {:error, :lost} = Opus.HostClient.record_denial(host, "domain_blocked", "blocked")
    assert rows_for(attempt) == []
  end
end
