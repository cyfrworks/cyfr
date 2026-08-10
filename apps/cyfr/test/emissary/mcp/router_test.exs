# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.RouterTest do
  use ExUnit.Case, async: false

  alias Emissary.MCP.{Message, Router, Session}
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()
    {:ok, session} = Session.create(ctx)

    on_exit(fn ->
      Session.terminate(session.id)
    end)

    {:ok, session: session, context: ctx}
  end

  describe "protocol_version/0" do
    test "returns the supported protocol version" do
      assert Router.protocol_version() == Emissary.MCP.Protocol.version()
    end
  end

  describe "dispatch/2 with server/discover" do
    test "advertises the supported revisions, capabilities and identity", %{session: session} do
      msg = %Message{type: :request, id: 1, method: "server/discover", params: %{}}

      assert {:ok, result} = Router.dispatch(session, msg)
      assert result["protocolVersions"] == Emissary.MCP.Protocol.supported()
      assert result["serverInfo"]["name"] == "CYFR"
      assert is_map(result["capabilities"])
    end
  end

  describe "dispatch/2 with ping" do
    test "returns empty object", %{session: session} do
      msg = %Message{
        type: :request,
        id: 2,
        method: "ping",
        params: nil
      }

      assert {:ok, result} = Router.dispatch(session, msg)
      assert result == %{}
    end
  end

  describe "dispatch/2 with tools/list" do
    test "delegates to ToolRegistry and returns tools list", %{session: session} do
      msg = %Message{
        type: :request,
        id: 3,
        method: "tools/list",
        params: nil
      }

      assert {:ok, result} = Router.dispatch(session, msg)
      assert is_list(result["tools"])
    end
  end

  describe "dispatch/2 with tools/call" do
    test "delegates to ToolRegistry for valid tool", %{session: session} do
      msg = %Message{
        type: :request,
        id: 4,
        method: "tools/call",
        params: %{
          "name" => "system",
          "arguments" => %{"action" => "status"}
        }
      }

      assert {:ok, result} = Router.dispatch(session, msg)
      assert is_list(result["content"])
      [content] = result["content"]
      assert content["type"] == "text"
      assert result["isError"] == false
    end

    test "returns protocol error for unknown tool", %{session: session} do
      msg = %Message{
        type: :request,
        id: 5,
        method: "tools/call",
        params: %{
          "name" => "nonexistent/tool",
          "arguments" => %{}
        }
      }

      assert {:error, :invalid_params, message} = Router.dispatch(session, msg)
      assert message =~ "Unknown tool: nonexistent/tool"
    end

    test "returns protocol error when tool name is missing", %{session: session} do
      msg = %Message{
        type: :request,
        id: 5,
        method: "tools/call",
        params: %{"arguments" => %{}}
      }

      assert {:error, :invalid_params, message} = Router.dispatch(session, msg)
      assert message =~ "Missing required field: name"
    end

    test "returns invalid_params for non-object arguments", %{session: session} do
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

        assert {:error, :invalid_params, message} = Router.dispatch(session, msg)
        assert message =~ "must be an object"
      end
    end

    test "handles missing arguments as empty map", %{session: session} do
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
      result = Router.dispatch(session, msg)
      assert match?({:ok, _}, result) or match?({:error, :invalid_params, _}, result)
    end
  end

  describe "dispatch/2 with resources/list" do
    test "delegates to ResourceRegistry and returns resources list", %{session: session} do
      msg = %Message{
        type: :request,
        id: 7,
        method: "resources/list",
        params: nil
      }

      assert {:ok, result} = Router.dispatch(session, msg)
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
    test "returns resource templates with uriTemplate field", %{session: session} do
      msg = %Message{
        type: :request,
        id: 20,
        method: "resources/templates/list",
        params: nil
      }

      assert {:ok, result} = Router.dispatch(session, msg)
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
    test "returns error for unknown URI scheme", %{session: session} do
      msg = %Message{
        type: :request,
        id: 8,
        method: "resources/read",
        params: %{"uri" => "unknown://resource/path"}
      }

      assert {:error, :resource_not_found, message} = Router.dispatch(session, msg)
      assert message =~ "Failed to read resource"
    end
  end

  describe "dispatch/2 with unknown method" do
    test "returns method_not_found error", %{session: session} do
      msg = %Message{
        type: :request,
        id: 9,
        method: "unknown/method",
        params: nil
      }

      assert {:error, :method_not_found, message} = Router.dispatch(session, msg)
      assert message =~ "Unknown method"
    end
  end

  describe "dispatch/2 with notifications" do
    test "handles notifications/initialized", %{session: session} do
      msg = %Message{
        type: :notification,
        method: "notifications/initialized",
        params: nil
      }

      assert :ok = Router.dispatch(session, msg)
    end

    test "handles notifications/cancelled", %{session: session} do
      msg = %Message{
        type: :notification,
        method: "notifications/cancelled",
        params: %{"requestId" => 123}
      }

      assert :ok = Router.dispatch(session, msg)
    end

    test "handles unknown notification gracefully", %{session: session} do
      msg = %Message{
        type: :notification,
        method: "notifications/unknown",
        params: nil
      }

      # Should not crash, just logs warning
      assert :ok = Router.dispatch(session, msg)
    end
  end

  describe "dispatch/2 with client response/error types" do
    test "returns :ok for response type (per MCP spec, maps to 202)", %{session: session} do
      msg = %Message{
        type: :response,
        id: 10,
        result: %{}
      }

      assert :ok = Router.dispatch(session, msg)
    end

    test "returns :ok for error type (per MCP spec, maps to 202)", %{session: session} do
      msg = %Message{
        type: :error,
        id: 11,
        error: %{"code" => -32600, "message" => "Error"}
      }

      assert :ok = Router.dispatch(session, msg)
    end
  end
end
