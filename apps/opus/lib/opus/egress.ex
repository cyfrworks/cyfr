# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Egress do
  @moduledoc """
  Where a guest's outbound HTTP request may connect: its URL resolved once,
  the address checked against the address classes in `Cyfr.Cidr` and the
  guest's consent, and the connection pinned to that address.

  A caller that checked a hostname and then connects by name resolves DNS
  a second time, and an attacker's domain can answer a public address for
  the check and a private one for the connection. `pin/2` closes that gap:
  it resolves and validates the host once and answers the request options
  that connect to that exact address while the original hostname is kept
  for TLS SNI, certificate verification and the `Host` header. The
  validated address is the connection target, so there is no second
  resolution to rebind.

  A cloud-metadata address (`Cyfr.Cidr.metadata?/1`) is refused whatever
  the consent says. A private address (`Cyfr.Cidr.private_ip?/1`) is
  refused unless the `:private_policy` function admits it: the guest's
  `egress.private_ips` grant (`Opus.EdgeGuard.allows_private_ip?/2`).
  """

  @typedoc """
  What `pin/2` answers: the address as text and as a tuple, the parsed
  URI, and the `Req` options that connect to that address with the
  fail-closed transport policy (no redirect, no retry, no compression, no
  body decoding), ready for the caller's method, headers and body.
  """
  @type pinned :: %{
          ip: String.t(),
          ip_tuple: :inet.ip_address(),
          uri: URI.t(),
          req_opts: keyword()
        }

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

  Answers `{:ok, pinned}` (`t:pinned/0`) or `{:error, type, message}`
  (`t:refusal/0`).
  """
  @spec pin(String.t(), keyword()) :: {:ok, pinned()} | {:error, refusal(), String.t()}
  def pin(url, opts \\ []) when is_binary(url) and is_list(opts) do
    uri = URI.parse(url)
    policy = Keyword.get(opts, :private_policy, :deny)

    with :ok <- check_scheme(uri.scheme),
         :ok <- check_host(uri.host),
         {:ok, ip_tuple} <- resolve(uri.host),
         :ok <- check_ip(ip_tuple, uri.host, policy) do
      ip = format_ip(ip_tuple)

      connect_options =
        [hostname: uri.host]
        |> put_unless_nil(:protocols, Keyword.get(opts, :protocols))
        |> put_unless_nil(:transport_opts, Keyword.get(opts, :transport_opts))

      req_opts = [
        url: URI.to_string(%{uri | host: ip}),
        compressed: false,
        decode_body: false,
        redirect: false,
        retry: false,
        connect_options: connect_options,
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
  defp check_host(_host), do: :ok

  # IPv4 first, IPv6 only when no A record resolves: a dual-stack host is
  # pinned to its v4 address, and its AAAA record is never resolved or
  # checked — safe because the connection pins to the address checked
  # here, so the unchecked family is also the unused one. A v6-first or
  # happy-eyeballs resolver would have to move the check with the address
  # actually dialed.
  defp resolve(hostname) do
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

  # A metadata address is refused before the private classification or
  # any policy is consulted.
  defp check_ip(ip_tuple, hostname, policy) do
    cond do
      Cyfr.Cidr.metadata?(ip_tuple) ->
        {:error, :private_ip_blocked,
         "metadata IP #{format_ip(ip_tuple)} blocked (resolved from #{hostname})"}

      not Cyfr.Cidr.private_ip?(ip_tuple) ->
        :ok

      private_permitted?(policy, ip_tuple) ->
        :ok

      true ->
        {:error, :private_ip_blocked,
         "private IP #{format_ip(ip_tuple)} blocked (resolved from #{hostname})"}
    end
  end

  defp private_permitted?({:fun, fun}, ip) when is_function(fun, 1), do: fun.(ip) == true
  defp private_permitted?(_policy, _ip), do: false

  defp put_unless_nil(keyword, _key, nil), do: keyword
  defp put_unless_nil(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp format_ip(ip_tuple), do: ip_tuple |> :inet.ntoa() |> to_string()
end
