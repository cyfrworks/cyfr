# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.RequestLogTest do
  @moduledoc """
  The request log's rows as projections of admission decisions: a
  decision opened with its row in one write, the row closed with the
  decision's completion, no row for a decision without a tenant, and an
  append that cannot land answered `:ok` with the loss event.
  """
  use ExUnit.Case, async: false

  alias Grimoire.{Decisions, RequestLog}
  alias Prima.{Decision, UUID7}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = %{Sanctum.TestContext.local() | request_id: UUID7.request_id()}
    %{ctx: ctx}
  end

  defp decision(ctx, extra \\ []) do
    Decision.new(
      Keyword.merge(
        [
          call_id: UUID7.generate_id("call"),
          request_id: ctx.request_id,
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          plane: :external,
          tool: "storage",
          action: "get",
          inserted_at: DateTime.utc_now(),
          admission: :admitted
        ],
        extra
      )
    )
  end

  defp row(call_id), do: Arca.Repo.get(Arca.Schemas.McpLog, call_id)

  defp stored(call_id),
    do: Arca.Repo.get(Arca.Schemas.DecisionLog, call_id)

  defp decode_json(nil), do: nil
  defp decode_json(str) when is_binary(str), do: Jason.decode!(str)

  defp attach(event) do
    ref = make_ref()
    test = self()

    :telemetry.attach(
      {__MODULE__, ref},
      event,
      fn name, measurements, metadata, _ -> send(test, {ref, name, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  describe "open/3" do
    test "an admitted decision leaves a pending row and the decision, one write", %{ctx: ctx} do
      decision = decision(ctx)

      assert :ok =
               Decisions.open(ctx, decision, %{
                 method: "tools/call",
                 input: %{"action" => "get", "path" => "/some/file"}
               })

      log = row(decision.call_id)
      assert log.id == decision.call_id
      assert log.request_id == ctx.request_id
      assert log.user_id == ctx.user_id
      assert log.athanor_id == ctx.athanor_id
      assert log.tool == "storage"
      assert log.action == "get"
      assert log.method == "tools/call"
      assert log.status == "pending"
      assert log.refusal_class == nil
      assert decode_json(log.input)["path"] == "/some/file"
      assert DateTime.compare(log.timestamp, decision.inserted_at) == :eq
      assert is_nil(log.output)
      assert is_nil(log.duration_ms)

      assert %{admission: "admitted", athanor_id: athanor, completion: nil} =
               stored(decision.call_id)

      assert athanor == ctx.athanor_id
    end

    test "the method defaults to tools/call", %{ctx: ctx} do
      decision = decision(ctx)
      assert :ok = Decisions.open(ctx, decision)
      assert row(decision.call_id).method == "tools/call"
    end

    test "a refused decision is a closed error row with its class and sentence", %{ctx: ctx} do
      decision =
        decision(ctx, admission: :refused, refusal_class: :forbidden, reason: "Not allowed.")

      assert :ok = Decisions.open(ctx, decision, %{input: %{"action" => "get"}})

      log = row(decision.call_id)
      assert log.status == "error"
      assert log.refusal_class == "forbidden"
      assert log.error == "Not allowed."
      assert log.error_code == nil

      assert %{admission: "refused", refusal_class: "forbidden", reason: "Not allowed."} =
               stored(decision.call_id)
    end

    test "input is sanitized before it is stored", %{ctx: ctx} do
      decision = decision(ctx)

      assert :ok =
               Decisions.open(ctx, decision, %{
                 input: %{
                   "name" => "my_secret",
                   "secret" => "super_secret_value_123",
                   "password" => "hunter2",
                   "metadata" => %{"token" => "bearer_token_xyz", "safe" => "visible"}
                 }
               })

      input = decode_json(row(decision.call_id).input)
      assert input["secret"] == "[REDACTED]"
      assert input["password"] == "[REDACTED]"
      assert input["metadata"]["token"] == "[REDACTED]"
      assert input["name"] == "my_secret"
      assert input["metadata"]["safe"] == "visible"
    end

    test "a decision without a tenant has no row: the decision alone", %{ctx: ctx} do
      platform = Sanctum.Context.internal()
      decision = decision(platform, request_id: ctx.request_id)

      assert :ok = Decisions.open(platform, decision, %{input: %{}})
      assert row(decision.call_id) == nil
      assert %{athanor_id: nil, user_id: "system"} = stored(decision.call_id)

      refused =
        decision(%{platform | user_id: nil},
          admission: :refused,
          refusal_class: :unauthenticated,
          reason: "Sign in."
        )

      assert :ok = Decisions.open(nil, refused)
      assert row(refused.call_id) == nil
      assert %{athanor_id: nil, user_id: nil, admission: "refused"} = stored(refused.call_id)
    end

    test "the decision's event is emitted, admitted or refused", %{ctx: ctx} do
      admitted = attach([:cyfr, :grimoire, :decision, :admitted])
      refused = attach([:cyfr, :grimoire, :decision, :refused])

      assert :ok = Decisions.open(ctx, decision(ctx))
      assert_receive {^admitted, _, %{count: 1}, %{plane: :external, tool: "storage"}}

      assert :ok =
               Decisions.open(
                 ctx,
                 decision(ctx, admission: :refused, refusal_class: :not_found, reason: "Gone.")
               )

      assert_receive {^refused, _, %{count: 1}, %{refusal_class: :not_found}}
    end

    test "an append that cannot land answers :ok, emits the decision and the loss", %{ctx: ctx} do
      admitted = attach([:cyfr, :grimoire, :decision, :admitted])
      lost = attach([:cyfr, :grimoire, :decision, :lost])

      # The call id already holds another decision: this one cannot land.
      held = decision(ctx)
      assert :ok = Decisions.open(ctx, held, %{input: %{}})
      assert_receive {^admitted, _, _, _}

      assert :ok = Decisions.open(ctx, %{held | action: "list"}, %{input: %{}})
      assert_receive {^admitted, _, _, %{action: "list"}}
      assert_receive {^lost, _, %{count: 1}, %{stage: :append, kind: :conflict}}

      # Nothing of the second was written, row or decision.
      assert row(held.call_id).action == "get"
      assert stored(held.call_id).action == "get"
    end
  end

  describe "close/3" do
    test "a success completes the decision and the row", %{ctx: ctx} do
      decision = decision(ctx)
      :ok = Decisions.open(ctx, decision, %{input: %{}})

      assert :ok =
               Decisions.close(ctx, decision.call_id, %{
                 result: {:ok, %{status: "ok", data: "file content"}},
                 duration_ms: 150,
                 routed_to: "arca"
               })

      log = row(decision.call_id)
      assert log.status == "success"
      assert decode_json(log.output)["status"] == "ok"
      assert log.duration_ms == 150
      assert log.routed_to == "arca"

      assert %{completion: "succeeded", completion_class: nil, duration_ms: 150} =
               stored(decision.call_id)
    end

    test "a failure is failed with its class, and the row carries the sentence, no code",
         %{ctx: ctx} do
      decision = decision(ctx)
      :ok = Decisions.open(ctx, decision, %{input: %{}})

      assert :ok =
               Decisions.close(ctx, decision.call_id, %{
                 result: {:error, {:not_found, "component", "c1"}},
                 duration_ms: 10
               })

      log = row(decision.call_id)
      assert log.status == "error"
      assert log.error == Grimoire.render({:not_found, "component", "c1"})
      assert log.duration_ms == 10
      # The meaning is the class; a JSON-RPC code is a transport's rendering.
      assert log.error_code == nil

      assert %{completion: "failed", completion_class: "not_found"} = stored(decision.call_id)
    end

    test "cancelled and uncertain ends keep their own outcomes", %{ctx: ctx} do
      for {reason, outcome} <- [
            {{:cancelled, "Tool t was cancelled"}, "cancelled"},
            {{:uncertain, "Tool t crashed; its outcome is unknown"}, "uncertain"}
          ] do
        decision = decision(ctx)
        :ok = Decisions.open(ctx, decision, %{input: %{}})
        :ok = Decisions.close(ctx, decision.call_id, %{result: {:error, reason}, duration_ms: 1})

        assert %{completion: ^outcome, completion_class: ^outcome} = stored(decision.call_id)
        assert row(decision.call_id).status == "error"
      end
    end

    test "a completion that cannot land answers :ok with the loss", %{ctx: ctx} do
      lost = attach([:cyfr, :grimoire, :decision, :lost])

      assert :ok =
               Decisions.close(ctx, UUID7.generate_id("call"), %{
                 result: {:ok, %{}},
                 duration_ms: 1
               })

      assert_receive {^lost, _, %{count: 1}, %{stage: :finish, kind: :not_found}}
    end
  end

  describe "the stored output" do
    # The router re-encodes the tool's structured result as a JSON string
    # under "content"[]."text". A credential a tool legitimately returns to
    # its caller (created API key, webhook secret, session token) must not
    # be persisted verbatim.
    defp closed_output(ctx, output) do
      decision = decision(ctx)
      :ok = Decisions.open(ctx, decision, %{input: %{}})
      :ok = Decisions.close(ctx, decision.call_id, %{result: {:ok, output}, duration_ms: 5})
      row(decision.call_id).output
    end

    test "redacts credentials inside the content text JSON", %{ctx: ctx} do
      output =
        closed_output(ctx, %{
          "content" => [
            %{
              "type" => "text",
              "text" =>
                Jason.encode!(%{
                  "api_key" => "cyfr_pk_super_secret_value",
                  "session_token" => "raw-session-token",
                  "secret" => "whsec_value",
                  "name" => "my-key"
                })
            }
          ],
          "isError" => false
        })

      refute output =~ "cyfr_pk_super_secret_value"
      refute output =~ "raw-session-token"
      refute output =~ "whsec_value"

      [%{"text" => text}] = decode_json(output)["content"]
      inner = Jason.decode!(text)
      assert inner["api_key"] == "[REDACTED]"
      assert inner["session_token"] == "[REDACTED]"
      assert inner["secret"] == "[REDACTED]"
      assert inner["name"] == "my-key"
    end

    test "redacts credentials in structuredContent", %{ctx: ctx} do
      output =
        closed_output(ctx, %{
          "content" => [%{"type" => "text", "text" => "created"}],
          "structuredContent" => %{"secret" => "whsec_value", "slug" => "hook-1"},
          "isError" => false
        })

      refute output =~ "whsec_value"
      assert decode_json(output)["structuredContent"]["secret"] == "[REDACTED]"
      assert decode_json(output)["structuredContent"]["slug"] == "hook-1"
    end

    test "leaves prose text blocks untouched", %{ctx: ctx} do
      output =
        closed_output(ctx, %{
          "content" => [%{"type" => "text", "text" => "all services healthy"}],
          "isError" => false
        })

      [%{"text" => text}] = decode_json(output)["content"]
      assert text == "all services healthy"
    end
  end

  describe "the projections" do
    test "a decision without a tenant projects no row", %{ctx: ctx} do
      assert RequestLog.opened(nil, decision(ctx), %{}) == nil
      assert RequestLog.opened(Sanctum.Context.internal(), decision(ctx), %{}) == nil
    end

    test "a completion's columns leave out what it does not name, and never a code" do
      assert RequestLog.closed({:error, "No."}, %{duration_ms: 3}) ==
               %{status: "error", error: "No.", duration_ms: 3}

      assert %{status: "success", routed_to: "arca"} =
               RequestLog.closed({:ok, %{}}, %{routed_to: "arca"})

      # A JSON-RPC code is a transport's rendering of a class: a caller's
      # code is not a column the gate's rows write.
      refute Map.has_key?(RequestLog.closed({:error, "No."}, %{error_code: -1}), :error_code)
      refute Map.has_key?(RequestLog.closed({:ok, %{}}, %{error_code: -1}), :error_code)
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
