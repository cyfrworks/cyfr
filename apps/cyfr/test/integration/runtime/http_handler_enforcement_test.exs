# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.EgressDenialTest do
  @moduledoc """
  A runner reports each refusal of its egress checks with its attempt's
  `record_denial` host call, which holds no context of its own. CYFR
  records the policy decisions among them for the audit trail, once each,
  in the attempt's athanor and for the attempt's component, and records
  nothing for a refusal that is no policy decision, such as a request's
  shape, or for an attempt it no longer holds. Since the engine resolves
  nothing, the pin CYFR refuses for a name that does not resolve is its own
  denial of the attempt, naming the host.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Test.{AttemptFixtures, HostCaller, RuntimeService}

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    :ok
  end

  # A real attached attempt for `component_ref`. The control plane's own
  # domain check runs before any resolution, so the attempt's authority
  # allows every host these calls name, for the resolver to be what decides.
  defp attached(component_ref) do
    egress = %{domains: ["*"], methods: [], schemes: [], private_ips: []}

    AttemptFixtures.attached!(
      ctx: Sanctum.TestContext.local(:api),
      component_ref: component_ref,
      authority: %{
        Prima.Authority.zero()
        | resources: %Prima.Authority.Blob.Edge{egress: egress}
      }
    )
  end

  defp call(attempt, op, args), do: HostCaller.call(attempt, RuntimeService.host_url(), op, args)

  defp denial(attempt, type, message),
    do: call(attempt, :record_denial, %{"type" => type, "message" => message})

  defp rows_for(attempt) do
    attempt.athanor_id
    |> Prima.Actor.in_athanor()
    |> Arca.PolicyLog.list(limit: 50)
    |> then(fn {:ok, rows} -> rows end)
    |> Enum.filter(&(&1.component_ref == attempt.component_ref))
  end

  test "a reported domain refusal records one domain_blocked enforcement row" do
    attempt = attached("catalyst:local.audited-egress:1.0.0")

    assert {:ok, true} =
             denial(attempt, "domain_blocked", "host evil.example.net is not allowed")

    assert [row] = rows_for(attempt)
    assert row.event_type == "domain_blocked"
    assert row.decision == "denied"
    assert row.component_type == "catalyst"
    assert row.decision_reason =~ "evil.example.net"
  end

  test "a reported method refusal records one method_blocked enforcement row" do
    attempt = attached("catalyst:local.audited-method:1.0.0")

    assert {:ok, true} = denial(attempt, "method_blocked", "method DELETE is not allowed")

    assert [row] = rows_for(attempt)
    assert row.event_type == "method_blocked"
    assert row.decision == "denied"
  end

  test "a reported credential-header refusal is no policy decision, and records nothing" do
    attempt = attached("catalyst:local.audited-shape:1.0.0")

    assert {:ok, true} =
             denial(
               attempt,
               "credential_header_refused",
               Prima.Refusal.message(:credential_header_refused)
             )

    assert rows_for(attempt) == []
  end

  test "a name the control plane cannot pin is its denial, naming the host" do
    attempt = attached("catalyst:local.audited-dns:1.0.0")

    # `.test` is reserved and never resolves (RFC 6761): the pin the engine
    # asks the control plane for is refused as a resolution failure, which
    # the control plane records as the attempt's denial, naming the host.
    assert {:error, "resolution", _fields} =
             call(attempt, :egress_pin, %{
               "url" => "https://nonexistent.test/data",
               "purpose" => "fetch"
             })

    assert [row] = rows_for(attempt)
    assert row.decision == "denied"
    assert row.decision_reason =~ "nonexistent.test"
  end

  test "a refusal reported for an attempt that is no longer held records nothing" do
    attempt = attached("catalyst:local.audited-closed:1.0.0")
    assert {:ok, %{cancelled: true}} = Opus.cancel(attempt.ctx, attempt.execution_id)

    assert {:error, "lost", _fields} = denial(attempt, "domain_blocked", "blocked")
    assert rows_for(attempt) == []
  end
end
