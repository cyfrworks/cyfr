# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.McpLogTest do
  @moduledoc """
  The request log's tool (`Sanctum.Providers.McpLog`), handed the
  caller's actor alone: its declarations, its authorization, its outage
  refusal, and the correlation of a request's rows with its decisions.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.Providers.McpLog, as: MCP

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local(:api)}
  end

  describe "tools/0" do
    test "declares the request log's tool under sanctum, handed the actor", %{ctx: ctx} do
      assert Enum.map(MCP.tools(), & &1.name) == ["mcp_log"]
      assert MCP.service() == "sanctum"
      assert Prima.Provider.context_kind(MCP) == :actor

      # The gate resolves the tool to this provider. A second declaration of
      # it on the roster refuses the catalog's boot (`:tool_registered_twice`).
      assert {:ok, {MCP, _meta}} = Sanctum.Catalog.lookup("mcp_log")

      assert {:error, {:not_found, "tool", "record"}} = MCP.handle("record", actor(ctx), %{})
    end
  end

  describe "mcp_log tool schema" do
    test "only exposes read-only actions" do
      tools = MCP.tools()
      tool = Enum.find(tools, &(&1.name == "mcp_log"))
      actions = tool.input_schema["properties"]["action"]["enum"]
      assert actions == ["list", "get", "correlate", "fan_outs", "stats"]

      for operation <- tool.operations do
        assert operation.kind == :read
        assert operation.planes == [:external]
        assert operation.permission == :storage_read
        assert is_nil(operation.scope)
      end

      refute "log_started" in actions
      refute "log_completed" in actions
      refute "log_failed" in actions
    end
  end

  describe "mcp_log rows" do
    test "a row answers the refusal's class, never a JSON-RPC code", %{ctx: ctx} do
      decision =
        Prima.Decision.new(
          call_id: Prima.UUID7.generate_id("call"),
          request_id: Prima.UUID7.request_id(),
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          plane: :external,
          tool: "storage",
          action: "get",
          inserted_at: DateTime.utc_now(),
          admission: :refused,
          refusal_class: :forbidden,
          reason: "Not allowed."
        )

      :ok = Sanctum.Decisions.open(ctx, decision, %{input: %{}})

      assert {:ok, row} =
               MCP.handle("mcp_log", actor(ctx), %{"action" => "get", "id" => decision.call_id})

      assert row.refusal_class == "forbidden"
      assert row.error == "Not allowed."
      refute Map.has_key?(row, :error_code)
    end
  end

  describe "retired write/delete verbs are unknown at dispatch" do
    test "kernel-only and append-only verbs no longer exist on the surface", %{ctx: ctx} do
      # Undeclared actions must be refused before handler dispatch.
      retired = [
        {"mcp_log", "log_started"},
        {"mcp_log", "log_completed"},
        {"mcp_log", "log_failed"},
        {"mcp_log", "delete"}
      ]

      for {tool, verb} <- retired do
        {:error, %Prima.Refusal{stage: :admission, reason: {:unknown_action, name_action}}} =
          Sanctum.Gate.call_external(tool, ctx, %{"action" => verb})

        assert name_action == "#{tool}.#{verb}"
      end
    end
  end

  describe "correlate authorization" do
    setup do
      no_read_ctx = %Context{
        user_id: "regular_user",
        athanor_id: "ath_test",
        permissions: MapSet.new([:execute]),
        scope: :athanor,
        auth_method: :api_key,
        api_key_type: :application,
        authenticated: true
      }

      {:ok, no_read_ctx: no_read_ctx}
    end

    test "mcp_log.correlate requires :storage_read like its siblings", %{no_read_ctx: ctx} do
      assert {:error,
              %Prima.Refusal{stage: :admission, reason: {:missing_permission, :storage_read}}} =
               Sanctum.Gate.call_external("mcp_log", ctx, %{
                 "action" => "correlate",
                 "request_id" => "req_x"
               })
    end

    test "correlate succeeds for a :storage_read context", %{ctx: ctx} do
      assert {:ok, %{request_id: "req_none"}} =
               MCP.handle("mcp_log", actor(ctx), %{
                 "action" => "correlate",
                 "request_id" => "req_none"
               })
    end
  end

  describe "mcp_log.stats authorization" do
    setup do
      no_read_ctx = %Context{
        user_id: "regular_user",
        athanor_id: "ath_test",
        permissions: MapSet.new([:execute]),
        scope: :athanor,
        auth_method: :api_key,
        api_key_type: :application,
        authenticated: true
      }

      {:ok, no_read_ctx: no_read_ctx}
    end

    test "stats requires :storage_read like its siblings", %{no_read_ctx: ctx} do
      assert {:error,
              %Prima.Refusal{stage: :admission, reason: {:missing_permission, :storage_read}}} =
               Sanctum.Gate.call_external("mcp_log", ctx, %{"action" => "stats"})
    end

    test "stats succeeds for a :storage_read context", %{ctx: ctx} do
      assert {:ok, result} = MCP.handle("mcp_log", actor(ctx), %{"action" => "stats"})
      assert is_integer(result.total)
      assert is_integer(result.errors)
    end
  end

  # Walks every action each tool declares in its input schema and asserts the
  # handler denies an unprivileged context. Pins authorization on all current
  # actions and fails when a future action ships without an authorize call
  # (an unauthorized probe must never fall through to a data-bearing path).
  describe "declared tool actions all authorize" do
    test "every declared action denies a context without permissions" do
      no_perm_ctx = %Context{
        user_id: "no_perm_user",
        athanor_id: "ath_test",
        permissions: MapSet.new(),
        scope: :athanor,
        auth_method: :api_key,
        api_key_type: :application,
        authenticated: true
      }

      # Minimal args per action so the call reaches the authorize path
      # instead of the missing-required-argument clause. A new action with
      # required args must be added here — the "Unauthorized" assert below
      # fails on the missing-arg error otherwise, forcing the pin.
      extra_args = fn
        {_, "get"} -> %{"id" => "guard_probe"}
        {_, "correlate"} -> %{"request_id" => "guard_probe"}
        {_, "fan_outs"} -> %{"request_ids" => ["guard_probe"]}
        _ -> %{}
      end

      for tool <- MCP.tools(),
          action <- tool.input_schema["properties"]["action"]["enum"] do
        args = Map.put(extra_args.({tool.name, action}), "action", action)

        case Sanctum.Gate.call_external(tool.name, no_perm_ctx, args) do
          {:error, %Prima.Refusal{stage: :admission, reason: reason}} ->
            assert Sanctum.Unauthorized.reason?(reason),
                   "#{tool.name}.#{action} error is not a permission denial: #{inspect(reason)}"

          {:error, reason} ->
            assert Sanctum.Unauthorized.reason?(reason),
                   "#{tool.name}.#{action} error is not a permission denial: #{inspect(reason)}"

          other ->
            flunk(
              "#{tool.name}.#{action} succeeded for an unprivileged context: #{inspect(other)}"
            )
        end
      end
    end
  end

  describe "a storage outage is a refusal, never a crash" do
    # Dropping the table inside the sandbox transaction is the outage: it
    # rolls back with the test, on both adapters.
    test "mcp_log.get", %{ctx: ctx} do
      Arca.Repo.query!("DROP TABLE mcp_logs")

      assert {:error, reason} =
               MCP.handle("mcp_log", actor(ctx), %{"action" => "get", "id" => "req_x"})

      assert err_msg(reason) =~ "unavailable"
    end
  end

  describe "the decisions leg" do
    setup %{ctx: ctx} do
      other =
        Sanctum.Context.build(
          user_id: "user_other_decision",
          athanor_id: "ath_other_decision",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )

      request_id = Prima.UUID7.request_id()
      admitted = append!(ctx, request_id: request_id)

      refused =
        append!(ctx, request_id: request_id, admission: :refused, refusal_class: :forbidden)

      foreign = append!(other, request_id: request_id)

      host =
        append!(nil, request_id: request_id, admission: :refused, refusal_class: :unauthenticated)

      {:ok,
       other: other,
       request_id: request_id,
       admitted: admitted,
       refused: refused,
       foreign: foreign,
       host: host}
    end

    test "mcp_log.correlate carries the decisions leg beside its own", %{
      ctx: ctx,
      request_id: request_id,
      admitted: admitted,
      refused: refused
    } do
      assert {:ok, result} =
               MCP.handle("mcp_log", actor(ctx), %{
                 "action" => "correlate",
                 "request_id" => request_id
               })

      assert ids(result.decisions) == Enum.sort([admitted.call_id, refused.call_id])

      assert Enum.sort(Map.keys(result) -- [:decisions]) == [
               :executions,
               :mcp_logs,
               :policy_logs,
               :request_id
             ]
    end
  end

  defp actor(ctx), do: Sanctum.Context.actor(ctx)

  # One decision appended under `ctx`'s actor, or under none for the
  # host's row, with `fields` over an admitted default.
  defp append!(ctx, fields) do
    decision =
      Prima.Decision.new(
        Keyword.merge(
          [
            call_id: Prima.UUID7.generate_id("call"),
            user_id: ctx && ctx.user_id,
            athanor_id: ctx && ctx.athanor_id,
            plane: :external,
            tool: "storage",
            action: "get",
            inserted_at: DateTime.utc_now(),
            admission: :admitted
          ],
          fields
        )
      )

    :ok = Arca.DecisionLog.append(ctx && actor(ctx), decision)
    decision
  end

  defp ids(rows), do: rows |> Enum.map(& &1["call_id"]) |> Enum.sort()

  # The provider answers typed reasons where the class is clear; the shared
  # renderer is the one spelling of every sentence, so assert through it.
  # Plain strings pass through unchanged.
  defp err_msg(reason) do
    Sanctum.Refusals.render(reason) ||
      flunk("unrenderable refusal: #{inspect(reason)}")
  end
end
