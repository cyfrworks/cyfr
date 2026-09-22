# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Network do
  @moduledoc """
  Pure outbound URL, address-policy and pinned-connection contracts.

  Callers supply the resolved address and any private-address policy. This
  module performs no DNS lookup, configuration read or HTTP request. Metadata
  addresses are refused before any policy override. A pinned connection uses
  exactly the supplied address and retains the original TLS and Host identity.
  """

  import Cyfr.MapUtil, only: [put_unless_nil: 3]

  @type pinned :: %{
          ip: String.t(),
          ip_tuple: :inet.ip_address(),
          uri: URI.t(),
          req_opts: keyword()
        }

  @doc "Parse an HTTP(S) URL with a hostname before its caller resolves it."
  @spec parse_url(String.t()) :: {:ok, URI.t()} | {:error, :invalid_url, String.t()}
  def parse_url(url) when is_binary(url) do
    uri = URI.parse(url)

    with :ok <- check_scheme(uri.scheme), :ok <- check_host(uri.host), do: {:ok, uri}
  rescue
    ArgumentError -> {:error, :invalid_url, "invalid URL"}
  end

  @doc """
  Validate a resolved address and construct its pinned connection options.

  `:private_policy` is `:deny` (default), `:allow_all`, `{:allowlist, targets}`
  or `{:fun, predicate}`. `:receive_timeout`, `:protocols` and `:transport_opts`
  are copied into the connection options. Redirects, retries, decompression
  and body decoding stay disabled so the caller controls every next request.
  """
  @spec pin(URI.t(), :inet.ip_address(), keyword()) ::
          {:ok, pinned()} | {:error, :private_ip_blocked, String.t()}
  def pin(%URI{} = uri, ip_tuple, opts) when is_list(opts) do
    policy = Keyword.get(opts, :private_policy, :deny)

    with :ok <- check_ip(ip_tuple, uri.host, policy) do
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

  defp private_permitted?({:allowlist, targets}, hostname, ip),
    do: private_allowed?(hostname, ip, targets)

  defp private_permitted?({:fun, fun}, _hostname, ip) when is_function(fun, 1), do: fun.(ip)
  defp private_permitted?(_, _hostname, _ip), do: false

  @doc "Match an explicit private-egress allowlist by hostname, address or CIDR."
  @spec private_allowed?(String.t() | nil, :inet.ip_address(), [String.t()]) :: boolean()
  def private_allowed?(hostname, ip_tuple, targets) do
    host = if is_binary(hostname), do: String.downcase(hostname), else: nil

    Enum.any?(targets, fn target ->
      String.downcase(target) == host or Cyfr.Cidr.match?(ip_tuple, target)
    end)
  end

  defp format_ip(ip_tuple), do: :inet.ntoa(ip_tuple) |> to_string()
end
