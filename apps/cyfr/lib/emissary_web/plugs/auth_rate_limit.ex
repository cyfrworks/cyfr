defmodule EmissaryWeb.Plugs.AuthRateLimit do
  @moduledoc """
  In-process rate limiting for pre-session auth routes.

  Used on endpoints that don't yet have a resolved session — username
  enumeration / OAuth kickoff — keyed by client IP. Configured per call
  site via `init/1` opts:

      plug EmissaryWeb.Plugs.AuthRateLimit,
        bucket: :claim_submit,
        max_requests: 10,
        window_ms: 60_000

  Counters live in `Arca.Cache` (ETS) so the plug is single-node only; the
  off-by-one on concurrent boundary requests is acceptable for rate limits
  (not a security boundary). For multi-node deployments the counter needs
  a shared store, out of scope here.

  Returns 429 with `retry-after` on breach. Adopts the tincture-side
  `PrismWeb.Plugs.PublicRateLimit` pattern; kept separate because the key
  topology (IP-only vs. IP+publisher+tincture) differs.
  """

  import Plug.Conn

  def init(opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    max_requests = Keyword.fetch!(opts, :max_requests)
    window_ms = Keyword.fetch!(opts, :window_ms)

    %{bucket: bucket, max_requests: max_requests, window_ms: window_ms}
  end

  def call(conn, %{bucket: bucket, max_requests: max_requests, window_ms: window_ms}) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    key = {:rate_limit, bucket, ip}
    now = System.monotonic_time(:millisecond)

    case Arca.Cache.get(key) do
      {:ok, {count, window_start}} when now - window_start < window_ms ->
        if count >= max_requests do
          remaining_ms = window_ms - (now - window_start)
          retry_after = max(div(remaining_ms, 1000), 1)

          conn
          |> put_resp_header("retry-after", to_string(retry_after))
          |> send_resp(429, "Rate limit exceeded. Try again in #{retry_after} seconds.")
          |> halt()
        else
          Arca.Cache.put(key, {count + 1, window_start}, window_ms)
          conn
        end

      _ ->
        Arca.Cache.put(key, {1, now}, window_ms)
        conn
    end
  end
end
