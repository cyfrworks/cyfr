defmodule Emissary.AuthChainIntegrationTest do
  @moduledoc """
  Integration tests for the full auth chain:
  API key → MCPSession plug → Context.build → authorize → handler → response

  Verifies that permission-gated MCP tools correctly enforce authorization
  through the unified Context.authorize/2 path.
  """
  use EmissaryWeb.ConnCase, async: false

  alias Emissary.MCP.Session

  setup do
    test_dir =
      Path.join(System.tmp_dir!(), "cyfr_auth_chain_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_dir)

    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_dir)

    ctx = Sanctum.Context.local()

    # Create an app key with only execute scope (no storage_read)
    {:ok, limited_key} =
      Sanctum.ApiKey.create(ctx, %{
        name: "test-limited-key",
        type: :application,
        scope: ["execute"]
      })

    # Create an app key with execute + storage_read
    {:ok, reader_key} =
      Sanctum.ApiKey.create(ctx, %{
        name: "test-reader-key",
        type: :application,
        scope: ["execute", "storage_read"]
      })

    on_exit(fn ->
      File.rm_rf!(test_dir)

      if original_base_path do
        Application.put_env(:cyfr, :base_path, original_base_path)
      else
        Application.delete_env(:cyfr, :base_path)
      end
    end)

    {:ok, limited_key: limited_key.key, reader_key: reader_key.key}
  end

  defp mcp_call(conn, api_key, tool, arguments) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{api_key}")
    |> post("/mcp", %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => "tools/call",
      "params" => %{
        "name" => tool,
        "arguments" => arguments
      }
    })
  end

  describe "public tool actions succeed without storage permissions" do
    @tag :requires_opus
    test "system status works with limited key", %{conn: conn, limited_key: key} do
      resp = conn |> mcp_call(key, "system", %{"action" => "status"}) |> json_response(200)

      assert resp["result"]["isError"] == false
      [content] = resp["result"]["content"]
      result = Jason.decode!(content["text"])
      assert result["status"] == "ok"
    end
  end

  describe "permission-gated actions enforce authorization" do
    test "record list denied without storage_read", %{conn: conn, limited_key: key} do
      resp = conn |> mcp_call(key, "record", %{"action" => "list"}) |> json_response(200)

      assert resp["result"]["isError"] == true
      [content] = resp["result"]["content"]
      assert content["text"] =~ "Unauthorized" or content["text"] =~ "permission"
    end

    test "record list succeeds with storage_read", %{conn: conn, reader_key: key} do
      resp = conn |> mcp_call(key, "record", %{"action" => "list"}) |> json_response(200)

      assert resp["result"]["isError"] == false
      [content] = resp["result"]["content"]
      result = Jason.decode!(content["text"])
      assert is_list(result["executions"])
    end

    test "retention get denied without storage_read", %{conn: conn, limited_key: key} do
      resp = conn |> mcp_call(key, "retention", %{"action" => "get"}) |> json_response(200)

      assert resp["result"]["isError"] == true
      [content] = resp["result"]["content"]
      assert content["text"] =~ "Unauthorized" or content["text"] =~ "permission"
    end

    test "retention get succeeds with storage_read", %{conn: conn, reader_key: key} do
      resp = conn |> mcp_call(key, "retention", %{"action" => "get"}) |> json_response(200)

      assert resp["result"]["isError"] == false
    end

    test "retention set denied for non-admin key", %{conn: conn, reader_key: key} do
      resp =
        conn
        |> mcp_call(key, "retention", %{
          "action" => "set",
          "settings" => %{"executions" => 5}
        })
        |> json_response(200)

      assert resp["result"]["isError"] == true
      [content] = resp["result"]["content"]
      assert content["text"] =~ "Unauthorized"
    end

    test "retention cleanup denied for non-admin key", %{conn: conn, reader_key: key} do
      resp =
        conn
        |> mcp_call(key, "retention", %{
          "action" => "cleanup",
          "cleanup_type" => "executions",
          "dry_run" => true
        })
        |> json_response(200)

      assert resp["result"]["isError"] == true
      [content] = resp["result"]["content"]
      assert content["text"] =~ "Unauthorized"
    end
  end

  describe "invalid API key returns 401" do
    test "invalid key is rejected at the protocol level", %{conn: conn} do
      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer cyfr_pk_invalid000000000000000000")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "record",
            "arguments" => %{"action" => "list"}
          }
        })

      response = json_response(resp, 401)
      assert response["error"]["message"] =~ "Invalid API key"
    end
  end

  describe "session cleanup" do
    test "sessions created during auth chain are valid", %{conn: conn, reader_key: key} do
      # Initialize a session with the reader key
      init_conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{key}")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        })

      response = json_response(init_conn, 200)
      assert response["result"]["protocolVersion"] == "2025-11-25"

      [session_id] = get_resp_header(init_conn, "mcp-session-id")
      assert String.starts_with?(session_id, "sess_")

      # Use session for a tool call
      tool_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{
            "name" => "retention",
            "arguments" => %{"action" => "get"}
          }
        })

      tool_resp = json_response(tool_conn, 200)
      assert tool_resp["result"]["isError"] == false

      Session.terminate(session_id)
    end
  end
end
