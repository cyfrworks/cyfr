# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Network do
  @moduledoc """
  Network security utilities for SSRF prevention.

  Validates outbound URLs before connecting, blocking requests to
  private/reserved IP ranges. Used by OCI blob operations and external MCP
  servers to prevent malicious registries/servers from reaching internal
  services or cloud metadata endpoints.

  ## DNS-rebinding protection

  `validate_redirect_url/2` only *checks* a URL — a caller that then connects
  by hostname re-resolves DNS and reopens a time-of-check/time-of-use gap (an
  attacker-controlled domain can answer a public IP for the check and a private
  IP for the connection). `pinned_request/5` closes that gap: it resolves and
  validates the host ONCE, then connects to that exact IP while preserving the
  original hostname for the TLS SNI, certificate verification, and `Host`
  header (via Mint's `:hostname` connect option). The validated IP is the
  connection target, so there is no second resolution to rebind.
  """

  import Bitwise
  import Arca.QueryHelpers, only: [maybe_put: 3]

  # Private/reserved IPv4 ranges (CIDR notation as {base, mask} tuples)
  @private_ranges [
    # 127.0.0.0/8 - loopback
    {bsl(127, 24), 0xFF000000},
    # 10.0.0.0/8 - private class A
    {bsl(10, 24), 0xFF000000},
    # 172.16.0.0/12 - private class B
    {bsl(172, 24) + bsl(16, 16), 0xFFF00000},
    # 192.168.0.0/16 - private class C
    {bsl(192, 24) + bsl(168, 16), 0xFFFF0000},
    # 169.254.0.0/16 - link-local / cloud metadata
    {bsl(169, 24) + bsl(254, 16), 0xFFFF0000},
    # 0.0.0.0/8 - current network
    {0, 0xFF000000},
    # 100.64.0.0/10 - CGNAT (RFC 6598); internal service ranges on several
    # clouds and overlay networks
    {bsl(100, 24) + bsl(64, 16), 0xFFC00000},
    # 192.0.0.0/24 - IETF protocol assignments (RFC 6890)
    {bsl(192, 24), 0xFFFFFF00},
    # 198.18.0.0/15 - benchmarking (RFC 2544)
    {bsl(198, 24) + bsl(18, 16), 0xFFFE0000},
    # 224.0.0.0/4 - multicast
    {bsl(224, 24), 0xF0000000},
    # 240.0.0.0/4 - reserved, includes 255.255.255.255 broadcast
    {bsl(240, 24), 0xF0000000}
  ]

  @doc """
  Validate a redirect URL is safe to follow.

  Checks scheme (http/https only), hostname presence, and DNS resolution
  to a non-private IP address.

  ## Options

    * `:allow_private` - when `true`, permits private IPs except
      169.254.0.0/16 (link-local/cloud metadata) which is always blocked.
      `:policy` permits a private IP only when the host or the IP is on the
      operator's private-egress allowlist (`CYFR_PRIVATE_EGRESS_TARGETS`,
      `private_allowed?/2`) — the posture every deployment shares once it has
      a door: a compose-network mcp-bridge or the lights in Home are named,
      not implied by "single user".

  Returns `:ok` or `{:error, reason_string}`.
  """
  @spec validate_redirect_url(String.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_redirect_url(url, opts \\ []) do
    case resolve_and_validate(url, opts) do
      {:ok, _ip_tuple, _uri} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resolve a URL's host, validate the IP, and return both the validated IP
  tuple and the parsed URI so the caller can pin the connection to that IP.

  Single source of truth for the scheme/host/IP checks. Same `:allow_private`
  semantics as `validate_redirect_url/2`.
  """
  @spec resolve_and_validate(String.t(), keyword()) ::
          {:ok, :inet.ip_address(), URI.t()} | {:error, String.t()}
  def resolve_and_validate(url, opts \\ []) do
    case pin(url, translate_legacy_opts(opts)) do
      {:ok, %{ip_tuple: ip_tuple, uri: uri}} -> {:ok, ip_tuple, uri}
      {:error, _type, message} -> {:error, message}
    end
  end

  @doc """
  Resolve, validate and PIN a URL for an outbound request — the ONE
  implementation of the resolve→validate→pin sequence, for both outbound
  planes: the host's own calls (OCI, cyfr.run, external MCP) and the WASM
  guest's `cyfr:http` handlers, which pass their consent policy as a
  function. The two planes used to carry separate copies of the DNS
  ladder and the pinned-URL/Req-option construction — and the guest copy
  silently inherited Req's auto-retry and auto-decode defaults.

  Returns `{:ok, %{ip: String.t(), ip_tuple: tuple, uri: URI.t(),
  req_opts: keyword()}}` — `req_opts` carries the pinned URL and the full
  fail-closed transport policy (`redirect/retry/compressed/decode_body`
  all off; the validated IP as the connection target with the original
  hostname preserved for SNI/cert/Host) ready for `Req.request/1` after
  the caller adds its method/headers/body — or `{:error, type, message}`
  with `type` in `:invalid_url | :dns_error | :private_ip_blocked`.

  ## Options

    * `:private_policy` — `:deny` (default) | `:allow_all` | `:operator`
      (the `CYFR_PRIVATE_EGRESS_TARGETS` allowlist) | `{:fun, (ip_tuple ->
      boolean)}` (the guest's consent check). Link-local is always
      blocked, whatever the policy — that range is the cloud metadata
      endpoint.
    * `:receive_timeout` — ms (default 30_000)
    * `:protocols` — Mint protocols list (e.g. `[:http1]`)
    * `:transport_opts` — extra Mint transport opts
  """
  @spec pin(String.t(), keyword()) ::
          {:ok, %{ip: String.t(), ip_tuple: :inet.ip_address(), uri: URI.t(), req_opts: keyword()}}
          | {:error, atom(), String.t()}
  def pin(url, opts \\ []) do
    uri = URI.parse(url)
    policy = Keyword.get(opts, :private_policy, :deny)

    with :ok <- check_scheme(uri.scheme),
         :ok <- check_host(uri.host),
         {:ok, ip_tuple} <- resolve_typed(uri.host),
         :ok <- check_ip(ip_tuple, uri.host, policy) do
      ip = format_ip(ip_tuple)

      req_opts =
        [
          url: URI.to_string(%{uri | host: bracket_ip(ip)}),
          compressed: false,
          decode_body: false,
          redirect: false,
          retry: false,
          connect_options:
            [hostname: uri.host]
            |> maybe_put(:protocols, Keyword.get(opts, :protocols))
            |> maybe_put(:transport_opts, Keyword.get(opts, :transport_opts)),
          receive_timeout: Keyword.get(opts, :receive_timeout, 30_000)
        ]

      {:ok, %{ip: ip, ip_tuple: ip_tuple, uri: uri, req_opts: req_opts}}
    end
  end

  defp translate_legacy_opts(opts) do
    policy =
      case Keyword.get(opts, :allow_private, false) do
        true -> :allow_all
        :policy -> :operator
        _ -> :deny
      end

    opts |> Keyword.delete(:allow_private) |> Keyword.put(:private_policy, policy)
  end

  @doc """
  Issue an HTTP request with SSRF protection AND DNS-rebinding protection.

  Resolves and validates the host once, then connects to that validated IP
  while preserving the original hostname for SNI / cert verification / `Host`
  (no second DNS resolution → no rebinding window). The body is returned raw
  (no decompression/decoding) and redirects are NOT followed, so callers stay
  in control of redirect validation.

  Returns a Finch-style 4-tuple `{:ok, status, headers, body}` (headers as a
  `[{name, value}]` list) or `{:error, reason}`.

  ## Options

    * `:allow_private` — see `validate_redirect_url/2` (default `false`)
    * `:receive_timeout` — ms (default 30_000)
    * `:protocols` — Mint protocols list (e.g. `[:http1]`)
    * `:transport_opts` — extra Mint transport opts
  """
  @spec pinned_request(atom(), String.t(), [{String.t(), String.t()}], binary() | nil, keyword()) ::
          {:ok, non_neg_integer(), [{String.t(), String.t()}], binary()} | {:error, term()}
  def pinned_request(method, url, headers \\ [], body \\ nil, opts \\ []) do
    # The identity semantics matter here: no accept-encoding and no decode
    # (OCI digest verification hashes the body as received), no redirects,
    # no Req-level retry — `pin/2` bakes exactly that policy in.
    case pin(url, translate_legacy_opts(opts)) do
      {:ok, %{req_opts: req_opts}} ->
        req_opts =
          req_opts
          |> Keyword.put(:method, method)
          |> Keyword.put(:headers, headers)
          |> maybe_put(:body, body)

        case Req.request(req_opts) do
          {:ok, %Req.Response{status: status, headers: resp_headers, body: resp_body}} ->
            {:ok, status, flatten_headers(resp_headers), resp_body}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _type, message} ->
        {:error, message}
    end
  end

  @doc """
  Format a resolved IP string as a URL authority host, bracketing IPv6 literals.

  Single source of truth for IP-pinning callers that substitute a validated IP
  for the hostname in a URL (this module plus the Opus host-HTTP handlers).
  """
  @spec bracket_ip(String.t()) :: String.t()
  def bracket_ip(ip) when is_binary(ip) do
    if String.contains?(ip, ":"), do: "[" <> ip <> "]", else: ip
  end

  # Req returns headers as %{name => [values]}; flatten to the [{name, value}]
  # list shape the Finch-style callers expect.
  defp flatten_headers(headers) when is_map(headers) do
    Enum.flat_map(headers, fn {k, vs} ->
      Enum.map(List.wrap(vs), &{to_string(k), to_string(&1)})
    end)
  end

  defp flatten_headers(headers) when is_list(headers), do: headers

  defp check_scheme(scheme) when scheme in ["http", "https"], do: :ok
  defp check_scheme(nil), do: {:error, :invalid_url, "missing URL scheme"}
  defp check_scheme(scheme), do: {:error, :invalid_url, "blocked URL scheme: #{scheme}"}

  defp check_host(nil), do: {:error, :invalid_url, "missing hostname"}
  defp check_host(""), do: {:error, :invalid_url, "missing hostname"}
  defp check_host(_), do: :ok

  defp resolve_typed(hostname) do
    charlist = String.to_charlist(hostname)

    case :inet.getaddr(charlist, :inet) do
      {:ok, ip_tuple} ->
        {:ok, ip_tuple}

      {:error, _} ->
        case :inet.getaddr(charlist, :inet6) do
          {:ok, ip_tuple} ->
            {:ok, ip_tuple}

          {:error, reason} ->
            {:error, :dns_error, "DNS resolution failed for #{hostname}: #{inspect(reason)}"}
        end
    end
  end

  defp check_ip(ip_tuple, hostname, policy) do
    if private_ip?(ip_tuple) do
      cond do
        # 169.254.0.0/16 always blocked — cloud metadata endpoint
        Sanctum.Cidr.link_local?(ip_tuple) ->
          {:error, :private_ip_blocked,
           "link-local IP #{format_ip(ip_tuple)} blocked (resolved from #{hostname})"}

        private_permitted?(policy, hostname, ip_tuple) ->
          :ok

        true ->
          {:error, :private_ip_blocked,
           "private IP #{format_ip(ip_tuple)} blocked (resolved from #{hostname})"}
      end
    else
      :ok
    end
  end

  defp private_permitted?(:allow_all, _hostname, _ip), do: true
  defp private_permitted?(:operator, hostname, ip), do: private_allowed?(hostname, ip)
  defp private_permitted?({:fun, fun}, _hostname, ip) when is_function(fun, 1), do: fun.(ip)
  defp private_permitted?(_, _hostname, _ip), do: false

  @doc """
  Whether the operator's private-egress allowlist names this target: the
  hostname exactly (case-insensitive), or the resolved IP by address or
  CIDR. Read from `config :cyfr, :private_egress_targets`; empty refuses.
  """
  @spec private_allowed?(String.t() | nil, :inet.ip_address()) :: boolean()
  def private_allowed?(hostname, ip_tuple) do
    host = if is_binary(hostname), do: String.downcase(hostname), else: nil

    Enum.any?(private_egress_targets(), fn target ->
      String.downcase(target) == host or Sanctum.Cidr.match?(ip_tuple, target)
    end)
  end

  @doc "The private-egress allowlist as configured (hostnames, IPs, CIDRs)."
  @spec private_egress_targets() :: [String.t()]
  def private_egress_targets do
    case Application.get_env(:cyfr, :private_egress_targets, []) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  @doc """
  Check if an IP tuple is in a private/reserved range.
  """
  @spec private_ip?(:inet.ip4_address() | :inet.ip6_address()) :: boolean()
  def private_ip?({a, b, c, d}) do
    ip_int = bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d

    Enum.any?(@private_ranges, fn {base, mask} ->
      band(ip_int, mask) == base
    end)
  end

  # IPv6 loopback ::1
  def private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  # IPv6 unspecified ::
  def private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true

  # IPv6 unique local fc00::/7
  def private_ip?({w1, _, _, _, _, _, _, _}) when w1 >= 0xFC00 and w1 <= 0xFDFF, do: true

  # IPv6 link-local fe80::/10
  def private_ip?({w1, _, _, _, _, _, _, _}) when w1 >= 0xFE80 and w1 <= 0xFEBF, do: true

  # IPv4-mapped IPv6 (::ffff:x.x.x.x) — delegate to IPv4 check
  def private_ip?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    private_ip?({bsr(ab, 8), band(ab, 0xFF), bsr(cd, 8), band(cd, 0xFF)})
  end

  # NAT64 well-known prefix 64:ff9b::/96 (RFC 6052) — the embedded IPv4
  # decides. Without this, 64:ff9b::a9fe:a9fe reaches 169.254.169.254
  # through a NAT64 gateway.
  def private_ip?({0x64, 0xFF9B, 0, 0, 0, 0, ab, cd}) do
    private_ip?({bsr(ab, 8), band(ab, 0xFF), bsr(cd, 8), band(cd, 0xFF)})
  end

  # 6to4 2002::/16 (RFC 3056) — the embedded IPv4 decides.
  def private_ip?({0x2002, ab, cd, _, _, _, _, _}) do
    private_ip?({bsr(ab, 8), band(ab, 0xFF), bsr(cd, 8), band(cd, 0xFF)})
  end

  # All other IPv6 addresses are considered public
  def private_ip?({_, _, _, _, _, _, _, _}), do: false

  defp format_ip(ip_tuple), do: :inet.ntoa(ip_tuple) |> to_string()
end
