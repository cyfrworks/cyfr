# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ChainLoggingTest do
  @moduledoc """
  A chain is one ingress request and every call made beneath it, and the log
  has to show all of them.

  Every recorded call is one admission decision with its own row, under its
  own `call_` id; the calls of one chain share the outer request id for
  correlation, and an in-chain call names the call that admitted its
  calling execution as its parent.
  """
  use ExUnit.Case, async: false

  alias Grimoire.Probe
  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Sanctum.Context

  @node "formula:local.chain-logging"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Two of these tests read an athanor's whole log to prove what a call did
    # or did not write, so each works in a furnace of its own. The suite's
    # `ath_test` is shared by everything, and `mcp_logs` outlives a run that
    # was killed rather than rolled back — reading it would make these
    # assertions a claim about the database instead of about the code.
    n = System.unique_integer([:positive])

    {:ok, athanor} =
      Sanctum.Tenancy.Athanors.create(%{
        kind: "group",
        name: "Chain log #{n}",
        slug: "chain-log-#{n}",
        created_by: "system"
      })

    {:ok, ctx: %{Sanctum.TestContext.local() | athanor_id: athanor.id}}
  end

  defp authority_granting(pairs) do
    graph = %{
      "canonical" => "jcs-1",
      "nodes" => %{
        @node => %{
          "limits" => %{
            "timeout" => "1m",
            "max_memory_bytes" => 67_108_864,
            "max_request_size" => 1_048_576,
            "max_response_size" => 5_242_880,
            "rate_limit" => %{"requests" => 10_000, "window" => "1m"},
            "max_concurrent_tasks" => 10,
            "batch_timeout" => "1m"
          },
          "edges" => %{"@ingress" => %{"tools" => Enum.sort(pairs)}}
        }
      }
    }

    {:ok, blob} = Blob.parse(graph)

    {:ok, auth} =
      Authority.root(
        %{
          profile_id: "prof-chain",
          consent_id: "consent-chain",
          source_ref: @node,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{@node => "sha256:chain"}
        },
        blob,
        ceiling: Sanctum.Policy.Ceiling.platform_ceiling()
      )

    auth
  end

  defp rows_for(ctx, request_id) do
    {:ok, rows} =
      Arca.McpLog.list(
        request_id: request_id,
        athanor_id: ctx.athanor_id,
        limit: 100
      )

    rows
  end

  defp decisions_for(ctx, request_id) do
    {:ok, decisions} = Arca.DecisionLog.correlate(Sanctum.Context.actor(ctx), request_id)
    decisions
  end

  test "an in-chain call gets its own row under the request that started it, naming its parent",
       %{ctx: ctx} do
    request_id = Prima.UUID7.request_id()
    root_call_id = Prima.UUID7.generate_id("call")
    ctx = %{ctx | request_id: request_id}

    Grimoire.Catalog.with_providers([Probe.Typed], fn ->
      # The root call, as a transport hands it to the gate under the call
      # id its entry minted.
      {:ok, _} =
        Grimoire.call_external("typed_probe", ctx, %{"action" => "empty"}, call_id: root_call_id)

      # Now the component that call started runs and calls a tool from
      # inside the sandbox. Its context is the handler's with the plane
      # flipped — same request id, and the root's call id, which its
      # execution row records.
      guest = Context.enter_guest(%{ctx | call_id: root_call_id})
      lineage = Cyfr.Test.AttemptFixtures.lineage!(guest)

      assert %{call_id: ^root_call_id} =
               Arca.Execution.get_tenant(Context.actor(ctx), lineage.parent_execution_id)

      auth = authority_granting(["typed_probe.empty"])

      {:ok, _} =
        Grimoire.call_in_chain("typed_probe", guest, %{"action" => "empty"}, auth,
          lineage: Map.put(lineage, :call_id, root_call_id)
        )
    end)

    rows = rows_for(ctx, request_id)

    assert length(rows) == 2, "expected the request and the call it made, got #{length(rows)}"
    assert Enum.all?(rows, &(&1.request_id == request_id))
    assert Enum.all?(rows, &String.starts_with?(&1.id, "call_"))

    [root, in_chain] = Enum.sort_by(decisions_for(ctx, request_id), &(&1.call_id != root_call_id))

    # The root is its own call, sharing the request id with the call it made.
    assert root.call_id == root_call_id
    assert root.plane == :external
    assert root.parent_call_id == nil
    assert "req_" <> _ = root.request_id

    # The in-chain call is a call of its own, beneath the call that
    # admitted its calling execution.
    assert in_chain.call_id != root_call_id
    assert in_chain.plane == :in_chain
    assert in_chain.parent_call_id == root_call_id
    assert in_chain.request_id == request_id
    assert in_chain.completion == :succeeded

    by_id = Map.new(rows, &{&1.id, &1})
    assert by_id[in_chain.call_id].action == "empty"
    assert by_id[in_chain.call_id].status == "success"
  end

  test "a guest's own call id keys are dropped, never read as its parent", %{ctx: ctx} do
    request_id = Prima.UUID7.request_id()
    ctx = %{ctx | request_id: request_id}
    guest = Context.enter_guest(ctx)
    auth = authority_granting(["typed_probe.empty"])

    Grimoire.Catalog.with_providers([Probe.Typed], fn ->
      assert {:ok, echoed} =
               Grimoire.call_in_chain(
                 "typed_probe",
                 guest,
                 %{
                   "action" => "empty",
                   "call_id" => "call_forged",
                   "parent_call_id" => "call_forged"
                 },
                 auth,
                 lineage: Cyfr.Test.AttemptFixtures.lineage!(guest)
               )

      refute Map.has_key?(echoed, "call_id")
      refute Map.has_key?(echoed, "parent_call_id")
    end)

    assert [decision] = decisions_for(ctx, request_id)
    assert decision.parent_call_id == nil
    refute decision.call_id == "call_forged"
  end

  test "a transport's call is recorded once, by the gate", %{ctx: ctx} do
    request_id = Prima.UUID7.request_id()
    ctx = %{ctx | request_id: request_id}

    # The dispatch of that very request. It arrives with a request id
    # already on the context; the transport writes no row of its own.
    Grimoire.Catalog.with_providers([Probe.Typed], fn ->
      {:ok, _} = Grimoire.call_external("typed_probe", ctx, %{"action" => "empty"})
    end)

    assert [row] = rows_for(ctx, request_id)
    assert "call_" <> _ = row.id
    assert [%{call_id: call_id}] = decisions_for(ctx, request_id)
    assert call_id == row.id
  end

  test "an internal caller with no request id becomes its own root", %{ctx: ctx} do
    ctx = %{ctx | request_id: nil}

    Grimoire.Catalog.with_providers([Probe.Typed], fn ->
      {:ok, _} = Grimoire.call_external("typed_probe", ctx, %{"action" => "empty"})
    end)

    {:ok, rows} = Arca.McpLog.list(athanor_id: ctx.athanor_id, limit: 100)
    [row] = Enum.filter(rows, &(&1.tool == "typed_probe"))

    # It is a root: a call of its own, the first of a request of its own.
    assert "call_" <> _ = row.id
    assert "req_" <> _ = row.request_id
    assert [%{call_id: call_id}] = decisions_for(ctx, row.request_id)
    assert call_id == row.id
  end

  # Discovery and the log's own reads are not recorded: without that,
  # listing the log writes a row to the log.
  test "discovery and the log's own reads are not recorded", %{ctx: ctx} do
    ctx = %{ctx | request_id: nil}

    {:ok, _} = Grimoire.call_external("mcp_log", ctx, %{"action" => "list"})
    {:ok, _} = Grimoire.call_external("system", ctx, %{"action" => "status"})
    {:ok, _} = Grimoire.call_external("tools", ctx, %{"action" => "list"})

    assert Arca.McpLog.list(athanor_id: ctx.athanor_id, limit: 100) == {:ok, []},
           "a discovery or log read wrote a row to the log"

    assert {:ok, []} = Arca.DecisionLog.list(Sanctum.Context.actor(ctx))
  end
end
