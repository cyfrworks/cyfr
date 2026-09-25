# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Egress do
  @moduledoc """
  Where a guest's outbound HTTP request may connect: its URL resolved once,
  the address checked against the address classes in `Prima.Cidr` and the
  guest's consent, and the connection pinned to that address.

  A caller that checked a hostname and then connects by name resolves DNS
  a second time, and an attacker's domain can answer a public address for
  the check and a private one for the connection. `pin/2` closes that gap:
  it resolves and validates the host once and answers the request options
  that connect to that exact address while the original hostname is kept
  for TLS SNI, certificate verification and the `Host` header. The
  validated address is the connection target, so there is no second
  resolution to rebind.

  A cloud-metadata address (`Prima.Cidr.metadata?/1`) is refused whatever
  the consent says. A private address (`Prima.Cidr.private_ip?/1`) is
  refused unless the `:private_policy` function admits it: the guest's
  `egress.private_ips` grant (`Opus.EdgeGuard.allows_private_ip?/2`).
  """

  @typedoc """
  What `pin/2` answers: the address as text and as a tuple, the parsed
  URI, and the `Req` options that connect to that address with the
  fail-closed transport policy (no redirect, no retry, no compression, no
  body decoding), ready for the caller's method, headers and body.
  """
  @type pinned :: Prima.Network.pinned()

  @type refusal :: :invalid_url | :dns_error | :private_ip_blocked

  @doc """
  Resolve, validate and pin `url` for an outbound request.

  ## Options

    * `:private_policy` — `:deny` (default), or `{:fun, (ip_tuple -> boolean)}`,
      the consent check a private address must pass. A metadata address
      is refused whatever the policy.
    * `:receive_timeout` — ms (default 30_000)
    * `:protocols` — Mint protocols list (e.g. `[:http1]`)
    * `:transport_opts` — extra Mint transport opts
    * `:resolver` — the module the host is resolved through, answering
      `getaddr/2` as `:inet` does. Defaults to `config :opus, :resolver`,
      which no deployment sets (`:inet`): the suite's seam for the
      guest-facing entry points, which take no options of their own.

  Answers `{:ok, pinned}` (`t:pinned/0`) or `{:error, type, message}`
  (`t:refusal/0`).
  """
  @spec pin(String.t(), keyword()) :: {:ok, pinned()} | {:error, refusal(), String.t()}
  def pin(url, opts \\ []) when is_binary(url) and is_list(opts) do
    policy =
      case Keyword.get(opts, :private_policy, :deny) do
        {:fun, fun} when is_function(fun, 1) -> {:fun, fn ip -> fun.(ip) == true end}
        _ -> :deny
      end

    resolver = Keyword.get_lazy(opts, :resolver, &default_resolver/0)

    with {:ok, uri} <- Prima.Network.parse_url(url),
         {:ok, ip} <- resolve(uri.host, resolver) do
      Prima.Network.pin(uri, ip, Keyword.put(opts, :private_policy, policy))
    end
  end

  # IPv4 first, IPv6 only when no A record resolves: a dual-stack host is
  # pinned to its v4 address, and its AAAA record is never resolved or
  # checked — safe because the connection pins to the address checked
  # here, so the unchecked family is also the unused one. A v6-first or
  # happy-eyeballs resolver would have to move the check with the address
  # actually dialed.
  defp resolve(hostname, resolver) do
    charlist = String.to_charlist(hostname)

    case resolver.getaddr(charlist, :inet) do
      {:ok, ip_tuple} ->
        {:ok, ip_tuple}

      {:error, _} ->
        case resolver.getaddr(charlist, :inet6) do
          {:ok, ip_tuple} ->
            {:ok, ip_tuple}

          {:error, reason} ->
            {:error, :dns_error,
             "DNS resolution failed for #{hostname}: #{:inet.format_error(reason)}"}
        end
    end
  end

  # The suite's seam for the guest-facing entry points, which take no
  # options of their own; no deployment sets it, and the host is resolved
  # through `:inet`.
  defp default_resolver, do: Application.get_env(:opus, :resolver, :inet)
end
