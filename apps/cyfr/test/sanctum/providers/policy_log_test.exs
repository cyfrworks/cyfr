# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.PolicyLogTest do
  @moduledoc """
  The policy log's tool (`Sanctum.Providers.PolicyLog`), handed the
  caller's actor alone, and its reader for a surface (`Sanctum.PolicyLog`):
  the declarations the operation table carries, the caller's athanor's rows
  and no other's, the permission each read takes, and the outage refusal.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.Providers.PolicyLog, as: MCP

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local(:api)}
  end

  describe "tools/0" do
    test "declares the policy log's tool under sanctum, handed the actor", %{ctx: ctx} do
      assert Enum.map(MCP.tools(), & &1.name) == ["policy_log"]
      assert MCP.service() == "sanctum"
      assert Prima.Provider.context_kind(MCP) == :actor

      # The gate resolves the tool to this provider, and the records door no
      # longer declares it: a second declaration on the roster refuses the
      # catalog's boot (`:tool_registered_twice`).
      assert {:ok, {MCP, _meta}} = Sanctum.Catalog.lookup("policy_log")
      refute "policy_log" in Enum.map(Arca.Providers.Records.tools(), & &1.name)

      assert {:error, {:not_found, "tool", "record"}} = MCP.handle("record", actor(ctx), %{})
    end

    test "the three reads keep their names, arguments, kinds, planes and permission" do
      [tool] = MCP.tools()

      assert tool.title == "Policy Logs"
      assert tool.description == "Query policy consultation logs - list, get, or correlate logs"
      assert tool.input_schema["properties"]["action"]["enum"] == ["list", "get", "correlate"]

      declared =
        for operation <- tool.operations do
          assert operation.kind == :read
          assert operation.planes == [:external]
          assert operation.permission == :storage_read
          assert is_nil(operation.scope)

          {operation.action,
           for(arg <- operation.args, do: {arg.name, arg.type, arg.required, arg.description})}
        end

      assert declared == [
               {"list",
                [
                  {"request_id", :string, false, "Filter by request ID"},
                  {"execution_id", :string, false, "Filter by execution ID"},
                  {"user_id", :string, false, "Filter by user ID"},
                  {"event_type", :string, false, "Filter by event type"},
                  {"limit", :integer, false, "Max results (default: 20)"}
                ]},
               {"get", [{"id", :string, true, "Policy log ID"}]},
               {"correlate", [{"request_id", :string, true, "Filter by request ID"}]}
             ]
    end

    test "kernel-only and append-only verbs are unknown at dispatch", %{ctx: ctx} do
      for verb <- ["log", "delete"] do
        assert {:error, %Prima.Refusal{stage: :admission, reason: {:unknown_action, name}}} =
                 Sanctum.Gate.call_external("policy_log", ctx, %{"action" => verb})

        assert name == "policy_log.#{verb}"
      end
    end
  end

  describe "the caller's athanor's rows" do
    setup %{ctx: ctx} do
      request_id = Prima.UUID7.request_id()
      own = record!(ctx.athanor_id, request_id: request_id, decision: "allowed")
      other = record!("ath_other_policy", request_id: request_id, decision: "denied")
      {:ok, request_id: request_id, own: own, other: other}
    end

    test "list answers the actor's athanor's rows, through the gate as well", %{
      ctx: ctx,
      request_id: request_id,
      own: own,
      other: other
    } do
      assert {:ok, %{logs: logs}} =
               MCP.handle("policy_log", actor(ctx), %{
                 "action" => "list",
                 "request_id" => request_id
               })

      assert Enum.map(logs, & &1.id) == [own.id]
      refute other.id in Enum.map(logs, & &1.id)

      assert {:ok, %{logs: [%{id: id, decision: "allowed"}]}} =
               Sanctum.Gate.call_external("policy_log", ctx, %{
                 "action" => "list",
                 "request_id" => request_id
               })

      assert id == own.id
    end

    test "correlate answers the request's rows in the actor's athanor", %{
      ctx: ctx,
      request_id: request_id,
      own: own
    } do
      assert {:ok, %{request_id: ^request_id, policy_logs: [%{id: id}]}} =
               MCP.handle("policy_log", actor(ctx), %{
                 "action" => "correlate",
                 "request_id" => request_id
               })

      assert id == own.id

      # The request log's correlation renders the same rows through this
      # door's projection.
      assert %{policy_logs: [%{id: ^id, decision: "allowed"}]} =
               Sanctum.Providers.McpLog.correlation(actor(ctx), request_id)
    end

    test "get finds the actor's athanor's row by its id or its request, never another's", %{
      ctx: ctx,
      request_id: request_id,
      own: own,
      other: other
    } do
      assert {:ok, %{id: id}} =
               MCP.handle("policy_log", actor(ctx), %{"action" => "get", "id" => own.id})

      assert id == own.id

      assert {:ok, %{id: ^id}} =
               MCP.handle("policy_log", actor(ctx), %{"action" => "get", "id" => request_id})

      assert MCP.handle("policy_log", actor(ctx), %{"action" => "get", "id" => other.id}) ==
               {:error, {:not_found, "Policy log", other.id}}
    end

    test "an actor with no athanor is refused before any row is read", %{request_id: request_id} do
      none = %Prima.Actor{athanor_id: nil, scope: :athanor}

      for args <- [
            %{"action" => "list"},
            %{"action" => "get", "id" => "pl_x"},
            %{"action" => "correlate", "request_id" => request_id}
          ] do
        assert MCP.handle("policy_log", none, args) == {:error, :missing_tenant}
      end

      # A platform actor passes the door's check; the log's list reads one
      # athanor, so it refuses one with none rather than reading every tenant.
      platform = %Prima.Actor{athanor_id: nil, scope: :platform}

      assert MCP.handle("policy_log", platform, %{"action" => "list"}) ==
               {:error, :missing_tenant}
    end
  end

  describe "Sanctum.PolicyLog.list/2" do
    test "reads the context's athanor's rows, whatever the options name", %{ctx: ctx} do
      request_id = Prima.UUID7.request_id()
      own = record!(ctx.athanor_id, request_id: request_id)
      _other = record!("ath_other_policy", request_id: request_id)

      assert {:ok, [%{id: id}]} =
               Sanctum.PolicyLog.list(ctx,
                 request_id: request_id,
                 athanor_id: "ath_other_policy",
                 limit: 100
               )

      assert id == own.id
    end

    test "takes :storage_read on the external plane, and a resolved athanor", %{ctx: ctx} do
      request_id = Prima.UUID7.request_id()
      record!(ctx.athanor_id, request_id: request_id)

      no_read = %{ctx | permissions: MapSet.new([:execute])}

      assert Sanctum.PolicyLog.list(no_read, request_id: request_id) ==
               {:error, {:missing_permission, :storage_read}}

      assert Sanctum.PolicyLog.list(Context.enter_guest(ctx), request_id: request_id) ==
               {:error, {:guest_plane, :storage_read}}

      assert Sanctum.PolicyLog.list(%{ctx | athanor_id: nil}, request_id: request_id) ==
               {:error, :no_athanor}

      assert Sanctum.PolicyLog.list(%{ctx | athanor_id: nil, scope: :platform}, []) ==
               {:error, :no_athanor}
    end
  end

  describe "authorization" do
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

      extra_args = fn
        "get" -> %{"id" => "guard_probe"}
        "correlate" -> %{"request_id" => "guard_probe"}
        _ -> %{}
      end

      [tool] = MCP.tools()

      for action <- tool.input_schema["properties"]["action"]["enum"] do
        args = Map.put(extra_args.(action), "action", action)

        assert {:error, %Prima.Refusal{stage: :admission, reason: reason}} =
                 Sanctum.Gate.call_external("policy_log", no_perm_ctx, args)

        assert Sanctum.Unauthorized.reason?(reason),
               "policy_log.#{action} error is not a permission denial: #{inspect(reason)}"
      end
    end
  end

  describe "a storage outage is a refusal, never a crash" do
    # Dropping the table inside the sandbox transaction is the outage: it
    # rolls back with the test, on both adapters.
    test "policy_log.get and policy_log.list", %{ctx: ctx} do
      Arca.Repo.query!("DROP TABLE policy_logs")

      for args <- [%{"action" => "get", "id" => "pl_x"}, %{"action" => "list"}] do
        assert MCP.handle("policy_log", actor(ctx), args) ==
                 {:error, {:unavailable, "Storage"}}
      end

      # The correlation's leg is best effort: the outage leaves it empty.
      assert {:ok, %{policy_logs: []}} =
               MCP.handle("policy_log", actor(ctx), %{
                 "action" => "correlate",
                 "request_id" => "req_x"
               })
    end
  end

  defp actor(ctx), do: Sanctum.Context.actor(ctx)

  defp record!(athanor_id, fields) do
    attrs =
      Map.merge(
        %{
          id: Prima.UUID7.generate_id("pl"),
          athanor_id: athanor_id,
          user_id: "user_policy",
          timestamp: DateTime.utc_now(),
          event_type: "policy_consultation",
          component_ref: "formula:local.policy",
          component_type: "formula",
          decision: "allowed",
          decision_reason: "default policy"
        },
        Map.new(fields)
      )

    {:ok, row} = Arca.PolicyLog.record(attrs)
    row
  end
end
