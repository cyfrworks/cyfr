# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HttpHandlerEnforcementTest do
  @moduledoc """
  A runner reports each refusal of its egress checks through its attempt's
  host client, which holds no context of its own. CYFR records the policy
  decisions among them for the audit trail, in the attempt's athanor and
  for the attempt's component, and records nothing for a malformed request
  or a transport failure.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Test.AttemptFixtures
  alias Opus.HttpHandler
  alias Opus.Test.EdgeFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  # A real attached attempt for `component_ref` and its host client.
  defp attached(component_ref) do
    attempt = AttemptFixtures.attached!(component_ref: component_ref)

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

  # The guest-facing entry takes no resolver of its own: the handler's
  # egress resolves through `config :opus, :resolver`, set here to the
  # fixture's table for the rest of the test, so a name that does not
  # resolve is the table's nxdomain and not the public resolver's answer.
  # The module is sync, so no other test sees the seam set.
  defp resolve_through(resolver) do
    previous = Application.fetch_env(:opus, :resolver)
    Application.put_env(:opus, :resolver, resolver)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:opus, :resolver, value)
        :error -> Application.delete_env(:opus, :resolver)
      end
    end)
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

  test "a malformed request and a transport-level failure record nothing" do
    edge = EdgeFixtures.edge(domains: ["*"], methods: ["GET"])
    {attempt, host} = attached("catalyst:local.audited-dns:1.0.0")

    malformed = HttpHandler.execute("not json", edge, EdgeFixtures.limits(), host, "ref")
    assert %{"error" => %{"type" => "invalid_json"}} = Jason.decode!(malformed)

    resolve_through(Sanctum.Test.Resolver)
    request = Jason.encode!(%{"method" => "GET", "url" => "https://nonexistent.test/data"})

    result =
      HttpHandler.execute(request, edge, EdgeFixtures.limits(), host, attempt.component_ref)

    assert %{"error" => %{"type" => "dns_error", "message" => message}} = Jason.decode!(result)
    assert message =~ "nonexistent.test"
    assert rows_for(attempt) == []
  end

  test "a refusal reported for an attempt that is no longer held records nothing" do
    {attempt, host} = attached("catalyst:local.audited-closed:1.0.0")
    assert {:ok, %{cancelled: true}} = Cyfr.Execution.cancel(attempt.ctx, attempt.execution_id)

    assert {:error, :lost} = Opus.HostClient.record_denial(host, "domain_blocked", "blocked")
    assert rows_for(attempt) == []
  end
end
