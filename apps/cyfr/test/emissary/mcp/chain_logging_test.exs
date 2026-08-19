# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ChainLoggingTest do
  @moduledoc """
  A chain is one ingress request and every call made beneath it, and the log
  has to show all of them.

  It used not to. `mcp_logs.id` was the request id, so a second row could not
  be written under one request, and the dispatcher skipped logging whenever the
  context already carried a request id — which an in-chain call always does,
  having inherited it through the guest closure. A formula that called
  `files.write` and `http.fetch` left one row behind: the `execution.run` that
  started it.
  """
  use ExUnit.Case, async: false

  alias Emissary.MCP.ToolRegistry
  alias Sanctum.Authority
  alias Sanctum.Authority.Blob
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
        blob
      )

    auth
  end

  defp rows_for(ctx, request_id) do
    Arca.McpLog.list(
      request_id: request_id,
      athanor_id: ctx.athanor_id,
      limit: 100
    )
  end

  test "an in-chain call gets its own row, filed under the request that started it", %{ctx: ctx} do
    request_id = Emissary.UUID7.request_id()
    ctx = %{ctx | request_id: request_id}

    # The transport's own row, as `EmissaryWeb.MCPController` writes it: the
    # call id *is* the request id, because this call is the request.
    :ok =
      Emissary.MCP.RequestLog.log_started(ctx, request_id, %{
        tool: "execution",
        action: "run",
        method: "tools/call"
      })

    # Now the component runs and calls a tool from inside the sandbox. Its
    # context is the caller's with the plane flipped — same request id.
    guest = Context.enter_guest(ctx)
    auth = authority_granting(["system.status"])

    {:ok, _} = ToolRegistry.call_in_chain("system", guest, %{"action" => "status"}, auth)

    rows = rows_for(ctx, request_id)

    assert length(rows) == 2, "expected the request and the call it made, got #{length(rows)}"
    assert Enum.all?(rows, &(&1.request_id == request_id))

    # Each row is its own call, and only the root's id is the request id.
    ids = Enum.map(rows, & &1.id)
    assert request_id in ids
    assert Enum.any?(ids, &String.starts_with?(&1, "call_"))

    by_tool = Map.new(rows, &{&1.tool, &1})
    assert by_tool["execution"].id == request_id
    assert by_tool["system"].action == "status"
    assert by_tool["system"].status == "success"
  end

  test "a call the transport already logged is not logged twice", %{ctx: ctx} do
    request_id = Emissary.UUID7.request_id()
    ctx = %{ctx | request_id: request_id}

    :ok =
      Emissary.MCP.RequestLog.log_started(ctx, request_id, %{
        tool: "system",
        action: "status",
        method: "tools/call"
      })

    # The dispatch of that very request. It arrives with a request id already
    # on the context and is not in-chain, so the transport owns its row.
    {:ok, _} = ToolRegistry.call_external("system", ctx, %{"action" => "status"})

    assert length(rows_for(ctx, request_id)) == 1
  end

  test "an internal caller with no request id becomes its own root", %{ctx: ctx} do
    ctx = %{ctx | request_id: nil}

    {:ok, _} = ToolRegistry.call_external("system", ctx, %{"action" => "status"})

    [row] =
      Arca.McpLog.list(athanor_id: ctx.athanor_id, limit: 100)
      |> Enum.filter(&(&1.tool == "system"))

    # It is a root: the row's id and its chain key are the same value.
    assert row.request_id == row.id
    assert String.starts_with?(row.id, "req_")
  end

  # `mcp_log` is not in-chain reachable, so the exemption only ever applies on
  # the external path — where an internal caller would otherwise be its own
  # root and log. Without it, listing the log writes a row to the log.
  test "mcp_log never logs itself", %{ctx: ctx} do
    ctx = %{ctx | request_id: nil}

    {:ok, _} = ToolRegistry.call_external("mcp_log", ctx, %{"action" => "list"})

    assert Arca.McpLog.list(athanor_id: ctx.athanor_id, limit: 100) == [],
           "listing the log wrote a row to the log"
  end
end
