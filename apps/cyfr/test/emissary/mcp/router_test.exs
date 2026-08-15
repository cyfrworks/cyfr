# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.RouterTest do
  use ExUnit.Case, async: false

  alias Emissary.MCP.{Message, Router}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()

    {:ok, context: ctx}
  end

  describe "dispatch/2 with server/discover" do
    test "advertises the supported revisions, capabilities and identity", %{context: ctx} do
      msg = %Message{type: :request, id: 1, method: "server/discover", params: %{}}

      assert {:ok, result} = Router.dispatch(ctx, msg)
      assert result["supportedVersions"] == Emissary.MCP.Protocol.supported()
      assert is_map(result["capabilities"])

      # Identity is stamped onto every result by the encoder, so the router's
      # own return value carries only what is specific to discovery.
      refute Map.has_key?(result, "serverInfo")
    end

    test "does not advertise a resource-subscribe capability it cannot honour",
         %{context: ctx} do
      msg = %Message{type: :request, id: 1, method: "server/discover", params: %{}}

      assert {:ok, result} = Router.dispatch(ctx, msg)

      # `resources/subscribe` was replaced by `subscriptions/listen`; advertising
      # the retired capability would have clients waiting for updates that this
      # server has no way to send.
      refute Map.has_key?(result["capabilities"]["resources"], "subscribe")
      assert is_map(result["capabilities"]["extensions"])
    end
  end

  describe "dispatch/2 with ping" do
    # Removed in 2026-07-28. Answering it would misreport which revision this
    # server speaks, so the rejection is the conformant behaviour.
    test "is not a method this revision has", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 2,
        method: "ping",
        params: nil
      }

      assert {:error, :method_not_found, message} = Router.dispatch(ctx, msg)
      assert message =~ "ping"
    end
  end

  describe "dispatch/2 with tools/list" do
    test "delegates to ToolRegistry and returns tools list", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 3,
        method: "tools/list",
        params: nil
      }

      assert {:ok, result} = Router.dispatch(ctx, msg)
      assert is_list(result["tools"])
    end
  end

  describe "dispatch/2 with tools/call" do
    test "delegates to ToolRegistry for valid tool", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 4,
        method: "tools/call",
        params: %{
          "name" => "system",
          "arguments" => %{"action" => "status"}
        }
      }

      assert {:ok, result} = Router.dispatch(ctx, msg)
      assert is_list(result["content"])
      [content] = result["content"]
      assert content["type"] == "text"
      assert result["isError"] == false
    end

    test "returns protocol error for unknown tool", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 5,
        method: "tools/call",
        params: %{
          "name" => "nonexistent/tool",
          "arguments" => %{}
        }
      }

      assert {:error, :invalid_params, message} = Router.dispatch(ctx, msg)
      assert message =~ "Unknown tool: nonexistent/tool"
    end

    test "returns protocol error when tool name is missing", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 5,
        method: "tools/call",
        params: %{"arguments" => %{}}
      }

      assert {:error, :invalid_params, message} = Router.dispatch(ctx, msg)
      assert message =~ "Missing required field: name"
    end

    test "returns invalid_params for non-object arguments", %{context: ctx} do
      # Regression: the dispatcher reads `arguments["action"]`, and Access raises
      # on a list — this used to escape as an uncaught ArgumentError (HTTP 500)
      # rather than a JSON-RPC -32602.
      for bad_arguments <- [[1, 2, 3], "a string", 42] do
        msg = %Message{
          type: :request,
          id: 5,
          method: "tools/call",
          params: %{"name" => "system", "arguments" => bad_arguments}
        }

        assert {:error, :invalid_params, message} = Router.dispatch(ctx, msg)
        assert message =~ "must be an object"
      end
    end

    test "handles missing arguments as empty map", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 6,
        method: "tools/call",
        params: %{
          "name" => "session",
          "arguments" => nil
        }
      }

      # Should not crash — returns validation error if schema requires fields,
      # or succeeds if tool has no required fields
      result = Router.dispatch(ctx, msg)
      assert match?({:ok, _}, result) or match?({:error, :invalid_params, _}, result)
    end
  end

  describe "dispatch/2 with resources/list" do
    test "delegates to ResourceRegistry and returns resources list", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 7,
        method: "resources/list",
        params: nil
      }

      assert {:ok, result} = Router.dispatch(ctx, msg)
      assert is_list(result["resources"])

      # Resources list must not contain URI templates
      Enum.each(result["resources"], fn resource ->
        uri = resource["uri"]

        refute String.contains?(uri, "{"),
               "resources/list should not contain URI templates, found: #{uri}"
      end)
    end
  end

  describe "dispatch/2 with resources/templates/list" do
    test "returns resource templates with uriTemplate field", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 20,
        method: "resources/templates/list",
        params: nil
      }

      assert {:ok, result} = Router.dispatch(ctx, msg)
      assert is_list(result["resourceTemplates"])

      # All templates should have uriTemplate field
      Enum.each(result["resourceTemplates"], fn template ->
        assert is_binary(template["uriTemplate"]),
               "resource template missing uriTemplate field: #{inspect(template)}"

        assert String.contains?(template["uriTemplate"], "{"),
               "uriTemplate should contain template variables: #{template["uriTemplate"]}"
      end)
    end
  end

  describe "dispatch/2 with resources/read" do
    test "returns error for unknown URI scheme", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 8,
        method: "resources/read",
        params: %{"uri" => "unknown://resource/path"}
      }

      assert {:error, :resource_not_found, message} = Router.dispatch(ctx, msg)
      assert message =~ "Failed to read resource"
    end
  end

  describe "dispatch/2 with unknown method" do
    test "returns method_not_found error", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 9,
        method: "unknown/method",
        params: nil
      }

      assert {:error, :method_not_found, message} = Router.dispatch(ctx, msg)
      assert message =~ "Unknown method"
    end
  end

  describe "dispatch/2 with notifications" do
    test "any notification is logged and absorbed, never dispatched", %{context: ctx} do
      # There is deliberately no notification clause besides the catch-all:
      # on Streamable HTTP the only cancellation signal is the caller
      # closing its own stream, so `notifications/cancelled` must NOT be a
      # second way in — it lands in the same absorb-and-log arm as anything
      # else.
      for {method, params} <- [
            {"notifications/cancelled", %{"requestId" => 123}},
            {"notifications/unknown", nil}
          ] do
        msg = %Message{type: :notification, method: method, params: params}
        assert :ok = Router.dispatch(ctx, msg)
      end
    end
  end

  describe "dispatch/2 with client response/error types" do
    test "returns :ok for response type (per MCP spec, maps to 202)", %{context: ctx} do
      msg = %Message{
        type: :response,
        id: 10,
        result: %{}
      }

      assert :ok = Router.dispatch(ctx, msg)
    end

    test "returns :ok for error type (per MCP spec, maps to 202)", %{context: ctx} do
      msg = %Message{
        type: :error,
        id: 11,
        error: %{"code" => -32600, "message" => "Error"}
      }

      assert :ok = Router.dispatch(ctx, msg)
    end
  end
end
