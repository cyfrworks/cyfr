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

  ## Why the claim is released on failure

  The row goes in *before* the controller runs, because that is what makes two
  concurrent deliveries of one key resolve to a single execution. But a claim
  staked ahead of the work is a claim that can outlive work which never
  happened: if the controller then answered 4xx/5xx — target component
  missing, execution refused, an internal error — the row stood, and the
  sender's retry, which is the entire reason it sent an idempotency key, got
  `{"status": "duplicate"}` while the target had never run once.

  So a non-2xx response gives the claim back on the way out, and the retry is
  a fresh delivery. A hard crash still leaves the row, which the TTL sweep
  clears; that is the same exposure as before, now bounded to the case where
  nothing could have run a `before_send` anyway.
  """

  import Plug.Conn

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    webhook = conn.assigns[:webhook]

    cond do
      is_nil(webhook) ->
        conn

      is_binary(webhook.idempotency_key_header) ->
        case fetch_key(conn, webhook.idempotency_key_header) do
          nil ->
            missing_key(conn, webhook.idempotency_key_header)

          key ->
            handle_lookup(conn, webhook.id, key)
        end

      # A timestamp bounds a replay to the skew window; it does not stop
      # one inside it. The sender emits no event id to dedupe on, so the
      # signature is the nonce: it is unique per (timestamp, body) and the
      # sender cannot forge a second one for the same pair without the
      # secret. Hashed rather than stored, because the column is the
      # signature itself otherwise.
      is_binary(webhook.timestamp_header) ->
        case signature_nonce(conn, webhook) do
          nil -> conn
          nonce -> handle_lookup(conn, webhook.id, nonce)
        end

      true ->
        conn
    end
  end

  defp signature_nonce(conn, webhook) do
    header = webhook.signature_header || Sanctum.Webhook.default_signature_header()

    case fetch_key(conn, header) do
      nil -> nil
      signature -> "sig:" <> Cyfr.Digest.sha256(signature)
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
        # The claim is settled by whoever learns the outcome. For a
        # delivery that reaches the task that is the task
        # (`WebhookController.run_in_task/6`); the before_send below
        # covers only the synchronous refusals that never get there.
        |> assign(:webhook_delivery_claim, {webhook_id, key})
        |> release_claim_unless_delivered(webhook_id, key)

      {:duplicate, first_seen_at} ->
        body =
          Jason.encode!(%{
            "status" => "duplicate",
            "first_seen_at" => Cyfr.Time.iso8601(first_seen_at)
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)
        |> halt()

      {:error, _} ->
        # Database error — let the request proceed rather than 500. The
        # target component runs, possibly twice. Failing closed would
        # create a hard outage on temporary DB hiccups. This is a fail-open
        # in the REPLAY control specifically, so it leaves a structured
        # trace an operator can alarm on, not just a warn log.
        :telemetry.execute(
          [:cyfr, :emissary, :webhook, :dedup_unavailable],
          %{count: 1},
          %{webhook_id: webhook_id}
        )

        conn
    end
  end

  # Registered on the fresh path only: a duplicate never staked a claim in
  # this request, and must not release the one the original delivery holds.
  #
  # This can only see SYNCHRONOUS refusals — a 503 when the engine is not
  # up, a 500 from a spawn failure. The controller answers `200 accepted`
  # the moment the task spawns, so a 2xx here means "handed off", never
  # "delivered", and every execution outcome happens afterwards. That is
  # why the task settles the claim itself; without it, a component that
  # raised kept its claim and the sender's retry read as a duplicate for
  # the full TTL.
  defp release_claim_unless_delivered(conn, webhook_id, key) do
    register_before_send(conn, fn sent ->
      if sent.status in 200..299 do
        sent
      else
        case Arca.WebhookDeliveryStorage.release(webhook_id, key) do
          :ok ->
            :ok

          {:error, reason} ->
            # The claim outlives a delivery that did not happen, so the
            # sender's retry will read as a duplicate. Say so where an
            # operator can alarm on it, the way the dedup-unavailable
            # fail-open above does.
            Logger.error(
              "[Webhook] could not release idempotency claim for #{webhook_id}: " <>
                "#{inspect(reason)} — a retry of this delivery will read as a duplicate"
            )

            :telemetry.execute(
              [:cyfr, :emissary, :webhook, :dedup_release_failed],
              %{count: 1},
              %{webhook_id: webhook_id}
            )
        end

        sent
      end
    end)
  end
end
