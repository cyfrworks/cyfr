defmodule PrismWeb.Plugs.PublicRateLimit do
  @moduledoc """
  Rate limiting for public tincture endpoints.

  60 requests per minute per (IP, publisher, tincture_name) tuple.
  Uses Arca.Cache ETS for counters. Returns 429 with Retry-After header.
  """

  import Plug.Conn

  @max_requests 60
  @window_ms 60_000

  def init(opts), do: opts

  def call(conn, _opts) do
    # Note: conn.remote_ip is the direct TCP peer. Behind a reverse proxy,
    # configure Endpoint's :remote_ip or use RemoteIp to extract the real client IP.
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    {publisher, tincture_name} =
      case {conn.path_params["publisher"], conn.path_params["tincture_name"]} do
        {pub, name} when is_binary(pub) and is_binary(name) -> {pub, name}
        _ ->
          case conn.path_info do
            ["t", pub, name | _] -> {pub, name}
            _ -> {"unknown", "unknown"}
          end
      end

    key = {:rate_limit, ip, publisher, tincture_name}

    now = System.monotonic_time(:millisecond)

    # Note: non-atomic read-check-write — two concurrent requests at the limit
    # boundary could both pass. Acceptable for rate limiting (off-by-one, not a
    # security issue). Use :ets.update_counter/3 if precise counting is ever needed.
    case Arca.Cache.get(key) do
      {:ok, {count, window_start}} when now - window_start < @window_ms ->
        if count >= @max_requests do
          remaining_ms = @window_ms - (now - window_start)
          retry_after = max(div(remaining_ms, 1000), 1)

          conn
          |> put_resp_header("retry-after", to_string(retry_after))
          |> send_resp(429, "Rate limit exceeded. Try again in #{retry_after} seconds.")
          |> halt()
        else
          Arca.Cache.put(key, {count + 1, window_start}, @window_ms)
          conn
        end

      _ ->
        # New window
        Arca.Cache.put(key, {1, now}, @window_ms)
        conn
    end
  end
end
