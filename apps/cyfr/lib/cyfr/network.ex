# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Network do
  @moduledoc """
  Network security utilities for SSRF prevention.

  Validates redirect URLs before following them, blocking requests to
  private/reserved IP ranges. Used by OCI blob operations to prevent
  malicious registries from redirecting to internal services or cloud
  metadata endpoints.
  """

  import Bitwise

  # Private IPv4 ranges (CIDR notation as {base, mask} tuples)
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
    {0, 0xFF000000}
  ]

  @doc """
  Validate a redirect URL is safe to follow.

  Checks scheme (http/https only), hostname presence, and DNS resolution
  to a non-private IP address.

  ## Options

    * `:allow_private` - when `true`, permits private IPs except
      169.254.0.0/16 (link-local/cloud metadata) which is always blocked.
      Useful for default-mode deployments with localhost registries.

  Returns `:ok` or `{:error, reason_string}`.
  """
  @spec validate_redirect_url(String.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_redirect_url(url, opts \\ []) do
    uri = URI.parse(url)

    with :ok <- validate_scheme(uri.scheme),
         :ok <- validate_host_present(uri.host),
         {:ok, ip_tuple} <- resolve_host(uri.host) do
      validate_ip(ip_tuple, uri.host, Keyword.get(opts, :allow_private, false))
    end
  end

  defp validate_scheme(scheme) when scheme in ["http", "https"], do: :ok
  defp validate_scheme(nil), do: {:error, "missing URL scheme"}
  defp validate_scheme(scheme), do: {:error, "blocked URL scheme: #{scheme}"}

  defp validate_host_present(nil), do: {:error, "missing hostname"}
  defp validate_host_present(""), do: {:error, "missing hostname"}
  defp validate_host_present(_), do: :ok

  defp resolve_host(hostname) do
    charlist = String.to_charlist(hostname)

    case :inet.getaddr(charlist, :inet) do
      {:ok, ip_tuple} ->
        {:ok, ip_tuple}

      {:error, _} ->
        case :inet.getaddr(charlist, :inet6) do
          {:ok, ip_tuple} ->
            {:ok, ip_tuple}

          {:error, reason} ->
            {:error, "DNS resolution failed for #{hostname}: #{inspect(reason)}"}
        end
    end
  end

  defp validate_ip(ip_tuple, hostname, allow_private) do
    if private_ip?(ip_tuple) do
      if Sanctum.Cidr.link_local?(ip_tuple) do
        # 169.254.0.0/16 always blocked — cloud metadata endpoint
        {:error, "link-local IP #{format_ip(ip_tuple)} blocked (resolved from #{hostname})"}
      else
        if allow_private do
          :ok
        else
          {:error, "private IP #{format_ip(ip_tuple)} blocked (resolved from #{hostname})"}
        end
      end
    else
      :ok
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

  # All other IPv6 addresses are considered public
  def private_ip?({_, _, _, _, _, _, _, _}), do: false

  defp format_ip(ip_tuple), do: :inet.ntoa(ip_tuple) |> to_string()
end