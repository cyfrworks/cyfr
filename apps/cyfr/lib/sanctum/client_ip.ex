# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ClientIp do
  @moduledoc """
  Single source of truth for resolving the client IP from a `Plug.Conn`,
  applying the X-Forwarded-For trust boundary.

  X-Forwarded-For is honored ONLY when `config :cyfr,
  :trust_x_forwarded_for` is true (set when the deployment is behind a trusted
  reverse proxy). Unconditional XFF trust would let any client spoof an
  API-key IP allowlist; ignoring XFF behind a proxy would make every allowlist
  check see the proxy IP. Both failure modes are closed here, once, for every
  caller (the authentication plug, the tincture auth resolver, and the tincture
  rate-limit bucket) so the trust decision cannot drift between entry points.

  ## Hop selection

  Proxies APPEND the peer they saw to X-Forwarded-For, so only the RIGHT end
  of the chain is proxy-attested — the leftmost entries are whatever the
  client sent and must never be trusted (a client sending
  `X-Forwarded-For: 1.2.3.4` would otherwise spoof any IP). The client IP is
  therefore selected right-to-left: the socket peer (`conn.remote_ip`) is
  appended as the outermost hop, trusted proxies are stripped from the right,
  and the first remaining hop is the client. Trusted proxies are identified
  either by `config :cyfr, :trusted_proxy_cidrs` (list of IPs/CIDRs — strips
  any number of matching trailing hops) or, when that is unset, by
  `config :cyfr, :trusted_proxy_hops` (fixed count, default 1 — the shipped
  single-Caddy topology). A wrong hop count resolves a proxy IP and fails an
  allowlist *closed*, never open.

  `resolve/1` ALWAYS returns a binary — never `nil`. A context with no
  resolvable IP yields `"0.0.0.0"`, which fails a real API-key allowlist
  *closed* (it won't match a configured CIDR). `Sanctum.ApiKey.validate/2`
  also rejects an allowlisted key outright when no `client_ip` is supplied,
  so both halves of the check fail closed.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @spec resolve(Plug.Conn.t()) :: String.t()
  def resolve(%Plug.Conn{} = conn) do
    if trust_forwarded_header?() do
      case extract_forwarded_ip(conn) do
        {:ok, ip} -> ip
        :error -> extract_remote_ip(conn)
      end
    else
      extract_remote_ip(conn)
    end
  end

  defp trust_forwarded_header? do
    Application.get_env(:cyfr, :trust_x_forwarded_for, false)
  end

  # Rightmost-untrusted hop of the X-Forwarded-For chain, validated as a
  # real IP literal. The socket peer is appended as the outermost hop so
  # trusted-proxy stripping covers it uniformly; proxies may also split the
  # chain across multiple header instances, so all of them are joined.
  defp extract_forwarded_ip(conn) do
    hops =
      conn
      |> get_req_header("x-forwarded-for")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case hops do
      [] ->
        :error

      hops ->
        chain = hops ++ [extract_remote_ip(conn)]

        candidate =
          case trusted_proxy_cidrs() do
            [] -> strip_hops(chain, trusted_proxy_hops())
            cidrs -> strip_trusted(chain, cidrs)
          end

        case candidate do
          ip when is_binary(ip) ->
            if valid_ip_string?(ip), do: {:ok, ip}, else: :error

          _ ->
            :error
        end
    end
  end

  # Drop exactly `count` trailing hops (the trusted proxies); the new last
  # element is the client. Exhausting the chain yields nil → :error → the
  # caller falls back to the socket IP. count=0 (trust on, no proxy) yields
  # the socket hop itself, correctly ignoring all client-supplied entries.
  defp strip_hops(chain, count) when is_integer(count) and count >= 0 do
    chain |> Enum.drop(-count) |> List.last()
  end

  defp strip_hops(chain, _bad_config), do: strip_hops(chain, 1)

  # Drop trailing hops that match a trusted IP/CIDR entry; the first
  # non-matching hop from the right is the client. If every hop is a trusted
  # proxy, the caller IS a proxy — return the innermost entry.
  defp strip_trusted(chain, cidrs) do
    chain
    |> Enum.reverse()
    |> Enum.drop_while(fn hop -> Enum.any?(cidrs, &Sanctum.Cidr.match?(hop, &1)) end)
    |> List.first(List.first(chain))
  end

  defp trusted_proxy_hops do
    Application.get_env(:cyfr, :trusted_proxy_hops, 1)
  end

  defp trusted_proxy_cidrs do
    Application.get_env(:cyfr, :trusted_proxy_cidrs, [])
  end

  # conn.remote_ip tuple → string; "0.0.0.0" (fail-closed) on anything else.
  defp extract_remote_ip(conn) do
    case conn.remote_ip do
      ip when is_tuple(ip) ->
        case :inet.ntoa(ip) do
          charlist when is_list(charlist) -> to_string(charlist)
          _ -> "0.0.0.0"
        end

      _ ->
        "0.0.0.0"
    end
  end

  defp valid_ip_string?(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
