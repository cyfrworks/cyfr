# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.WebhookFlowIntegrationTest do
  @moduledoc """
  End-to-end test for the inbound webhook pipeline.

  Exercises the *full* HTTP path: router match, `RawBodyReader` body capture
  through `Plug.Parsers`, rate limiter, signature verification, idempotency
  dedup, controller invocation. Catches wiring regressions that unit-level
  plug tests can mask — a working test here means W1 (route) + W2 (body
  reader) + W4 (replay) + W5 (idempotency) are all live in the real
  endpoint.

  A delivery whose target names a connection runs in a real runner of the
  Opus service: CYFR attaches the bound key to the guest's request while
  the binding is live, and refuses the request of a delivery after the
  binding's instant before any upstream request.
  """

  use CyfrWeb.ConnCase, async: false

  setup do
    # Webhook controller dispatches `Crucible.Dispatch.run/4` async via
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

  # Wait for the spawned `Crucible.Dispatch.run/4` task to finish so the test
  # process doesn't exit while the task is mid-DB-query.
  defp await_invoke_stop(request_id) do
    assert_receive {:telemetry, [:cyfr, :emissary, :webhook, :invoke, :stop], _measurements,
                    %{request_id: ^request_id}},
                   2_000
  end

  defp create_hook!(ctx, name, opts \\ %{}) do
    # ConnCase configures an auth provider, so the webhook's owner must hold
    # a live membership or the owner re-check refuses the invoke.
    {:ok, _} = Sanctum.Tenancy.Members.ensure(ctx.user_id, scope: "platform")

    # Registered but artifact-less: create-time target validation passes,
    # execution fails cleanly, which is the path these tests observe.
    comp = "wh-target-#{System.unique_integer([:positive])}"
    Sanctum.Test.ComponentHelpers.register_test_component(comp, "1.0.0", "formula", %{})
    profile = Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "f:local.#{comp}")

    {:ok, result} =
      Sanctum.TestContext.create_webhook(
        ctx,
        Map.merge(%{name: name, target_ref: "f:local.#{comp}", profile_id: profile}, opts)
        # After the merge, so a fixture naming a real header still wins.
        |> Map.put_new(:replay_protection, "none")
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

  test "a failed delivery is retryable; a delivery that ran is a duplicate",
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

    # Failed async execution releases the claim, so the sender’s retry
    # must be accepted.
    {:ok, hook_row} = Arca.WebhookStorage.get_by_slug(slug)

    # The claim is settled after the stop event; until it is, the delivery
    # is still in flight and a retry reads as a duplicate, which runs
    # nothing.
    test = self()

    Prima.Test.Wait.wait_until(
      fn ->
        retry =
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("x-cyfr-signature", sig)
          |> put_req_header("x-cyfr-delivery", delivery_id)
          |> post("/hooks/" <> slug, body)
          |> json_response(200)

        if retry["status"] == "accepted", do: send(test, {:retry_accepted, retry["request_id"]})
        retry["status"] == "accepted"
      end,
      2_000,
      "the failed delivery's retry to be accepted"
    )

    assert_receive {:retry_accepted, retry_request_id}
    await_invoke_stop(retry_request_id)

    # And a delivery whose claim is live — staked here rather than raced
    # for — is still deduped over the real HTTP path. `claimed` means "in
    # flight somewhere", which is exactly when a second delivery must not
    # run the target again.
    live_id = "evt_live_#{System.unique_integer([:positive])}"
    assert :fresh = Arca.WebhookDeliveryStorage.record(hook_row.id, live_id)

    second =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-cyfr-signature", sig)
      |> put_req_header("x-cyfr-delivery", live_id)
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
    assert json_response(conn, 404)["code"] == "not_found"
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

  defmodule Upstream do
    @moduledoc false
    # A loopback upstream that tells the test what it was sent.
    @behaviour Plug

    @impl true
    def init(test), do: test

    @impl true
    def call(conn, test) do
      send(test, {:upstream, %{path: conn.request_path, headers: conn.req_headers}})
      Plug.Conn.send_resp(conn, 200, "webhook upstream")
    end
  end

  @attached_probe Path.expand(
                    "../../../opus/test/support/test_wasm/hostile/attached_header_probe.wasm",
                    __DIR__
                  )
  @attached_secret "sk-webhook-e7-canary-93c0a7"

  # The probe of Opus's hostile guests that sends its input as its one
  # request, published as a component of the person's own whose need
  # `api_key` CYFR attaches by header, its entry bound until `until` under a
  # consent that admits webhook deliveries, and a webhook firing it with
  # `input` as its template.
  defp attached_hook!(ctx, port, until, input) do
    {:ok, _} = Sanctum.Tenancy.Members.ensure(ctx.user_id, scope: "platform")
    walk = Sanctum.TestContext.via(ctx, :prism)
    name = "webhook-probe-#{System.unique_integer([:positive])}"

    manifest = %{
      "name" => name,
      "version" => "1.0.0",
      "type" => "catalyst",
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:upstream.test",
          "reason" => "to call the upstream with your key",
          "fields" => ["KEY"],
          "attach" => %{"in" => "header", "name" => "x-api-key", "template" => "{value}"}
        }
      },
      "caps" => %{
        "egress" => %{
          "domains" => ["127.0.0.1"],
          "methods" => ["GET"],
          "schemes" => ["http"],
          "private_ips" => ["127.0.0.1"]
        }
      }
    }

    {:ok, _component} =
      Compendium.Registry.publish_bytes(walk, File.read!(@attached_probe), %{
        name: name,
        version: "1.0.0",
        type: "catalyst",
        manifest: Jason.encode!(manifest)
      })

    {:ok, entry} =
      Sanctum.TestContext.create_vault(walk, %{
        name: "#{name} key",
        kind: "api_key",
        provider_hint: "upstream.test",
        fields: %{"KEY" => @attached_secret},
        destination: %{"hosts" => ["127.0.0.1"], "scheme" => "http", "port" => port}
      })

    ref = "catalyst:local." <> name

    decisions = %{
      ref: ref,
      bindings: [
        %{
          need: "api_key",
          entry_id: entry.id,
          lifetime: %{kind: "until", until: DateTime.to_iso8601(until)}
        }
      ],
      origins: [:interactive, :webhook]
    }

    {:ok, plan} = Sanctum.Consent.Plan.plan(walk, %{ref: ref})
    {:ok, preview} = Sanctum.Consent.Commit.preview(walk, decisions)

    {:ok, %{profile_id: profile_id}} =
      Sanctum.Consent.Commit.commit(walk, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    {:ok, hook} =
      Sanctum.TestContext.create_webhook(ctx, %{
        name: name,
        target_ref: ref,
        profile_id: profile_id,
        input_template: input,
        replay_protection: "none"
      })

    hook
  end

  # One delivery, signed, and the run it fired, awaited to its end: the
  # guest's answer as its runner closed the attempt with it.
  defp deliver!(%{slug: slug, secret: secret}) do
    body = ~s({"event":"fired"})

    response =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-cyfr-signature", "sha256=" <> hmac_hex(secret, body))
      |> post("/hooks/" <> slug, body)
      |> json_response(200)

    assert %{"status" => "accepted", "request_id" => request_id} = response

    assert_receive {:telemetry, [:cyfr, :emissary, :webhook, :invoke, :stop], _measurements,
                    %{request_id: ^request_id}},
                   30_000

    assert %{args: %{"outcome" => %{"output" => output}}} =
             Cyfr.Test.TwoServices.calls()
             |> Enum.filter(&(&1.callback == :complete))
             |> List.last()

    output
  end

  test "a webhook attached request succeeds before expiry and is refused after it", %{ctx: ctx} do
    upstream =
      start_supervised!(
        {Bandit, plug: {Upstream, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(upstream)
    Cyfr.Test.TwoServices.watch!()

    until = DateTime.utc_now() |> DateTime.add(8, :second) |> DateTime.truncate(:second)

    hook =
      attached_hook!(ctx, port, until, %{
        "connection" => "api_key",
        "method" => "GET",
        "url" => "http://127.0.0.1:#{port}/delivered"
      })

    # Before the instant: the delivery's run reaches the upstream, the key
    # attached by CYFR; the guest's request names the connection beside
    # the delivery's envelope, which the runner ignores.
    assert %{"status" => 200, "body" => "webhook upstream"} = deliver!(hook)
    assert_receive {:upstream, sent}, 5_000
    assert sent.path == "/delivered" and {"x-api-key", @attached_secret} in sent.headers

    Prima.Test.Wait.wait_until(
      fn -> DateTime.compare(DateTime.utc_now(), until) == :gt end,
      15_000,
      "the binding's instant to pass"
    )

    # After it: the next delivery's request is refused before any upstream
    # request.
    assert %{"error" => %{"type" => "grant_expired", "message" => message}} = deliver!(hook)
    assert message == Prima.Refusal.message(:grant_expired)
    refute_received {:upstream, _sent}
  end
end
