# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.WebhookRateLimit do
  @moduledoc """
  Per-slug rate limiter for inbound webhook POSTs.

  Buckets:

    * **Known, enabled slug** → keyed on `{:slug, slug}`. Default `100/1m`,
      override via the `rate_limit` column on the `webhooks` row.
    * **Unknown OR disabled slug** → keyed on `{:ip_unknown, ip}` with a
      smaller cap (`10/1m`). This defends against slug-enumeration scans
      without giving every random slug attempt a fresh per-slug bucket.
    * **Every request, whatever the slug** → also keyed on `{:ip, ip}` at
      a much higher ceiling (`6_000/1m`, `:webhook_per_ip_rate_limit_max`).
      One address cannot mint unbounded per-slug buckets, and bulk probing
      is throttled the same whether the slugs it tries are real or not.
      Configurable because it is checked FIRST and so clamps every
      per-slug limit beneath it.

  ## What the buckets do NOT hide

  A valid slug with a bad signature answers 401; an unknown or disabled
  one answers 404 (`VerifyWebhookSignature`, deliberately — that plug's
  moduledoc scopes its "no enumeration leakage" claim to not-found vs
  disabled, not to valid vs invalid). So the two ARE distinguishable, from
  the first request, and the bucket split above is a second signal that
  appears after ten.

  That is accepted rather than overlooked. Slugs are 144 bits of CSPRNG
  (`Sanctum.Webhook`), so the distinction confirms a slug someone already
  holds and cannot help them find one; closing it would mean either
  charging legitimate deliveries to the 10/min scan bucket or making a
  real 404 indistinguishable from a signature failure, and both cost more
  than the leak. The uniform per-IP ceiling is the part worth having: it
  bounds the damage of bulk probing and the ETS key cardinality one
  address can create.

  We perform the slug lookup here (and not just in
  `EmissaryWeb.Plugs.VerifyWebhookSignature`) because rate-limiting must
  run *before* signature verification — otherwise an attacker can spam
  unverified requests indefinitely. The lookup is a single indexed query
  against `webhooks.slug` (UNIQUE).

  Counters live in `Cyfr.RateLimiter` (ETS) — single-node only; same caveats as
  `EmissaryWeb.Plugs.AuthRateLimit`.
  """

  import Plug.Conn
  require Logger

  @default_max 100
  @default_window_ms 60_000

  @unknown_max 10
  @unknown_window_ms 60_000

  # Applies to every request regardless of slug validity — a circuit
  # breaker for bulk probing rather than a delivery throttle.
  #
  # It is a KNOB, because it is checked before the per-slug bucket and
  # therefore clamps it. An operator who sets `rate_limit: "1000/1m"` on a
  # webhooks row — which `Sanctum.Webhook` accepts with no upper bound —
  # was silently held to this number for any single sender, and one
  # provider egressing from one stable address is the ordinary case, not
  # an attack. Raise it when a real sender needs more; it only has to stay
  # above the per-slug limits actually configured.
  @default_per_ip_max 6_000
  @per_ip_window_ms 60_000

  defp per_ip_max do
    Application.get_env(:cyfr, :webhook_per_ip_rate_limit_max, @default_per_ip_max)
  end

  def init(_opts), do: %{}

  def call(conn, _opts) do
    {conn, bucket_id, max_requests, window_ms} = bucket_for(conn)

    checks = [
      {{:rate_limit, :webhook, {:ip, ip(conn)}}, per_ip_max(), @per_ip_window_ms},
      {{:rate_limit, :webhook, bucket_id}, max_requests, window_ms}
    ]

    case Enum.find_value(checks, fn {key, max, window} ->
           case Cyfr.RateLimiter.check(key, max, window) do
             :ok -> nil
             {:deny, retry_after} -> retry_after
           end
         end) do
      nil ->
        conn

      retry_after ->
        EmissaryWeb.RateLimitRefusal.halt(conn, retry_after, EmissaryWeb.ApiError)
    end
  end

  # Resolve the rate-limit bucket and limits for this request.
  #
  # Slug lookup happens here so the limiter applies *before* signature
  # verification. Unknown or disabled slugs share an IP-keyed scan bucket so
  # an attacker cannot get a fresh `100/1m` allowance per fabricated slug.
  #
  # We cache the lookup result on `conn.assigns[:webhook_lookup]` so the
  # `VerifyWebhookSignature` plug can reuse it without a second indexed query.
  # On the happy path that takes inbound webhook deliveries from 2 DB queries
  # to 1.
  #
  # Database errors fall through to the *default* slug-keyed bucket (not the
  # tighter scan-evasion one): during a DB outage we don't know whether the
  # slug is legitimate, and rate-limiting legitimate traffic to 10/min would
  # cascade the outage into rejected webhooks. The verify-signature plug will
  # 500 on its own DB error — losing audit-correctness, not security.
  defp bucket_for(%Plug.Conn{path_params: %{"slug" => slug}} = conn)
       when is_binary(slug) and slug != "" do
    lookup = Arca.WebhookStorage.get_by_slug(slug)
    conn = assign(conn, :webhook_lookup, lookup)

    case lookup do
      {:ok, %{enabled: true, rate_limit: rl}} when is_binary(rl) and rl != "" ->
        {max, window} = parse_rate_limit(rl)
        {conn, {:slug, slug}, max, window}

      {:ok, %{enabled: true}} ->
        {conn, {:slug, slug}, @default_max, @default_window_ms}

      {:ok, %{enabled: false}} ->
        # Disabled slug: scan-evasion bucket keyed by IP.
        {conn, {:ip_unknown, ip(conn)}, @unknown_max, @unknown_window_ms}

      {:error, :not_found} ->
        # Unknown slug: scan-evasion bucket keyed by IP.
        {conn, {:ip_unknown, ip(conn)}, @unknown_max, @unknown_window_ms}

      {:error, reason} ->
        require Logger

        Logger.warning(
          "[WebhookRateLimit] storage lookup failed slug=#{slug} reason=#{inspect(reason)} — falling back to default per-slug limit"
        )

        {conn, {:slug, slug}, @default_max, @default_window_ms}
    end
  end

  defp bucket_for(conn), do: {conn, {:ip_unknown, ip(conn)}, @unknown_max, @unknown_window_ms}

  # Through the X-Forwarded-For trust boundary like every other limiter:
  # behind the shipped Caddy proxy, `conn.remote_ip` is the proxy, which
  # collapsed the whole internet's scan traffic into one 10/1m bucket.
  defp ip(conn), do: Sanctum.ClientIp.resolve(conn)

  # Parse "<count>/<window>" — e.g. "100/1m", "1000/1h", "60/30s".
  # Falls back to defaults on any parse failure — and SAYS SO. A typo'd
  # `rate_limit` on a webhooks row is an operator who believes they set a
  # budget and did not; silently serving them the default is how they find
  # out from a 429 instead of from the log.
  defp parse_rate_limit(spec) do
    with [count_str, window_str] <- String.split(spec, "/", parts: 2),
         {count, ""} when count > 0 <- Integer.parse(count_str),
         {:ok, window_ms} <- parse_window(window_str) do
      {count, window_ms}
    else
      _ ->
        Logger.warning(
          "[WebhookRateLimit] unparseable rate_limit #{inspect(spec)} — " <>
            "falling back to #{@default_max}/#{@default_window_ms}ms"
        )

        {@default_max, @default_window_ms}
    end
  end

  # One duration grammar for every enforcement window (Sanctum.Limits) —
  # this also gains ms support the local parser lacked.
  defp parse_window(spec) do
    case Sanctum.Limits.parse_duration(spec) do
      {:ok, ms} when ms > 0 -> {:ok, ms}
      _ -> :error
    end
  end
end
