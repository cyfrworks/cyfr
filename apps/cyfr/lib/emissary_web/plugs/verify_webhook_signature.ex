defmodule EmissaryWeb.Plugs.VerifyWebhookSignature do
  @moduledoc """
  Authenticate inbound webhook POSTs via HMAC-SHA256.

  Pipeline expectation: runs **after** `Plug.Parsers` (so
  `conn.assigns[:raw_body]` has been populated by
  `EmissaryWeb.Plugs.RawBodyReader` when the request path is `/hooks/*`).

  ## Behavior

    * 404 — slug not found OR webhook is disabled. (Same response in both
      cases — no enumeration leakage.)
    * 401 — signature header missing, malformed, or mismatched.
    * 500 — defensive: raw body wasn't captured (body_reader didn't run) or
      secret decryption failed. Should never happen in practice.

  On success:
    * Assigns the webhook row (struct of fields from `Arca.WebhookStorage`)
      to `conn.assigns[:webhook]` for the controller to consume.
    * Halts on any failure path; never falls through to the controller.

  All response bodies are generic — secret material and structural error
  detail never leak.
  """

  import Plug.Conn
  require Logger

  alias Sanctum.Webhook

  def init(opts), do: opts

  def call(%Plug.Conn{path_params: %{"slug" => slug}} = conn, _opts) when is_binary(slug) do
    case lookup_active_webhook(conn, slug) do
      {:ok, webhook} ->
        verify(conn, webhook)

      :not_found ->
        emit_telemetry(slug, nil, :not_found_or_disabled)
        deny_404(conn)
    end
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
      {:error, _} -> :not_found
      nil -> fresh_lookup(slug)
    end
  end

  defp fresh_lookup(slug) do
    case Arca.WebhookStorage.get_by_slug(slug) do
      {:ok, %{enabled: true} = webhook} -> {:ok, webhook}
      {:ok, _disabled} -> :not_found
      {:error, :not_found} -> :not_found
      {:error, _} -> :not_found
    end
  end

  defp verify(conn, webhook) do
    with {:ok, raw_body} <- fetch_raw_body(conn),
         {:ok, received} <- fetch_signature_header(conn, webhook.signature_header),
         {:ok, timestamp} <- fetch_timestamp(conn, webhook.timestamp_header),
         :ok <- Webhook.verify_signature(webhook.secret_encrypted, raw_body, received, timestamp) do
      :telemetry.execute(
        [:cyfr, :emissary, :webhook, :verify_succeeded],
        %{count: 1},
        %{slug: webhook.slug, webhook_id: webhook.id}
      )

      conn
      |> assign(:webhook, webhook)
      |> assign(:raw_body, raw_body)
    else
      {:error, reason} -> deny_with_telemetry(conn, webhook.slug, reason)
    end
  end

  # Map verification failure reasons to telemetry + HTTP response. Status
  # bucketing is unchanged; the wrapper just adds an observability hook so
  # operators can see *why* a webhook is failing.
  defp deny_with_telemetry(conn, slug, reason) do
    emit_telemetry(slug, conn.assigns[:webhook] && conn.assigns[:webhook].id, reason)

    case reason do
      :missing_raw_body -> deny_500(conn)
      :missing_signature -> deny_401(conn)
      :missing_timestamp -> deny_401(conn)
      :malformed_signature -> deny_401(conn)
      :malformed_timestamp -> deny_401(conn)
      :timestamp_skew -> deny_401(conn)
      :signature_mismatch -> deny_401(conn)
      {:decryption_failed, _} -> deny_500(conn)
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
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, ~s({"error":"not_found"}))
    |> halt()
  end

  defp deny_401(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"unauthorized"}))
    |> halt()
  end

  defp deny_500(conn) do
    Logger.error("[VerifyWebhookSignature] internal error path=#{conn.request_path}")

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(500, ~s({"error":"internal_error"}))
    |> halt()
  end
end
