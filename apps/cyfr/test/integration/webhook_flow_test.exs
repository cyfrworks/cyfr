# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.WebhookFlowIntegrationTest do
  @moduledoc """
  End-to-end test for the inbound webhook pipeline.

  Exercises the *full* HTTP path: router match, `RawBodyReader` body capture
  through `Plug.Parsers`, rate limiter, signature verification, idempotency
  dedup, controller invocation. Catches wiring regressions that unit-level
  plug tests can mask — a working test here means W1 (route) + W2 (body
  reader) + W4 (replay) + W5 (idempotency) are all live in the real
  endpoint.
  """

  use EmissaryWeb.ConnCase, async: false

  alias Sanctum.Webhook

  setup do
    # Webhook controller dispatches `Opus.Executor.run/3` async via
    # `Task.Supervisor.start_child/2`. Tests must synchronize on the task
    # completing (`[:invoke, :stop]`) before exiting, otherwise the
    # ConnCase Ecto sandbox checks the connection back in while the task
    # is mid-query, producing noisy `DBConnection.Holder.checkout` shutdown
    # crashes (the test still passes, but the log is misleading).
    handler_id = "wh-flow-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:cyfr, :emissary, :webhook, :invoke, :stop],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  # Wait for the spawned `Opus.Executor.run/3` task to finish so the test
  # process doesn't exit while the task is mid-DB-query.
  defp await_invoke_stop(request_id) do
    assert_receive {:telemetry, [:cyfr, :emissary, :webhook, :invoke, :stop], _measurements,
                    %{request_id: ^request_id}},
                   2_000
  end

  defp create_hook!(ctx, name, opts \\ %{}) do
    # Registered but artifact-less: create-time target validation passes,
    # execution fails cleanly, which is the path these tests observe.
    comp = "wh-target-#{System.unique_integer([:positive])}"
    Sanctum.Test.ComponentHelpers.register_test_component(comp, "1.0.0", "formula", %{})

    {:ok, result} =
      Webhook.create(
        ctx,
        Map.merge(%{name: name, target_ref: "f:local.#{comp}"}, opts)
      )

    result
  end

  defp hmac_hex(secret, body) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end

  test "happy-path POST reaches controller and accepts async (proves W1 + W2 + body_reader pipeline)",
       %{conn: conn, ctx: ctx} do
    %{slug: slug, secret: secret} = create_hook!(ctx, "happy-path")
    body = ~s({"event":"x","ts":12345})
    sig = "sha256=" <> hmac_hex(secret, body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-cyfr-signature", sig)
      |> post("/hooks/" <> slug, body)

    # 200 accepted with a correlation request_id. Status proves we got past
    # router (not 404) and signature verification (not 401), and that
    # RawBodyReader fed Plug.Parsers correctly (raw body matched HMAC).
    # Component-side errors surface via `[:invoke, :stop]` telemetry inside
    # the spawned task (covered in webhook_controller_test.exs).
    assert conn.status == 200
    response = json_response(conn, 200)
    assert response["status"] == "accepted"
    assert is_binary(response["request_id"])

    await_invoke_stop(response["request_id"])
  end

  test "replay protection rejects out-of-window timestamp at the HTTP edge",
       %{conn: conn, ctx: ctx} do
    %{slug: slug, secret: secret} =
      create_hook!(ctx, "replay-edge", %{timestamp_header: "X-Cyfr-Timestamp"})

    body = ~s({"event":"replay"})
    stale = (System.system_time(:second) - 600) |> Integer.to_string()
    sig = "sha256=" <> hmac_hex(secret, stale <> "." <> body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-cyfr-signature", sig)
      |> put_req_header("x-cyfr-timestamp", stale)
      |> post("/hooks/" <> slug, body)

    assert conn.status == 401
  end

  test "idempotency dedup returns 200 with status:duplicate on repeat delivery",
       %{conn: conn, ctx: ctx} do
    %{slug: slug, secret: secret} =
      create_hook!(ctx, "idem-edge", %{idempotency_key_header: "X-Cyfr-Delivery"})

    body = ~s({"event":"once"})
    sig = "sha256=" <> hmac_hex(secret, body)
    delivery_id = "evt_integration_#{System.unique_integer([:positive])}"

    base_conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-cyfr-signature", sig)
      |> put_req_header("x-cyfr-delivery", delivery_id)

    # First delivery → 200 accepted, async dispatch.
    first = post(base_conn, "/hooks/" <> slug, body)
    assert first.status == 200
    first_response = json_response(first, 200)
    assert first_response["status"] == "accepted"
    await_invoke_stop(first_response["request_id"])

    # Second delivery → idempotency plug short-circuits before the controller
    # to 200 with status:duplicate. The plug runs *before* the controller
    # (router pipeline order: rate limit → verify → idempotency → controller)
    # so dedup happens regardless of async vs sync execution.
    second =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-cyfr-signature", sig)
      |> put_req_header("x-cyfr-delivery", delivery_id)
      |> post("/hooks/" <> slug, body)

    assert second.status == 200
    body = json_response(second, 200)
    assert body["status"] == "duplicate"
    assert is_binary(body["first_seen_at"])
  end

  test "404 on unknown slug returns the JSON error body (proves the verify plug ran, not Phoenix's default)",
       %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-cyfr-signature", "sha256=00")
      |> post("/hooks/wh_does_not_exist", ~s({}))

    assert conn.status == 404
    # Phoenix's default error handler returns "" for unmatched routes, so a
    # JSON body with `error: "not_found"` is proof that our plug halted (not
    # the framework).
    assert json_response(conn, 404)["error"] == "not_found"
  end

  test "body exceeding webhook size cap raises RequestTooLargeError (mapped to 413 by Plug.Exception)",
       %{conn: conn, ctx: ctx} do
    # Lower the cap for this test so we don't have to ship 1 MB of bytes.
    Application.put_env(:cyfr, :webhook_max_body_bytes, 1024)
    on_exit(fn -> Application.delete_env(:cyfr, :webhook_max_body_bytes) end)

    %{slug: slug, secret: secret} = create_hook!(ctx, "too-big")
    body = String.duplicate("x", 4096)
    sig = "sha256=" <> hmac_hex(secret, body)

    # `Plug.Parsers.RequestTooLargeError` implements `Plug.Exception` with
    # status 413, so Phoenix maps it to a 413 response in production. In test
    # the exception propagates; assert it directly + check the wrapped status.
    err =
      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-cyfr-signature", sig)
        |> post("/hooks/" <> slug, body)
      end

    assert Plug.Exception.status(err) == 413
  end

  test "body within webhook size cap passes through the body reader",
       %{conn: conn, ctx: ctx} do
    Application.put_env(:cyfr, :webhook_max_body_bytes, 4096)
    on_exit(fn -> Application.delete_env(:cyfr, :webhook_max_body_bytes) end)

    %{slug: slug, secret: secret} = create_hook!(ctx, "just-small-enough")
    # Valid JSON, padded to ~1 KB but still under the 4 KB cap.
    body = ~s({"event":"x","filler":") <> String.duplicate("a", 1024) <> ~s("})
    sig = "sha256=" <> hmac_hex(secret, body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-cyfr-signature", sig)
      |> post("/hooks/" <> slug, body)

    # Body within cap → reaches controller → 200 accepted (async dispatch).
    # Status proves the cap let it through and the controller dispatched.
    assert conn.status == 200
    response = json_response(conn, 200)
    assert response["status"] == "accepted"
    await_invoke_stop(response["request_id"])
  end
end
