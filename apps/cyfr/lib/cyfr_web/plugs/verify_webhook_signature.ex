# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.VerifyWebhookSignature do
  @moduledoc """
  Authenticate inbound webhook POSTs via HMAC-SHA256.

  Pipeline expectation: runs **after** `Plug.Parsers` (so
  `conn.assigns[:raw_body]` has been populated by
  `CyfrWeb.Plugs.RawBodyReader` when the request path is `/hooks/*`) and
  after `CyfrWeb.Plugs.WebhookRateLimit`, whose lookup of the route's
  slug (`conn.assigns[:webhook_lookup]`) it judges the request against.

  ## Behavior

    * 404 — slug not found OR webhook is disabled. (Same response in both
      cases — no enumeration leakage.)
    * 503 — the webhook store, or the skew window a timestamped delivery
      is checked against, could not answer. Never a 404, which would read
      as "no such hook" to a sender that retries on 5xx only.
    * 401 — signature or timestamp header missing, malformed, or
      mismatched, or a timestamp outside the skew window.
    * 400 — no raw body was captured: the sender used a content type no
      parser reads, so there is nothing to verify a signature over.
    * 500 — the stored signing secret could not be opened.

  On success:
    * Assigns the webhook row (`Sanctum.Webhook.resolve_ingress/1`'s, with
      the function that opens its signing secrets removed) to
      `conn.assigns[:webhook]` for the controller to consume.
    * Halts on any failure path; never falls through to the controller.

  Whatever the outcome, the connection leaves this plug carrying no way to
  open a signing secret: the lookup `WebhookRateLimit` cached is dropped
  too. The secrets are opened here, by verification, and nowhere before.

  All response bodies are generic — secret material and structural error
  detail never leak.
  """

  import Plug.Conn
  require Logger

  alias Sanctum.Webhook

  def init(opts), do: opts

  def call(%Plug.Conn{path_params: %{"slug" => slug}} = conn, _opts) do
    conn =
      case active_webhook(conn.assigns.webhook_lookup) do
        {:ok, webhook} ->
          verify(conn, webhook)

        :not_found ->
          emit_telemetry(slug, nil, :not_found_or_disabled)
          deny_404(conn)

        :unavailable ->
          emit_telemetry(slug, nil, :store_unavailable)
          deny_503(conn)
      end

    drop_lookup(conn)
  end

  # ============================================================================
  # Internal
  # ============================================================================

  # The lookup `WebhookRateLimit` made of the slug before this plug runs
  # (`Sanctum.Webhook.resolve_ingress/1`'s answer), judged once.
  defp active_webhook({:ok, %{enabled: true} = webhook}), do: {:ok, webhook}
  defp active_webhook({:ok, _disabled}), do: :not_found
  defp active_webhook({:error, :not_found}), do: :not_found
  defp active_webhook({:error, :unavailable}), do: :unavailable

  defp verify(conn, webhook) do
    with {:ok, raw_body} <- fetch_raw_body(conn),
         {:ok, received} <- fetch_signature_header(conn, webhook.signature_header),
         {:ok, timestamp} <- fetch_timestamp(conn, webhook.timestamp_header),
         :ok <- Webhook.verify_with_grace(webhook, raw_body, received, timestamp) do
      :telemetry.execute(
        [:cyfr, :emissary, :webhook, :verify_succeeded],
        %{count: 1},
        %{slug: webhook.slug, webhook_id: webhook.id}
      )

      conn
      |> assign(:webhook, Map.delete(webhook, :signing_secrets))
      |> assign(:raw_body, raw_body)
    else
      {:error, reason} -> deny_with_telemetry(conn, webhook, reason)
    end
  end

  # The cached lookup carries the function that opens the signing secrets;
  # nothing after verification needs it.
  defp drop_lookup(conn), do: %{conn | assigns: Map.delete(conn.assigns, :webhook_lookup)}

  # A verification failure is counted under its reason, with the webhook
  # it was judged against, so an operator sees why a webhook is failing,
  # and answered by its status.
  defp deny_with_telemetry(conn, webhook, reason) do
    emit_telemetry(webhook.slug, webhook.id, reason)

    case reason do
      :missing_raw_body -> deny_400(conn)
      :missing_signature -> deny_401(conn)
      :missing_timestamp -> deny_401(conn)
      :malformed_signature -> deny_401(conn)
      :malformed_timestamp -> deny_401(conn)
      :timestamp_skew -> deny_401(conn)
      :signature_mismatch -> deny_401(conn)
      # The server cannot read its own secret — a keyring rotated without
      # re-sealing, or a restored backup. Not the sender's fault and not
      # fixable by them, so it must not read as a signature failure.
      :secret_unreadable -> deny_500(conn)
      # The skew window could not be read: refused, and retried by the
      # sender like any outage.
      :unavailable -> deny_503(conn)
    end
  end

  # `webhook_id` is nil where no active webhook holds the slug. The reason
  # is one atom of a closed set: the lookup's two outcomes and the
  # verification's reasons above.
  defp emit_telemetry(slug, webhook_id, reason) do
    :telemetry.execute(
      [:cyfr, :emissary, :webhook, :verify_failed],
      %{count: 1},
      %{slug: slug, webhook_id: webhook_id, reason: reason}
    )
  end

  defp fetch_raw_body(%Plug.Conn{assigns: %{raw_body: body}}) when is_binary(body),
    do: {:ok, body}

  defp fetch_raw_body(_conn), do: {:error, :missing_raw_body}

  defp fetch_signature_header(conn, header) do
    case get_req_header(conn, header) do
      [value | _] when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_signature}
    end
  end

  # When `timestamp_header` is unset on the webhook row, replay protection is
  # off — return `{:ok, nil}` so `Sanctum.Webhook.verify_with_grace/4` skips
  # the timestamp check. When set, the request MUST carry the named header
  # (missing → 401).
  defp fetch_timestamp(_conn, nil), do: {:ok, nil}

  defp fetch_timestamp(conn, header) when is_binary(header) do
    case get_req_header(conn, header) do
      [value | _] when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_timestamp}
    end
  end

  defp deny_404(conn) do
    CyfrWeb.ApiError.halt(conn, 404, :not_found, nil)
  end

  defp deny_503(conn) do
    conn
    |> put_resp_header("retry-after", "5")
    |> CyfrWeb.ApiError.halt(503, :unavailable, nil)
  end

  defp deny_401(conn) do
    CyfrWeb.ApiError.halt(conn, 401, :signature_invalid, nil)
  end

  # The sender used a content type no parser matches, so `RawBodyReader`
  # never ran and there is no raw body to verify a signature over. That is
  # a malformed request, not a server fault, and a retry of it can never
  # succeed.
  defp deny_400(conn) do
    CyfrWeb.ApiError.halt(
      conn,
      400,
      :unsupported_content_type,
      nil
    )
  end

  defp deny_500(conn) do
    Logger.error("[VerifyWebhookSignature] internal error path=#{conn.request_path}")
    CyfrWeb.ApiError.halt(conn, 500, :internal_error, nil)
  end
end
