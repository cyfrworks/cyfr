# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.VerifyWebhookSignature do
  @moduledoc """
  Authenticate inbound webhook POSTs via HMAC-SHA256.

  Pipeline expectation: runs **after** `Plug.Parsers` (so
  `conn.assigns[:raw_body]` has been populated by
  `EmissaryWeb.Plugs.RawBodyReader` when the request path is `/hooks/*`).

  ## Behavior

    * 404 — slug not found OR webhook is disabled. (Same response in both
      cases — no enumeration leakage.)
    * 503 — the webhook store could not answer. Never a 404, which would
      read as "no such hook" to a sender that retries on 5xx only.
    * 401 — signature header missing, malformed, or mismatched.
    * 500 — defensive: raw body wasn't captured (body_reader didn't run) or
      secret decryption failed. Should never happen in practice.

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

  def call(%Plug.Conn{path_params: %{"slug" => slug}} = conn, _opts) when is_binary(slug) do
    conn =
      case lookup_active_webhook(conn, slug) do
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

  def call(conn, _opts) do
    emit_telemetry(nil, nil, :no_slug)
    deny_404(conn)
  end

  # ============================================================================
  # Internal
  # ============================================================================

  # `WebhookRateLimit` runs before us in the pipeline and caches the lookup
  # on `conn.assigns[:webhook_lookup]`. Use that when present to avoid a
  # second indexed query per request. Fall through to a fresh query when the
  # assign is absent — that's the "called directly from a unit test" path
  # (verify_webhook_signature_test.exs builds conns without the rate limiter).
  defp lookup_active_webhook(conn, slug) do
    case conn.assigns[:webhook_lookup] do
      {:ok, %{enabled: true} = webhook} -> {:ok, webhook}
      {:ok, _disabled} -> :not_found
      {:error, :not_found} -> :not_found
      {:error, _} -> :unavailable
      nil -> fresh_lookup(slug)
    end
  end

  defp fresh_lookup(slug) do
    case Sanctum.Webhook.resolve_ingress(slug) do
      {:ok, %{enabled: true} = webhook} -> {:ok, webhook}
      {:ok, _disabled} -> :not_found
      {:error, :not_found} -> :not_found
      {:error, _} -> :unavailable
    end
  end

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

  # Map verification failure reasons to telemetry + HTTP response. Status
  # bucketing is unchanged; the wrapper just adds an observability hook so
  # operators can see *why* a webhook is failing.
  defp deny_with_telemetry(conn, webhook, reason) do
    # The webhook row is in hand here — reading it back off an assign only
    # set on the success path made webhook_id structurally nil on every
    # failure event.
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
      _ -> deny_500(conn)
    end
  end

  # `slug` may be nil (no_slug case). Reason is normalized to an atom so
  # downstream handlers can pattern-match without parsing tuples.
  defp emit_telemetry(slug, webhook_id, reason) do
    reason_atom =
      case reason do
        atom when is_atom(atom) -> atom
        {atom, _} when is_atom(atom) -> atom
        _ -> :unknown
      end

    :telemetry.execute(
      [:cyfr, :emissary, :webhook, :verify_failed],
      %{count: 1},
      %{slug: slug, webhook_id: webhook_id, reason: reason_atom}
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
  # off — return `{:ok, nil}` so `verify_signature/4` skips the timestamp check.
  # When set, the request MUST carry the named header (missing → 401).
  defp fetch_timestamp(_conn, nil), do: {:ok, nil}
  defp fetch_timestamp(_conn, ""), do: {:ok, nil}

  defp fetch_timestamp(conn, header) when is_binary(header) do
    case get_req_header(conn, header) do
      [value | _] when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_timestamp}
    end
  end

  defp deny_404(conn) do
    EmissaryWeb.ApiError.halt(conn, 404, :not_found, nil)
  end

  defp deny_503(conn) do
    conn
    |> put_resp_header("retry-after", "5")
    |> EmissaryWeb.ApiError.halt(503, :unavailable, nil)
  end

  defp deny_401(conn) do
    EmissaryWeb.ApiError.halt(conn, 401, :signature_invalid, nil)
  end

  # The sender used a content type no parser matches, so `RawBodyReader`
  # never ran and there is no raw body to verify a signature over. That is
  # a malformed REQUEST, not a server fault: answering 500 logged an error
  # for every mis-configured sender and told them to retry something that
  # can never succeed.
  defp deny_400(conn) do
    EmissaryWeb.ApiError.halt(
      conn,
      400,
      :unsupported_content_type,
      nil
    )
  end

  defp deny_500(conn) do
    Logger.error("[VerifyWebhookSignature] internal error path=#{conn.request_path}")
    EmissaryWeb.ApiError.halt(conn, 500, :internal_error, nil)
  end
end
