# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Network do
  @moduledoc """
  Where an outbound request may connect: the decision, not the request.

  Validates outbound URLs before connecting, blocking requests to
  private/reserved IP ranges (`Cyfr.Cidr.private_ip?/1`). Used by OCI blob
  operations and external MCP servers to prevent malicious registries/servers
  from reaching internal services or cloud metadata endpoints.

  ## DNS-rebinding protection

  `validate_redirect_url/2` only *checks* a URL — a caller that then connects
  by hostname re-resolves DNS and reopens a time-of-check/time-of-use gap (an
  attacker-controlled domain can answer a public IP for the check and a private
  IP for the connection). `pin/2` closes that gap: it resolves and validates
  the host ONCE, and answers the request options that connect to that exact
  IP while preserving the original hostname for the TLS SNI, certificate
  verification, and `Host` header (via Mint's `:hostname` connect option).
  The validated IP is the connection target, so there is no second
  resolution to rebind.

  ## Deciding here, connecting there

  This module holds no HTTP client and issues no request: every check, the
  `:resolver` seam and the fail-closed transport policy baked into
  `req_opts` live here, so the layers below the host can validate a
  destination without an HTTP client in their dependency tree. Actually
  sending the request is a handful of lines over `pin/2` with no security
  decision in them, and each side that speaks HTTP owns its own —
  `Cyfr.Egress` for the control plane, `Sanctum.Vault.OAuth` for the token
  endpoint, `Opus.Egress` for the guest. `Cyfr.EgressInventoryTest` is the
  roster of those sites.
  """

  import Cyfr.MapUtil, only: [put_unless_nil: 3]

  @doc """
  Validate a redirect URL is safe to follow.

  Checks scheme (http/https only), hostname presence, and DNS resolution
  to a non-private IP address.

  ## Options

    * `:private_policy` — see `pin/2` (default `:deny`). `:operator` permits
      a private IP only when the host or the IP is on the operator's
      private-egress allowlist (`CYFR_PRIVATE_EGRESS_TARGETS`,
      `private_allowed?/2`): a compose-network mcp-bridge is named, never
      implied.

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

  Single source of truth for the scheme/host/IP checks. Same `:private_policy`
  semantics as `validate_redirect_url/2`.
  """
  @spec resolve_and_validate(String.t(), keyword()) ::
          {:ok, :inet.ip_address(), URI.t()} | {:error, String.t()}
  def resolve_and_validate(url, opts \\ []) do
    case pin(url, opts) do
      {:ok, %{ip_tuple: ip_tuple, uri: uri}} -> {:ok, ip_tuple, uri}
      {:error, _type, message} -> {:error, message}
    end
  end

  @doc """
  Resolves, validates and pins a URL for outbound requests. Used by host
  calls (OCI, registry and external MCP) and WASM HTTP handlers, which
  supply a consent-policy function.

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
      boolean)}` (the guest's consent check). A cloud-metadata address
      (`Cyfr.Cidr.metadata?/1`, IPv6 forms embedding one included) is
      always blocked, whatever the policy.
    * `:receive_timeout` — ms (default 30_000)
    * `:protocols` — Mint protocols list (e.g. `[:http1]`)
    * `:transport_opts` — extra Mint transport opts
    * `:resolver` — the module the host is resolved through, answering
      `getaddr/2` as `:inet` does (the default). A test's fixed table of
      answers goes here, so the decision it asserts is the table's and
      not the public resolver's.
  """
  @spec pin(String.t(), keyword()) ::
          {:ok,
           %{ip: String.t(), ip_tuple: :inet.ip_address(), uri: URI.t(), req_opts: keyword()}}
          | {:error, atom(), String.t()}
  def pin(url, opts \\ []) do
    uri = URI.parse(url)
    policy = Keyword.get(opts, :private_policy, :deny)
    resolver = Keyword.get(opts, :resolver, :inet)

    with :ok <- check_scheme(uri.scheme),
         :ok <- check_host(uri.host),
         {:ok, ip_tuple} <- resolve_typed(uri.host, resolver),
         :ok <- check_ip(ip_tuple, uri.host, policy) do
      ip = format_ip(ip_tuple)

      req_opts =
        [
          url: URI.to_string(%{uri | host: ip}),
          compressed: false,
          decode_body: false,
          redirect: false,
          retry: false,
          connect_options:
            [hostname: uri.host]
            |> put_unless_nil(:protocols, Keyword.get(opts, :protocols))
            |> put_unless_nil(:transport_opts, Keyword.get(opts, :transport_opts)),
          receive_timeout: Keyword.get(opts, :receive_timeout, 30_000)
        ]

      {:ok, %{ip: ip, ip_tuple: ip_tuple, uri: uri, req_opts: req_opts}}
    end
  end

  defp check_scheme(scheme) when scheme in ["http", "https"], do: :ok
  defp check_scheme(nil), do: {:error, :invalid_url, "missing URL scheme"}
  defp check_scheme(scheme), do: {:error, :invalid_url, "blocked URL scheme: #{scheme}"}

  defp check_host(nil), do: {:error, :invalid_url, "missing hostname"}
  defp check_host(""), do: {:error, :invalid_url, "missing hostname"}
  defp check_host(_), do: :ok

  # IPv4 first, IPv6 only when no A record resolves: a dual-stack host is
  # always pinned to its v4 address, and its AAAA record is never resolved
  # or policy-checked — which is safe precisely because the connection
  # pins to the address checked here, so the unchecked family is also the
  # unused one. If v6-first (or happy-eyeballs) ever lands, the policy
  # check must move with the address actually dialed.
  defp resolve_typed(hostname, resolver) do
    charlist = String.to_charlist(hostname)

    case resolver.getaddr(charlist, :inet) do
      {:ok, ip_tuple} ->
        {:ok, ip_tuple}

      {:error, _} ->
        case resolver.getaddr(charlist, :inet6) do
          {:ok, ip_tuple} ->
            {:ok, ip_tuple}

          {:error, reason} ->
            {:error, :dns_error, "DNS resolution failed for #{hostname}: #{inspect(reason)}"}
        end
    end
  end

  # A metadata address is refused before the private classification or any
  # policy is consulted.
  defp check_ip(ip_tuple, hostname, policy) do
    cond do
      Cyfr.Cidr.metadata?(ip_tuple) ->
        {:error, :private_ip_blocked,
         "metadata IP #{format_ip(ip_tuple)} blocked (resolved from #{hostname})"}

      not Cyfr.Cidr.private_ip?(ip_tuple) ->
        :ok

      private_permitted?(policy, hostname, ip_tuple) ->
        :ok

      true ->
        {:error, :private_ip_blocked,
         "private IP #{format_ip(ip_tuple)} blocked (resolved from #{hostname})"}
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
      String.downcase(target) == host or Cyfr.Cidr.match?(ip_tuple, target)
    end)
  end

  @doc """
  The private-egress allowlist as configured (hostnames, IPs, CIDRs).

  The key stays under `:cyfr`: the allowlist is the operator's deployment
  setting, read from `CYFR_PRIVATE_EGRESS_TARGETS` by the host's runtime
  configuration, and this module is the shared transport that consults
  it rather than its owner. An absent key is the empty allowlist, which
  refuses every private target — the fail-closed direction.
  """
  @spec private_egress_targets() :: [String.t()]
  def private_egress_targets do
    case Application.get_env(:cyfr, :private_egress_targets, []) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  defp format_ip(ip_tuple), do: :inet.ntoa(ip_tuple) |> to_string()
end
