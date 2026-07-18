# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.RequestLogTest do
  use ExUnit.Case, async: false

  alias Emissary.MCP.RequestLog
  alias Emissary.UUID7
  alias Sanctum.Context

  setup do
    # Checkout the Ecto sandbox to isolate SQLite data between tests
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Create a unique request_id for each test
    request_id = UUID7.request_id()
    ctx = %{Sanctum.TestContext.local() | session_id: UUID7.session_id()}

    %{request_id: request_id, ctx: ctx}
  end

  # Helper to fetch an MCP log directly from the database
  defp get_log!(request_id) do
    Arca.Repo.get(Arca.McpLog, request_id)
  end

  defp decode_json(nil), do: nil
  defp decode_json(str) when is_binary(str), do: Jason.decode!(str)

  describe "log_started/3" do
    test "creates initial log entry with pending status", %{request_id: request_id, ctx: ctx} do
      :ok =
        RequestLog.log_started(ctx, request_id, %{
          tool: "storage",
          action: "get",
          method: "tools/call",
          input: %{path: "/some/file"}
        })

      log = get_log!(request_id)

      assert log.id == request_id
      assert log.session_id == ctx.session_id
      assert log.user_id == ctx.user_id
      assert log.tool == "storage"
      assert log.action == "get"
      assert log.method == "tools/call"
      assert log.status == "pending"
      assert decode_json(log.input)["path"] == "/some/file"
      assert log.timestamp
      assert is_nil(log.output)
      assert is_nil(log.duration_ms)
    end

    test "sanitizes sensitive data in input", %{request_id: request_id, ctx: ctx} do
      :ok =
        RequestLog.log_started(ctx, request_id, %{
          tool: "secrets",
          action: "set",
          input: %{
            "name" => "my_secret",
            "secret" => "super_secret_value_123",
            "password" => "hunter2",
            "metadata" => %{
              "token" => "bearer_token_xyz",
              "safe" => "visible"
            }
          }
        })

      log = get_log!(request_id)
      input = decode_json(log.input)

      # Sensitive keys should be redacted
      assert input["secret"] == "[REDACTED]"
      assert input["password"] == "[REDACTED]"
      assert input["metadata"]["token"] == "[REDACTED]"

      # Non-sensitive keys should remain
      assert input["name"] == "my_secret"
      assert input["metadata"]["safe"] == "visible"
    end
  end

  describe "log_completed/2" do
    test "updates log with success status and output", %{request_id: request_id, ctx: ctx} do
      :ok =
        RequestLog.log_started(ctx, request_id, %{
          tool: "storage",
          action: "get",
          input: %{}
        })

      :ok =
        RequestLog.log_completed(ctx, request_id, %{
          output: %{status: "ok", data: "file content"},
          duration_ms: 150,
          routed_to: "arca"
        })

      log = get_log!(request_id)

      assert log.status == "success"
      assert decode_json(log.output)["status"] == "ok"
      assert log.duration_ms == 150
      assert log.routed_to == "arca"
    end
  end

  describe "log_failed/2" do
    test "updates log with error status and error info", %{request_id: request_id, ctx: ctx} do
      :ok =
        RequestLog.log_started(ctx, request_id, %{
          tool: "execution",
          action: "run",
          input: %{}
        })

      :ok =
        RequestLog.log_failed(ctx, request_id, %{
          error: "Component not found",
          code: -32602,
          duration_ms: 10
        })

      log = get_log!(request_id)

      assert log.status == "error"
      assert log.error == "Component not found"
      assert log.error_code == -32602
      assert log.duration_ms == 10
    end
  end

  describe "direct log lookup" do
    test "returns nil for non-existent log" do
      assert is_nil(Arca.Repo.get(Arca.McpLog, "req_nonexistent_123"))
    end
  end

  describe "log filtering" do
    test "filters by status" do
      ctx = Sanctum.TestContext.local()
      req1 = UUID7.request_id()
      req2 = UUID7.request_id()

      # Create a successful request
      :ok = RequestLog.log_started(ctx, req1, %{tool: "test_filter_success", input: %{}})

      :ok =
        RequestLog.log_completed(ctx, req1, %{output: %{}, duration_ms: 10, routed_to: "test"})

      # Create a failed request
      :ok = RequestLog.log_started(ctx, req2, %{tool: "test_filter_error", input: %{}})
      :ok = RequestLog.log_failed(ctx, req2, %{error: "fail", code: -1, duration_ms: 5})

      # Verify the logs were written by reading them directly
      log1 = get_log!(req1)
      log2 = get_log!(req2)

      assert log1.status == "success"
      assert log2.status == "error"

      # Test that list filtering returns correct results
      success_logs =
        Arca.McpLog.list(status: "success", limit: 10, org_id: "local", project_id: "default")

      error_logs =
        Arca.McpLog.list(status: "error", limit: 10, org_id: "local", project_id: "default")

      for log <- success_logs do
        assert log.status == "success"
      end

      for log <- error_logs do
        assert log.status == "error"
      end
    end
  end

  describe "sanitize_input/1" do
    test "redacts password variants" do
      input = %{
        "password" => "secret",
        "passwd" => "secret",
        "pwd" => "secret"
      }

      result = RequestLog.sanitize_input(input)

      assert result["password"] == "[REDACTED]"
      assert result["passwd"] == "[REDACTED]"
      assert result["pwd"] == "[REDACTED]"
    end

    test "redacts token variants" do
      input = %{
        "token" => "abc123",
        "access_token" => "xyz789",
        "refresh_token" => "refresh123",
        "bearer" => "bearer_token"
      }

      result = RequestLog.sanitize_input(input)

      assert result["token"] == "[REDACTED]"
      assert result["access_token"] == "[REDACTED]"
      assert result["refresh_token"] == "[REDACTED]"
      assert result["bearer"] == "[REDACTED]"
    end

    test "redacts API key variants" do
      input = %{
        "api_key" => "key123",
        "apikey" => "key456",
        "api-key" => "key789",
        "x-api-key" => "keyabc"
      }

      result = RequestLog.sanitize_input(input)

      assert result["api_key"] == "[REDACTED]"
      assert result["apikey"] == "[REDACTED]"
      assert result["api-key"] == "[REDACTED]"
      assert result["x-api-key"] == "[REDACTED]"
    end

    test "redacts secret variants" do
      input = %{
        "secret" => "shh",
        "secret_key" => "shhh",
        "private_key" => "very_private"
      }

      result = RequestLog.sanitize_input(input)

      assert result["secret"] == "[REDACTED]"
      assert result["secret_key"] == "[REDACTED]"
      assert result["private_key"] == "[REDACTED]"
    end

    test "handles nested maps" do
      input = %{
        "outer" => %{
          "password" => "nested_secret",
          "safe" => "visible"
        }
      }

      result = RequestLog.sanitize_input(input)

      assert result["outer"]["password"] == "[REDACTED]"
      assert result["outer"]["safe"] == "visible"
    end

    test "handles lists" do
      input = [
        %{"password" => "secret1"},
        %{"password" => "secret2", "name" => "test"}
      ]

      result = RequestLog.sanitize_input(input)

      assert Enum.at(result, 0)["password"] == "[REDACTED]"
      assert Enum.at(result, 1)["password"] == "[REDACTED]"
      assert Enum.at(result, 1)["name"] == "test"
    end

    test "handles atom keys" do
      input = %{
        password: "secret",
        api_key: "key123",
        safe: "visible"
      }

      result = RequestLog.sanitize_input(input)

      assert result[:password] == "[REDACTED]"
      assert result[:api_key] == "[REDACTED]"
      assert result[:safe] == "visible"
    end

    test "preserves non-sensitive data" do
      input = %{
        "name" => "test_component",
        "version" => "1.0.0",
        "count" => 42,
        "enabled" => true
      }

      result = RequestLog.sanitize_input(input)

      assert result == input
    end
  end
end
