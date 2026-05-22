# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.VerifyWebhookSignatureTest do
  use ExUnit.Case, async: false

  alias EmissaryWeb.Plugs.VerifyWebhookSignature
  alias Sanctum.Webhook

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp create_hook!(ctx, name, opts \\ []) do
    {:ok, result} =
      Webhook.create(
        ctx,
        Map.merge(
          %{name: name, target_ref: "f:local.handler"},
          Map.new(opts)
        )
      )

    result
  end

  defp build_request(slug, body, headers) do
    conn =
      Plug.Test.conn(:post, "/hooks/" <> slug, body)
      |> Map.put(:path_params, %{"slug" => slug})
      |> Plug.Conn.assign(:raw_body, body)

    Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
  end

  defp hmac_hex(secret, body) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end

  test "200/passthrough on valid signature, assigns :webhook", %{ctx: ctx} do
    %{slug: slug, secret: secret} = create_hook!(ctx, "valid")
    body = ~s({"event":"x"})
    sig = "sha256=" <> hmac_hex(secret, body)

    conn = build_request(slug, body, [{"x-cyfr-signature", sig}])

    result = VerifyWebhookSignature.call(conn, [])

    refute result.halted
    assert %{slug: ^slug} = result.assigns[:webhook]
    assert result.assigns[:raw_body] == body
  end

  test "404 on unknown slug" do
    conn = build_request("wh_does_not_exist", "{}", [{"x-cyfr-signature", "sha256=abc"}])

    result = VerifyWebhookSignature.call(conn, [])

    assert result.halted
    assert result.status == 404
    assert result.resp_body =~ "not_found"
  end

  test "404 on disabled webhook (no enumeration leak)", %{ctx: ctx} do
    %{slug: slug, secret: secret} = create_hook!(ctx, "to-disable")
    :ok = Webhook.revoke(ctx, "to-disable")

    body = "{}"
    sig = "sha256=" <> hmac_hex(secret, body)

    conn = build_request(slug, body, [{"x-cyfr-signature", sig}])

    result = VerifyWebhookSignature.call(conn, [])

    assert result.halted
    assert result.status == 404
  end

  test "401 on missing signature header", %{ctx: ctx} do
    %{slug: slug} = create_hook!(ctx, "missing-sig")
    conn = build_request(slug, "{}", [])

    result = VerifyWebhookSignature.call(conn, [])

    assert result.halted
    assert result.status == 401
    assert result.resp_body =~ "unauthorized"
  end

  test "401 on malformed signature header", %{ctx: ctx} do
    %{slug: slug} = create_hook!(ctx, "malformed")

    conn = build_request(slug, "{}", [{"x-cyfr-signature", "not-prefixed-correctly"}])

    result = VerifyWebhookSignature.call(conn, [])

    assert result.halted
    assert result.status == 401
  end

  test "401 on signature mismatch", %{ctx: ctx} do
    %{slug: slug} = create_hook!(ctx, "mismatch")
    conn = build_request(slug, ~s({"x":1}), [{"x-cyfr-signature", "sha256=deadbeef"}])

    result = VerifyWebhookSignature.call(conn, [])

    assert result.halted
    assert result.status == 401
  end

  test "401 when signature signed against different body (tamper detection)", %{ctx: ctx} do
    %{slug: slug, secret: secret} = create_hook!(ctx, "tamper")
    signed_body = ~s({"original":true})
    sig = "sha256=" <> hmac_hex(secret, signed_body)

    delivered_body = ~s({"tampered":true})
    conn = build_request(slug, delivered_body, [{"x-cyfr-signature", sig}])

    result = VerifyWebhookSignature.call(conn, [])

    assert result.halted
    assert result.status == 401
  end

  test "500 when raw_body assign is missing (defensive)", %{ctx: ctx} do
    %{slug: slug, secret: secret} = create_hook!(ctx, "no-raw-body")
    body = "{}"
    sig = "sha256=" <> hmac_hex(secret, body)

    conn =
      Plug.Test.conn(:post, "/hooks/" <> slug, body)
      |> Map.put(:path_params, %{"slug" => slug})
      |> Plug.Conn.put_req_header("x-cyfr-signature", sig)

    # Note: no Plug.Conn.assign(:raw_body, body)

    result = VerifyWebhookSignature.call(conn, [])

    assert result.halted
    assert result.status == 500
  end

  describe "replay protection (timestamp_header set)" do
    test "401 when timestamp header is missing on a webhook configured for it", %{ctx: ctx} do
      %{slug: slug, secret: secret} =
        create_hook!(ctx, "ts-missing", timestamp_header: "X-Cyfr-Timestamp")

      body = ~s({"event":"x"})
      ts = System.system_time(:second) |> Integer.to_string()
      sig = "sha256=" <> hmac_hex(secret, ts <> "." <> body)

      conn = build_request(slug, body, [{"x-cyfr-signature", sig}])
      result = VerifyWebhookSignature.call(conn, [])

      assert result.halted
      assert result.status == 401
    end

    test "200 when valid timestamp + signed payload arrive together", %{ctx: ctx} do
      %{slug: slug, secret: secret} =
        create_hook!(ctx, "ts-valid", timestamp_header: "X-Cyfr-Timestamp")

      body = ~s({"event":"x"})
      ts = System.system_time(:second) |> Integer.to_string()
      sig = "sha256=" <> hmac_hex(secret, ts <> "." <> body)

      conn =
        build_request(slug, body, [
          {"x-cyfr-signature", sig},
          {"x-cyfr-timestamp", ts}
        ])

      result = VerifyWebhookSignature.call(conn, [])

      refute result.halted
      assert result.assigns[:webhook].slug == slug
    end

    test "401 when timestamp is outside the skew window", %{ctx: ctx} do
      %{slug: slug, secret: secret} =
        create_hook!(ctx, "ts-skewed", timestamp_header: "X-Cyfr-Timestamp")

      body = "{}"
      stale = (System.system_time(:second) - 600) |> Integer.to_string()
      sig = "sha256=" <> hmac_hex(secret, stale <> "." <> body)

      conn =
        build_request(slug, body, [
          {"x-cyfr-signature", sig},
          {"x-cyfr-timestamp", stale}
        ])

      result = VerifyWebhookSignature.call(conn, [])

      assert result.halted
      assert result.status == 401
    end

    test "without timestamp_header on the webhook, no timestamp header is required", %{ctx: ctx} do
      %{slug: slug, secret: secret} = create_hook!(ctx, "no-ts-required")

      body = ~s({"event":"y"})
      sig = "sha256=" <> hmac_hex(secret, body)

      conn = build_request(slug, body, [{"x-cyfr-signature", sig}])
      result = VerifyWebhookSignature.call(conn, [])

      refute result.halted
      assert result.assigns[:webhook].slug == slug
    end
  end

  describe "telemetry on verify failures" do
    setup do
      handler_id = "test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        [
          [:cyfr, :emissary, :webhook, :verify_failed],
          [:cyfr, :emissary, :webhook, :verify_succeeded]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits :verify_succeeded on the happy path", %{ctx: ctx} do
      %{slug: slug, secret: secret} = create_hook!(ctx, "tel-success")
      body = ~s({"event":"x"})
      sig = "sha256=" <> hmac_hex(secret, body)

      conn = build_request(slug, body, [{"x-cyfr-signature", sig}])
      result = VerifyWebhookSignature.call(conn, [])

      refute result.halted

      assert_receive {:telemetry, [:cyfr, :emissary, :webhook, :verify_succeeded], %{count: 1},
                      %{slug: ^slug, webhook_id: webhook_id}}

      assert is_binary(webhook_id)
    end

    test "emits :signature_mismatch on bad signature", %{ctx: ctx} do
      %{slug: slug} = create_hook!(ctx, "tel-mismatch")
      conn = build_request(slug, "{}", [{"x-cyfr-signature", "sha256=00"}])
      VerifyWebhookSignature.call(conn, [])

      assert_receive {:telemetry, _event, %{count: 1},
                      %{slug: ^slug, reason: :signature_mismatch}}
    end

    test "emits :missing_signature when header is absent", %{ctx: ctx} do
      %{slug: slug} = create_hook!(ctx, "tel-nosig")
      conn = build_request(slug, "{}", [])
      VerifyWebhookSignature.call(conn, [])

      assert_receive {:telemetry, _, _, %{slug: ^slug, reason: :missing_signature}}
    end

    test "emits :not_found_or_disabled on unknown slug" do
      conn = build_request("wh_nope", "{}", [{"x-cyfr-signature", "sha256=00"}])
      VerifyWebhookSignature.call(conn, [])

      assert_receive {:telemetry, _, _, %{reason: :not_found_or_disabled}}
    end

    test "emits :timestamp_skew when timestamp is too old", %{ctx: ctx} do
      %{slug: slug, secret: secret} =
        create_hook!(ctx, "tel-skew", timestamp_header: "X-Cyfr-Timestamp")

      stale = (System.system_time(:second) - 600) |> Integer.to_string()
      sig = "sha256=" <> hmac_hex(secret, stale <> "." <> "{}")

      conn =
        build_request(slug, "{}", [
          {"x-cyfr-signature", sig},
          {"x-cyfr-timestamp", stale}
        ])

      VerifyWebhookSignature.call(conn, [])

      assert_receive {:telemetry, _, _, %{slug: ^slug, reason: :timestamp_skew}}
    end
  end

  test "honors custom signature_header configured on the webhook", %{ctx: ctx} do
    %{slug: slug, secret: secret} =
      create_hook!(ctx, "custom-header", signature_header: "X-Hub-Signature-256")

    body = ~s({"github":"event"})
    sig = "sha256=" <> hmac_hex(secret, body)

    # Default header should NOT work
    conn1 = build_request(slug, body, [{"x-cyfr-signature", sig}])
    r1 = VerifyWebhookSignature.call(conn1, [])
    assert r1.halted
    assert r1.status == 401

    # Custom header should work
    conn2 = build_request(slug, body, [{"x-hub-signature-256", sig}])
    r2 = VerifyWebhookSignature.call(conn2, [])
    refute r2.halted
  end
end
