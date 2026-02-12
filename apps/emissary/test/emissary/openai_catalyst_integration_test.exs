defmodule Emissary.OpenAICatalystIntegrationTest do
  @moduledoc """
  HTTP-layer integration tests for the OpenAI catalyst through Emissary.

  Tests the full HTTP stack: init session -> execute catalyst -> verify response.

  ## Running

      # With real API key:
      OPENAI_API_KEY=sk-... mix test apps/emissary/test/emissary/openai_catalyst_integration_test.exs --include integration

      # Policy error test (no API key needed):
      mix test apps/emissary/test/emissary/openai_catalyst_integration_test.exs
  """

  use EmissaryWeb.ConnCase

  alias Emissary.MCP.Session

  @wasm_source Path.expand("../../../../components/catalysts/local/openai/0.1.0/catalyst.wasm", __DIR__)
  @component_ref "local.openai:0.1.0"

  setup do
    unless File.exists?(@wasm_source) do
      raise "catalyst.wasm not found at #{@wasm_source} — build with: cd components/catalysts/local/openai/0.1.0 && cargo component build --release"
    end

    test_path = Path.join(System.tmp_dir!(), "emissary_openai_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    # Copy WASM to canonical layout in temp dir so component ref can be derived
    wasm_dir = Path.join(test_path, "catalysts/local/openai/0.1.0")
    File.mkdir_p!(wasm_dir)
    wasm_path = Path.join(wasm_dir, "catalyst.wasm")
    File.cp!(@wasm_source, wasm_path)

    ctx = Sanctum.Context.local()

    on_exit(fn ->
      Sanctum.PolicyStore.delete(@component_ref)

      try do
        Sanctum.Secrets.delete(ctx, "OPENAI_API_KEY")
      rescue
        _ -> :ok
      end

      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: ctx, wasm_path: wasm_path}
  end

  defp init_session(conn) do
    init_conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "clientInfo" => %{"name" => "openai-catalyst-test", "version" => "1.0"}
        }
      })

    assert json_response(init_conn, 200)
    [session_id] = get_resp_header(init_conn, "mcp-session-id")
    session_id
  end

  defp call_tool(conn, session_id, tool_name, arguments, id \\ 2) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-session-id", session_id)
    |> post("/mcp", %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{
        "name" => tool_name,
        "arguments" => arguments
      }
    })
  end

  describe "execute without policy" do
    test "returns isError: true in MCP response", %{conn: conn, wasm_path: wp} do
      session_id = init_session(conn)

      tool_conn = call_tool(conn, session_id, "execution", %{
        "action" => "run",
        "reference" => %{"local" => wp},
        "input" => %{
          "operation" => "models.list",
          "params" => %{},
          "stream" => false
        },
        "type" => "catalyst"
      })

      response = json_response(tool_conn, 200)
      assert response["result"]["isError"] == true
      [content] = response["result"]["content"]
      assert content["text"] =~ "allowed_domains"

      Session.terminate(session_id)
    end
  end

  describe "full lifecycle through HTTP" do
    @tag :integration
    test "init session -> execute catalyst -> verify response", %{conn: conn, ctx: ctx, wasm_path: wp} do
      key = System.get_env("OPENAI_API_KEY")
      unless key, do: ExUnit.Assertions.flunk("OPENAI_API_KEY not set")

      :ok = Sanctum.PolicyStore.put(@component_ref, %{
        allowed_domains: ["api.openai.com"],
        timeout: "30s"
      })

      :ok = Sanctum.Secrets.set(ctx, "OPENAI_API_KEY", key)
      :ok = Sanctum.Secrets.grant(ctx, "OPENAI_API_KEY", @component_ref)

      session_id = init_session(conn)

      tool_conn = call_tool(conn, session_id, "execution", %{
        "action" => "run",
        "reference" => %{"local" => wp},
        "input" => %{
          "operation" => "models.list",
          "params" => %{},
          "stream" => false
        },
        "type" => "catalyst"
      })

      response = json_response(tool_conn, 200)

      refute response["result"]["isError"]

      [content] = response["result"]["content"]
      result = Jason.decode!(content["text"])

      assert result["status"] == "completed"
      assert result["result"]["status"] == 200
      assert is_binary(result["execution_id"])
      assert result["component_type"] == "catalyst"

      Session.terminate(session_id)
    end
  end
end
