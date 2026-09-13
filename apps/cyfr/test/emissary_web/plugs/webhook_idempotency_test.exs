# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.WebhookIdempotencyTest do
  use ExUnit.Case, async: false

  alias EmissaryWeb.Plugs.WebhookIdempotency
  alias Sanctum.Webhook

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp create_hook!(ctx, name, opts \\ %{}) do
    Sanctum.Test.ComponentHelpers.register_test_component("handler", "1.0.0", "formula", %{})
    Sanctum.Test.ConsentFixtures.start_source!()
    profile = Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "f:local.handler")

    {:ok, %{slug: slug}} =
      Webhook.create(
        ctx,
        Map.merge(%{name: name, target_ref: "f:local.handler", profile_id: profile}, opts)
        |> Map.put_new(:replay_protection, "none")
      )

    {:ok, row} = Arca.WebhookStorage.get_by_slug(slug)
    row
  end

  defp build_conn_with_webhook(webhook, headers) do
    conn =
      Plug.Test.conn(:post, "/hooks/" <> webhook.slug, "{}")
      |> Map.put(:path_params, %{"slug" => webhook.slug})
      |> Plug.Conn.assign(:webhook, webhook)
      |> Plug.Conn.assign(:raw_body, "{}")

    Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
  end

  describe "no idempotency_key_header configured" do
    test "passes through unchanged", %{ctx: ctx} do
      webhook = create_hook!(ctx, "no-idem")
      assert webhook.idempotency_key_header == nil

      conn = build_conn_with_webhook(webhook, [])
      result = WebhookIdempotency.call(conn, [])

      refute result.halted
      assert result.status == nil
    end
  end

  describe "idempotency_key_header configured" do
    test "fresh delivery passes through", %{ctx: ctx} do
      webhook = create_hook!(ctx, "fresh", %{idempotency_key_header: "X-Cyfr-Delivery"})

      conn = build_conn_with_webhook(webhook, [{"x-cyfr-delivery", "evt_1"}])
      result = WebhookIdempotency.call(conn, [])

      refute result.halted
    end

    test "duplicate delivery returns 200 with status:duplicate", %{ctx: ctx} do
      webhook = create_hook!(ctx, "dup", %{idempotency_key_header: "X-Cyfr-Delivery"})

      # First time: fresh.
      conn1 = build_conn_with_webhook(webhook, [{"x-cyfr-delivery", "evt_dup"}])
      r1 = WebhookIdempotency.call(conn1, [])
      refute r1.halted

      # Second time: duplicate.
      conn2 = build_conn_with_webhook(webhook, [{"x-cyfr-delivery", "evt_dup"}])
      r2 = WebhookIdempotency.call(conn2, [])

      assert r2.halted
      assert r2.status == 200

      body = Jason.decode!(r2.resp_body)
      assert body["status"] == "duplicate"
      assert is_binary(body["first_seen_at"])
    end

    test "missing header on a webhook configured for it is refused",
         %{ctx: ctx} do
      # Configuring the header is the operator's statement that every real
      # delivery carries it. Letting a header-less request through made the
      # dedup opt-out per request — a replayer just stripped the header.
      webhook = create_hook!(ctx, "missing", %{idempotency_key_header: "X-Cyfr-Delivery"})

      conn = build_conn_with_webhook(webhook, [])
      result = WebhookIdempotency.call(conn, [])

      assert result.halted
      assert result.status == 400
      assert Jason.decode!(result.resp_body)["code"] == "missing_idempotency_key"
    end

    test "different keys do not collide", %{ctx: ctx} do
      webhook = create_hook!(ctx, "k1", %{idempotency_key_header: "X-Cyfr-Delivery"})

      r1 =
        webhook
        |> build_conn_with_webhook([{"x-cyfr-delivery", "key_a"}])
        |> WebhookIdempotency.call([])

      r2 =
        webhook
        |> build_conn_with_webhook([{"x-cyfr-delivery", "key_b"}])
        |> WebhookIdempotency.call([])

      refute r1.halted
      refute r2.halted
    end

    test "same key on different webhooks does not collide", %{ctx: ctx} do
      w1 = create_hook!(ctx, "wh-a", %{idempotency_key_header: "X-Cyfr-Delivery"})
      w2 = create_hook!(ctx, "wh-b", %{idempotency_key_header: "X-Cyfr-Delivery"})

      r1 =
        w1
        |> build_conn_with_webhook([{"x-cyfr-delivery", "shared"}])
        |> WebhookIdempotency.call([])

      r2 =
        w2
        |> build_conn_with_webhook([{"x-cyfr-delivery", "shared"}])
        |> WebhookIdempotency.call([])

      refute r1.halted
      refute r2.halted
    end
  end

  describe "a claim staked for a delivery that failed" do
    # Claim before dispatch to serialize duplicate deliveries; release failed claims for retry.

    defp send_status(conn, status) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, "{}")
    end

    test "is released when the delivery answers a failure status", %{ctx: ctx} do
      webhook = create_hook!(ctx, "rel-fail", %{idempotency_key_header: "X-Cyfr-Delivery"})
      headers = [{"x-cyfr-delivery", "evt_failed"}]

      build_conn_with_webhook(webhook, headers)
      |> WebhookIdempotency.call([])
      |> send_status(502)

      # The retry is a fresh delivery, not a duplicate.
      retry =
        build_conn_with_webhook(webhook, headers)
        |> WebhookIdempotency.call([])

      refute retry.halted
      assert retry.status == nil
    end

    test "is kept when the delivery succeeded", %{ctx: ctx} do
      webhook = create_hook!(ctx, "rel-ok", %{idempotency_key_header: "X-Cyfr-Delivery"})
      headers = [{"x-cyfr-delivery", "evt_ok"}]

      build_conn_with_webhook(webhook, headers)
      |> WebhookIdempotency.call([])
      |> send_status(200)

      replay =
        build_conn_with_webhook(webhook, headers)
        |> WebhookIdempotency.call([])

      assert replay.halted
      assert replay.status == 200
      assert Jason.decode!(replay.resp_body)["status"] == "duplicate"
    end

    test "a duplicate does not release the original's claim", %{ctx: ctx} do
      # The duplicate response is itself a 200, but even a non-2xx duplicate
      # must not hand back a claim this request never staked.
      webhook = create_hook!(ctx, "rel-dup", %{idempotency_key_header: "X-Cyfr-Delivery"})
      headers = [{"x-cyfr-delivery", "evt_keep"}]

      build_conn_with_webhook(webhook, headers)
      |> WebhookIdempotency.call([])
      |> send_status(200)

      # A second delivery halts as a duplicate...
      build_conn_with_webhook(webhook, headers)
      |> WebhookIdempotency.call([])

      # ...and a third still sees the original claim.
      third =
        build_conn_with_webhook(webhook, headers)
        |> WebhookIdempotency.call([])

      assert third.halted
      assert Jason.decode!(third.resp_body)["status"] == "duplicate"
    end
  end

  describe "Arca.WebhookDeliveryStorage.sweep/1" do
    test "deletes rows older than the cutoff, keeps newer rows", %{ctx: ctx} do
      webhook = create_hook!(ctx, "sweep", %{idempotency_key_header: "X-Cyfr-Delivery"})

      # Record a fresh delivery.
      assert :fresh = Arca.WebhookDeliveryStorage.record(webhook.id, "key1")

      # Sweep with cutoff far in the past — nothing should be deleted.
      cutoff_past = DateTime.add(DateTime.utc_now(), -3600, :second)
      assert {:ok, 0} = Arca.WebhookDeliveryStorage.sweep(cutoff_past)

      # Sweep with cutoff in the future — record should be deleted.
      cutoff_future = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert {:ok, count} = Arca.WebhookDeliveryStorage.sweep(cutoff_future)
      assert count >= 1

      # After sweep, recording the same key is fresh again.
      assert :fresh = Arca.WebhookDeliveryStorage.record(webhook.id, "key1")
    end
  end

  describe "the claim follows the work, not the response" do
    test "a failed delivery is re-deliverable; a succeeded one is not", %{ctx: ctx} do
      hook =
        create_hook!(ctx, "idem-life-#{:rand.uniform(1_000_000)}", %{
          idempotency_key_header: "x-delivery-id"
        })

      conn = build_conn_with_webhook(hook, [{"x-delivery-id", "evt-1"}])

      # First delivery claims.
      assert %{halted: false} = WebhookIdempotency.call(conn, %{})
      assert {:duplicate, _} = Arca.WebhookDeliveryStorage.record(hook.id, "evt-1")

      # The task reports it failed — the sender is entitled to retry.
      :ok = Arca.WebhookDeliveryStorage.settle(hook.id, "evt-1", :failed)
      assert :fresh = Arca.WebhookDeliveryStorage.record(hook.id, "evt-1")

      # This time it ran. Now a retry really is a duplicate.
      :ok = Arca.WebhookDeliveryStorage.settle(hook.id, "evt-1", :succeeded)
      assert {:duplicate, _} = Arca.WebhookDeliveryStorage.record(hook.id, "evt-1")
    end

    test "a claim in flight is a duplicate — settling is not the same as never having run",
         %{ctx: ctx} do
      hook =
        create_hook!(ctx, "idem-inflight-#{:rand.uniform(1_000_000)}", %{
          idempotency_key_header: "x-delivery-id"
        })

      assert :fresh = Arca.WebhookDeliveryStorage.record(hook.id, "evt-2")
      # Still `claimed`: another node must not run it concurrently.
      assert {:duplicate, _} = Arca.WebhookDeliveryStorage.record(hook.id, "evt-2")
    end

    test "the plug hands the claim to the controller", %{ctx: ctx} do
      hook =
        create_hook!(ctx, "idem-claim-#{:rand.uniform(1_000_000)}", %{
          idempotency_key_header: "x-delivery-id"
        })

      conn =
        hook
        |> build_conn_with_webhook([{"x-delivery-id", "evt-3"}])
        |> WebhookIdempotency.call(%{})

      assert conn.assigns[:webhook_delivery_claim] == {hook.id, "evt-3"}
    end
  end

  describe "the timestamp path dedupes on the signature" do
    test "a replay inside the skew window is refused without an idempotency header",
         %{ctx: ctx} do
      hook =
        create_hook!(ctx, "idem-nonce-#{:rand.uniform(1_000_000)}", %{
          timestamp_header: "x-timestamp"
        })

      headers = [{"x-timestamp", "1234567890"}, {"x-cyfr-signature", "sha256=deadbeef"}]

      first = hook |> build_conn_with_webhook(headers) |> WebhookIdempotency.call(%{})
      refute first.halted
      assert first.assigns[:webhook_delivery_claim]

      # Same signature — same (timestamp, body) — is the same delivery.
      second = hook |> build_conn_with_webhook(headers) |> WebhookIdempotency.call(%{})
      assert second.halted
      assert second.status == 200
      assert second.resp_body =~ "duplicate"
    end

    test "a webhook with neither header still dedupes nothing", %{ctx: ctx} do
      hook = create_hook!(ctx, "idem-none-#{:rand.uniform(1_000_000)}")

      conn = hook |> build_conn_with_webhook([]) |> WebhookIdempotency.call(%{})
      refute conn.halted
      refute conn.assigns[:webhook_delivery_claim]
    end
  end
end
