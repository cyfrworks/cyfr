# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.WebhookIdempotency do
  @moduledoc """
  Idempotency dedup for inbound webhooks.

  Runs **after** `EmissaryWeb.Plugs.VerifyWebhookSignature` so we only burn
  dedup rows on requests that proved their signature. Lookup is keyed on
  `(webhook_id, idempotency_key)` where the key is read from the per-webhook
  configurable header (e.g. GitHub's `X-GitHub-Delivery`, Stripe's event id).

  ## Behavior

    * If the webhook row has no `idempotency_key_header` set → noop, request
      proceeds to the controller.
    * If the header is configured but absent on the request → **400**.
      Configuring the header is the operator's statement that every real
      delivery carries it — a request without it is either a sender
      misconfiguration or a replayer who stripped the header to skate past
      dedup, and letting it through would make the dedup opt-out per
      request, attacker's choice.
    * On a fresh `(webhook_id, key)` insert → request proceeds, controller
      runs the target component.
    * On a duplicate hit → 200 with `{"status": "duplicate", "first_seen_at": "..."}`,
      controller is bypassed entirely (no double-execution of the target).

  ## Why 200 on duplicate

  We *succeeded* — the original delivery already ran. Returning 4xx/5xx on
  duplicate would prompt the sender to keep retrying, defeating the purpose.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    webhook = conn.assigns[:webhook]

    cond do
      is_nil(webhook) ->
        conn

      is_nil(webhook.idempotency_key_header) ->
        conn

      true ->
        case fetch_key(conn, webhook.idempotency_key_header) do
          nil ->
            missing_key(conn, webhook.idempotency_key_header)

          key ->
            handle_lookup(conn, webhook.id, key)
        end
    end
  end

  defp missing_key(conn, header) do
    conn
    |> EmissaryWeb.ApiError.send(
      400,
      :missing_idempotency_key,
      "this webhook requires the '#{header}' header on every delivery"
    )
    |> halt()
  end

  defp fetch_key(conn, header) do
    case get_req_header(conn, header) do
      [value | _] when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp handle_lookup(conn, webhook_id, key) do
    case Arca.WebhookDeliveryStorage.record(webhook_id, key) do
      :fresh ->
        conn

      {:duplicate, first_seen_at} ->
        body =
          Jason.encode!(%{
            "status" => "duplicate",
            "first_seen_at" => format_datetime(first_seen_at)
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)
        |> halt()

      {:error, _} ->
        # Database error — let the request proceed rather than 500. The
        # target component runs, possibly twice. Operators see the warn log
        # from WebhookDeliveryStorage and can investigate. Failing closed
        # would create a hard outage on temporary DB hiccups.
        conn
    end
  end

  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(value) when is_binary(value), do: value
  defp format_datetime(_), do: nil
end
