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
    {:ok, %{slug: slug}} =
      Webhook.create(
        ctx,
        Map.merge(%{name: name, target_ref: "f:local.handler"}, opts)
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

    test "missing header on a webhook configured for it passes through (no fail-closed)",
         %{ctx: ctx} do
      webhook = create_hook!(ctx, "missing", %{idempotency_key_header: "X-Cyfr-Delivery"})

      conn = build_conn_with_webhook(webhook, [])
      result = WebhookIdempotency.call(conn, [])

      refute result.halted
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
end
