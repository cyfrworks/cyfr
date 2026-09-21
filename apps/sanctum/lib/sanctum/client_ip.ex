# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ClientIp do
  @moduledoc """
  Single source of truth for resolving the client IP of a request,
  applying the X-Forwarded-For trust boundary.

  Two entry points, one decision: `resolve/1` for a `Plug.Conn` and
  `from_connect_info/1` for a LiveView socket. The socket needs its own
  door because the `/live` socket is handled by the endpoint before the
  router (`EmissaryWeb.Endpoint`), so it never passes a plug and has no
  conn to hand over — and a synthesised one would be a second place the
  hop rules could drift. Both spellings reduce to the same
  `(peer, forwarded-header values)` pair.

  X-Forwarded-For is honored ONLY when `config :sanctum,
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
  either by `config :sanctum, :trusted_proxy_cidrs` (list of IPs/CIDRs — strips
  any number of matching trailing hops) or, when that is unset, by
  `config :sanctum, :trusted_proxy_hops` (fixed count, default 1 — the shipped
  single-Caddy topology). A wrong hop count resolves a proxy IP and fails an
  allowlist *closed*, never open.

  `resolve/1` ALWAYS returns a binary — never `nil`. A context with no
  resolvable IP yields `"0.0.0.0"`, which fails a real API-key allowlist
  *closed* (it won't match a configured CIDR). `Sanctum.ApiKey.validate/2`
  also rejects an allowlisted key outright when no `client_ip` is supplied,
  so both halves of the check fail closed.
  """

  import Plug.Conn, only: [get_req_header: 2]

  # The shipped single-Caddy topology. Spelled once: the config default and
  # the fallback a malformed `:trusted_proxy_hops` lands on are the same
  # decision, and a deployment that changes one must change both.
  @default_trusted_proxy_hops 1

  @spec resolve(Plug.Conn.t()) :: String.t()
  def resolve(%Plug.Conn{} = conn) do
    resolve_from(remote_ip_string(conn.remote_ip), get_req_header(conn, "x-forwarded-for"))
  end

  @doc """
  The client IP behind a LiveView socket, from its `connect_info`.

  The endpoint must list `:peer_data` and `:x_headers` in the socket's
  `connect_info` for this to see anything; without them it answers
  `"0.0.0.0"`, the same fail-closed value `resolve/1` gives an
  unresolvable conn. Capture it at `mount/3` — `connect_info` is only
  readable there.
  """
  @spec from_connect_info(map()) :: String.t()
  def from_connect_info(connect_info) when is_map(connect_info) do
    peer =
      case connect_info do
        %{peer_data: %{address: address}} -> remote_ip_string(address)
        _ -> "0.0.0.0"
      end

    # `List.wrap/1` so a socket that was never given `:x_headers` — or the
    # static mount, where `connect_info` is not readable at all — degrades
    # to "no forwarded header" rather than raising.
    forwarded =
      connect_info
      |> Map.get(:x_headers)
      |> List.wrap()
      |> Enum.filter(fn {name, _value} -> String.downcase(name) == "x-forwarded-for" end)
      |> Enum.map(fn {_name, value} -> value end)

    resolve_from(peer, forwarded)
  end

  def from_connect_info(_absent), do: "0.0.0.0"

  defp resolve_from(peer, forwarded_values) do
    if trust_forwarded_header?() do
      case extract_forwarded_ip(peer, forwarded_values) do
        {:ok, ip} -> ip
        :error -> peer
      end
    else
      peer
    end
  end

  defp trust_forwarded_header? do
    Application.get_env(:sanctum, :trust_x_forwarded_for, false)
  end

  # Rightmost-untrusted hop of the X-Forwarded-For chain, validated as a
  # real IP literal. The socket peer is appended as the outermost hop so
  # trusted-proxy stripping covers it uniformly; proxies may also split the
  # chain across multiple header instances, so all of them are joined.
  defp extract_forwarded_ip(peer, forwarded_values) do
    hops =
      forwarded_values
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case hops do
      [] ->
        :error

      hops ->
        chain = hops ++ [peer]

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

  defp strip_hops(chain, _bad_config), do: strip_hops(chain, @default_trusted_proxy_hops)

  # Drop trailing hops that match a trusted IP/CIDR entry; the first
  # non-matching hop from the right is the client. If every hop is a trusted
  # proxy, the caller IS a proxy — return the innermost entry, which is the
  # socket peer appended by `extract_forwarded_ip/1` and the only hop in the
  # chain the caller could not have written. `List.first(chain)` named the
  # OUTERMOST hop instead: a caller whose own peer sits inside a trusted
  # range could then choose the address every IP allowlist would see.
  defp strip_trusted(chain, cidrs) do
    chain
    |> Enum.reverse()
    |> Enum.drop_while(fn hop -> Enum.any?(cidrs, &Cyfr.Cidr.match?(hop, &1)) end)
    |> List.first(List.last(chain))
  end

  defp trusted_proxy_hops do
    Application.get_env(:sanctum, :trusted_proxy_hops, @default_trusted_proxy_hops)
  end

  defp trusted_proxy_cidrs do
    Application.get_env(:sanctum, :trusted_proxy_cidrs, [])
  end

  # An address tuple → string; "0.0.0.0" (fail-closed) on anything else.
  # Shared by the conn peer (`conn.remote_ip`) and the socket peer
  # (`connect_info.peer_data.address`), which are the same shape.
  defp remote_ip_string(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      charlist when is_list(charlist) -> to_string(charlist)
      _ -> "0.0.0.0"
    end
  end

  defp remote_ip_string(_not_an_address), do: "0.0.0.0"

  defp valid_ip_string?(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
