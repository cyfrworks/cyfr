# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ChainScopeTest do
  # Cancel, logs and list are chain-scoped for in-chain callers: a running
  # component reaches its own subtree, never a sibling's execution or the
  # operator's. External-plane callers keep the tenant-wide view — members
  # of a project are interchangeable there by design.
  use ExUnit.Case, async: false

  alias Opus.ExecutionRecord

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp record!(ctx, opts) do
    record = ExecutionRecord.new(ctx, "reagent:local.scoped:1.0.0", %{}, opts)
    :ok = ExecutionRecord.write_started(record)
    record
  end

  describe "root_execution_id stamping" do
    test "a root stamps itself; a child carries the root", %{ctx: ctx} do
      root = record!(ctx, component_type: :formula)
      assert root.root_execution_id == root.id

      child =
        record!(ctx, parent_execution_id: root.id, root_execution_id: root.id)

      assert child.root_execution_id == root.id
      refute child.id == root.id

      {:ok, reloaded} = ExecutionRecord.get(ctx, child.id)
      assert reloaded.root_execution_id == root.id
    end
  end

  describe "in-chain scope" do
    setup %{ctx: ctx} do
      root = record!(ctx, component_type: :formula)
      child = record!(ctx, parent_execution_id: root.id, root_execution_id: root.id)
      stranger = record!(ctx, component_type: :formula)

      {:ok, root: root, child: child, stranger: stranger}
    end

    test "logs reach own-chain rows and refuse strangers",
         %{ctx: ctx, root: root, child: child, stranger: stranger} do
      lineage = %{"root_execution_id" => root.id}

      assert {:ok, %{execution_id: id}} =
               Opus.MCP.handle(
                 "execution",
                 ctx,
                 Map.merge(%{"action" => "logs", "execution_id" => child.id}, lineage)
               )

      assert id == child.id

      # The root itself is in its own chain.
      assert {:ok, _} =
               Opus.MCP.handle(
                 "execution",
                 ctx,
                 Map.merge(%{"action" => "logs", "execution_id" => root.id}, lineage)
               )

      assert {:error, message} =
               Opus.MCP.handle(
                 "execution",
                 ctx,
                 Map.merge(%{"action" => "logs", "execution_id" => stranger.id}, lineage)
               )

      assert message =~ "not found in this chain"
    end

    test "cancel refuses a stranger's execution", %{ctx: ctx, root: root, stranger: stranger} do
      assert {:error, message} =
               Opus.MCP.handle("execution", ctx, %{
                 "action" => "cancel",
                 "execution_id" => stranger.id,
                 "root_execution_id" => root.id
               })

      assert message =~ "not found in this chain"

      {:ok, untouched} = ExecutionRecord.get(ctx, stranger.id)
      assert untouched.status == :running
    end

    test "list is filtered to the caller's subtree",
         %{ctx: ctx, root: root, child: child, stranger: stranger} do
      {:ok, %{executions: scoped}} =
        Opus.MCP.handle("execution", ctx, %{
          "action" => "list",
          "root_execution_id" => root.id
        })

      ids = Enum.map(scoped, & &1.execution_id)
      assert root.id in ids
      assert child.id in ids
      refute stranger.id in ids
    end

    test "a legacy row with no stamped root fails closed for in-chain callers",
         %{ctx: ctx, root: root} do
      legacy = record!(ctx, component_type: :formula)

      import Ecto.Query

      Arca.Repo.update_all(
        from(e in Arca.Execution, where: e.id == ^legacy.id),
        set: [root_execution_id: nil]
      )

      assert {:error, message} =
               Opus.MCP.handle("execution", ctx, %{
                 "action" => "logs",
                 "execution_id" => legacy.id,
                 "root_execution_id" => root.id
               })

      assert message =~ "not found in this chain"
    end
  end

  describe "external plane" do
    test "without host-injected lineage the tenant-wide view is unchanged", %{ctx: ctx} do
      root = record!(ctx, component_type: :formula)
      stranger = record!(ctx, component_type: :formula)

      assert {:ok, _} =
               Opus.MCP.handle("execution", ctx, %{
                 "action" => "logs",
                 "execution_id" => stranger.id
               })

      {:ok, %{executions: all}} = Opus.MCP.handle("execution", ctx, %{"action" => "list"})
      ids = Enum.map(all, & &1.execution_id)
      assert root.id in ids
      assert stranger.id in ids
    end
  end

  describe "lineage cannot be forged" do
    test "a guest-supplied root_execution_id is dropped before dispatch", %{ctx: ctx} do
      root = record!(ctx, component_type: :formula)
      stranger = record!(ctx, component_type: :formula)

      # The guest claims the stranger's chain; the host says otherwise.
      # call_in_chain drops the guest's key and re-injects only the
      # lineage it was told, so the stranger stays out of reach.
      {:error, message} =
        Emissary.MCP.ToolRegistry.call_in_chain(
          "execution",
          ctx,
          %{
            "action" => "logs",
            "execution_id" => stranger.id,
            "root_execution_id" => stranger.id
          },
          authority(),
          lineage: %{root_execution_id: root.id}
        )

      assert message =~ "not found in this chain"
    end

    test "a guest-planed context cannot read execution records at all", %{ctx: ctx} do
      stranger = record!(ctx, component_type: :formula)

      # Belt to the chain scope's braces: the record read gate refuses the
      # guest plane outright, before any lineage question arises.
      {:error, message} =
        Emissary.MCP.ToolRegistry.call_in_chain(
          "execution",
          Sanctum.Context.enter_guest(ctx),
          %{"action" => "logs", "execution_id" => stranger.id},
          authority(),
          lineage: %{root_execution_id: stranger.id}
        )

      assert message =~ "not found"
    end
  end

  defp authority do
    node = "formula:local.scoper"

    graph = %{
      "canonical" => "jcs-1",
      "nodes" => %{
        node => %{
          "limits" => %{
            "timeout" => "1m",
            "max_memory_bytes" => 67_108_864,
            "max_request_size" => 1_048_576,
            "max_response_size" => 5_242_880,
            "rate_limit" => %{"requests" => 10_000, "window" => "1m"},
            "max_concurrent_tasks" => 10,
            "batch_timeout" => "1m"
          },
          "edges" => %{"@ingress" => %{"tools" => ["execution.logs"]}}
        }
      }
    }

    {:ok, blob} = Sanctum.Authority.Blob.parse(graph)

    {:ok, auth} =
      Sanctum.Authority.root(
        %{
          profile_id: "prof-scope",
          consent_id: "consent-scope",
          source_ref: node,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{node => "sha256:scope"}
        },
        blob
      )

    auth
  end
end
