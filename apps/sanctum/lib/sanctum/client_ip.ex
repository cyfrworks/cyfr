# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ClientIp do
  @moduledoc """
  Single source of truth for resolving the client IP of a request,
  applying the X-Forwarded-For trust boundary, and for reading which of
  the endpoint's listeners accepted it (its ingress).

  Two entry points, one decision: `resolve/1` for a `Plug.Conn` and
  `from_connect_info/1` for a LiveView socket. The socket needs its own
  door because the `/live` socket is handled by the endpoint before the
  router (`CyfrWeb.Endpoint`), so it never passes a plug and has no
  conn to hand over — and a synthesised one would be a second place the
  hop rules could drift. Both spellings reduce to the same
  `(ingress, peer, forwarded-header values)` triple.

  ## The ingress

  The endpoint serves two listeners, and the listener that accepted a
  request is the boundary: `:loopback`, the listener this machine's
  loopback reaches, or `:proxy`, the one a tailnet or public home's proxy
  forwards to. Each listener's first plug tags the request
  (`put_ingress/2`): the atom in `conn.private`, read by `ingress/1`, and
  the request header `x-cyfr-ingress`, which a socket's
  `connect_info` carries among its `:x_headers` and `ingress_from_connect_info/1`
  reads. The tag replaces every copy of the header the client sent, so no
  header a client writes chooses it. A request that no listener tagged, or
  a socket whose headers hold anything but exactly one tag, has no ingress
  (`nil`), which is never `:loopback` and never `:proxy`.

  ## The trust boundary

  X-Forwarded-For is honoured ONLY on the proxy listener, and only as
  `config :sanctum, :proxy_trust` says, which `config/runtime.exs` sets
  from the home's access settings (`Cyfr.RuntimeConfig.resolve_access/1`):
  `{:cidrs, entries}` strips the trailing hops inside those IPs and CIDRs,
  `{:hops, count}` strips a fixed count from 0 to 16, and `:none`, a
  local home's, trusts nothing. On the loopback listener, and on a request
  with no ingress, the header is never read: the client is the socket
  peer. Unconditional XFF trust would let any client spoof an API-key IP
  allowlist; ignoring XFF behind a proxy would make every allowlist check
  see the proxy IP. Both failure modes are closed here, once, for every
  caller (the authentication plug, the tincture auth resolver, and the
  tincture rate-limit bucket) so the trust decision cannot drift between
  entry points.

  ## Hop selection

  Proxies APPEND the peer they saw to X-Forwarded-For, so only the RIGHT end
  of the chain is proxy-attested — the leftmost entries are whatever the
  client sent and must never be trusted (a client sending
  `X-Forwarded-For: 1.2.3.4` would otherwise spoof any IP). The client IP is
  therefore selected right-to-left: the socket peer (`conn.remote_ip`) is
  appended as the outermost hop, trusted proxies are stripped from the right,
  and the first remaining hop is the client. A hop count that is not a whole
  number from 0 to 16 is zero hops: the socket peer, never a hop the chain's
  writer chose. A wrong hop count resolves a proxy IP and fails an allowlist
  *closed*, never open.

  `resolve/1` ALWAYS returns a binary — never `nil`. A context with no
  resolvable IP yields `"0.0.0.0"`, which fails a real API-key allowlist
  *closed* (it won't match a configured CIDR). `Sanctum.ApiKey.validate/2`
  also rejects an allowlisted key outright when no `client_ip` is supplied,
  so both halves of the check fail closed.
  """

  import Plug.Conn, only: [get_req_header: 2, put_private: 3]

  @typedoc "The listener that accepted a request."
  @type ingress :: :loopback | :proxy

  # The most proxy hops a deployment may trust, as `config/runtime.exs`
  # reads `CYFR_TRUSTED_PROXY_HOPS`.
  @max_trusted_proxy_hops 16

  # Where a listener's tag is kept: the conn's private map, and the
  # request header a socket's `connect_info` carries.
  @ingress_key :cyfr_ingress
  @ingress_header "x-cyfr-ingress"
  @ingresses %{"loopback" => :loopback, "proxy" => :proxy}

  @doc """
  Tag `conn` as accepted by the listener `ingress`: the atom in its
  private map and the one `x-cyfr-ingress` request header, after every
  copy of the header the client sent, in any case, is deleted. Only a
  listener's first plug calls this (`CyfrWeb.Ingress`).
  """
  @spec put_ingress(Plug.Conn.t(), ingress()) :: Plug.Conn.t()
  def put_ingress(%Plug.Conn{} = conn, ingress) when ingress in [:loopback, :proxy] do
    headers =
      Enum.reject(conn.req_headers, fn {name, _value} ->
        String.downcase(name) == @ingress_header
      end)

    %{conn | req_headers: [{@ingress_header, Atom.to_string(ingress)} | headers]}
    |> put_private(@ingress_key, ingress)
  end

  @doc "The listener that accepted `conn` (`put_ingress/2`), or `nil` when none tagged it."
  @spec ingress(Plug.Conn.t()) :: ingress() | nil
  def ingress(%Plug.Conn{private: %{@ingress_key => ingress}})
      when ingress in [:loopback, :proxy],
      do: ingress

  def ingress(%Plug.Conn{}), do: nil

  @doc """
  The listener that accepted a socket's connection, from its
  `connect_info`'s `:x_headers`: the one `x-cyfr-ingress` header the
  listener set, or `nil` when there is none, more than one, or one that
  names no listener.
  """
  @spec ingress_from_connect_info(map()) :: ingress() | nil
  def ingress_from_connect_info(connect_info) when is_map(connect_info) do
    tags =
      for {name, value} <- List.wrap(Map.get(connect_info, :x_headers)),
          is_binary(name) and String.downcase(name) == @ingress_header,
          do: value

    case tags do
      [tag] -> Map.get(@ingresses, tag)
      _none_or_many -> nil
    end
  end

  def ingress_from_connect_info(_absent), do: nil

  @spec resolve(Plug.Conn.t()) :: String.t()
  def resolve(%Plug.Conn{} = conn) do
    resolve_from(
      ingress(conn),
      remote_ip_string(conn.remote_ip),
      get_req_header(conn, "x-forwarded-for")
    )
  end

  @doc """
  The client IP behind a LiveView socket, from its `connect_info`.

  The endpoint must list `:peer_data` and `:x_headers` in the socket's
  `connect_info` for this to see anything; without them it answers
  `"0.0.0.0"`, the same fail-closed value `resolve/1` gives an
  unresolvable conn, and without the listener's tag among the headers no
  forwarded header is read. Capture it at `mount/3` — `connect_info` is
  only readable there.
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

    resolve_from(ingress_from_connect_info(connect_info), peer, forwarded)
  end

  def from_connect_info(_absent), do: "0.0.0.0"

  defp resolve_from(:proxy, peer, forwarded_values) do
    case extract_forwarded_ip(peer, forwarded_values, proxy_trust()) do
      {:ok, ip} -> ip
      :error -> peer
    end
  end

  defp resolve_from(_loopback_or_none, peer, _forwarded_values), do: peer

  defp proxy_trust, do: Application.get_env(:sanctum, :proxy_trust, :none)

  # Rightmost-untrusted hop of the X-Forwarded-For chain, validated as a
  # real IP literal. The socket peer is appended as the outermost hop so
  # trusted-proxy stripping covers it uniformly; proxies may also split the
  # chain across multiple header instances, so all of them are joined.
  defp extract_forwarded_ip(_peer, _forwarded_values, :none), do: :error

  defp extract_forwarded_ip(peer, forwarded_values, trust) do
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
          case trust do
            {:cidrs, cidrs} when is_list(cidrs) -> strip_trusted(chain, cidrs)
            {:hops, count} -> strip_hops(chain, trusted_proxy_hops(count))
            _malformed -> peer
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
  # caller falls back to the socket IP. count=0 (no proxy hop trusted)
  # yields the socket hop itself, correctly ignoring all client-supplied
  # entries.
  defp strip_hops(chain, count), do: chain |> Enum.drop(-count) |> List.last()

  # Drop trailing hops that match a trusted IP/CIDR entry; the first
  # non-matching hop from the right is the client. If every hop is a trusted
  # proxy, the caller IS a proxy — return the innermost entry, which is the
  # socket peer appended by `extract_forwarded_ip/3` and the only hop in the
  # chain the caller could not have written. The OUTERMOST hop would be the
  # caller's to choose: a caller whose own peer sits inside a trusted range
  # would pick the address every IP allowlist sees.
  defp strip_trusted(chain, cidrs) do
    chain
    |> Enum.reverse()
    |> Enum.drop_while(fn hop -> Enum.any?(cidrs, &Prima.Cidr.match?(hop, &1)) end)
    |> List.first(List.last(chain))
  end

  # Malformed is zero hops, the socket peer: a count this module cannot
  # trust never widens what the chain's writer controls.
  defp trusted_proxy_hops(count)
       when is_integer(count) and count in 0..@max_trusted_proxy_hops//1,
       do: count

  defp trusted_proxy_hops(_malformed), do: 0

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
