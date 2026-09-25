# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Network do
  @moduledoc """
  Resolves control-plane outbound destinations and applies the operator's
  private-egress configuration through the shared pure network policy.

  `pin/2` resolves once and returns options that connect to that exact address.
  `validate_redirect_url/2` only checks; the subsequent request must still pin
  its connection. HTTP transport belongs to `Sanctum.Egress`.
  """

  @spec validate_redirect_url(String.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_redirect_url(url, opts \\ []) do
    case resolve_and_validate(url, opts) do
      {:ok, _ip, _uri} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec resolve_and_validate(String.t(), keyword()) ::
          {:ok, :inet.ip_address(), URI.t()} | {:error, String.t()}
  def resolve_and_validate(url, opts \\ []) do
    case pin(url, opts) do
      {:ok, %{ip_tuple: ip, uri: uri}} -> {:ok, ip, uri}
      {:error, _type, message} -> {:error, message}
    end
  end

  @doc """
  Resolve and pin a URL under `:private_policy` (`:deny` by default).

  `:operator` uses the configured private-egress allowlist; `:allow_all` and
  `{:fun, predicate}` retain their explicit meanings. Metadata addresses are
  always refused. `:resolver` defaults to `:inet`; remaining transport options
  are the pure `Prima.Network.pin/3` options.
  """
  @spec pin(String.t(), keyword()) ::
          {:ok, Prima.Network.pinned()} | {:error, atom(), String.t()}
  def pin(url, opts \\ []) do
    policy =
      case Keyword.get(opts, :private_policy, :deny) do
        :operator -> {:allowlist, private_egress_targets()}
        policy -> policy
      end

    resolver = Keyword.get(opts, :resolver, :inet)

    with {:ok, uri} <- Prima.Network.parse_url(url),
         {:ok, ip} <- resolve_typed(uri.host, resolver) do
      Prima.Network.pin(uri, ip, Keyword.put(opts, :private_policy, policy))
    end
  end

  @spec private_allowed?(String.t() | nil, :inet.ip_address()) :: boolean()
  def private_allowed?(hostname, ip),
    do: Prima.Network.private_allowed?(hostname, ip, private_egress_targets())

  @doc """
  The operator's hostnames, IPs and CIDRs from `CYFR_PRIVATE_EGRESS_TARGETS`.
  Host parses the environment into `:sanctum, :private_egress_targets`.
  An absent value is empty; malformed configuration refuses instead of being
  silently weakened by dropping entries.
  """
  @spec private_egress_targets() :: [String.t()]
  def private_egress_targets do
    targets = Application.get_env(:sanctum, :private_egress_targets, [])

    unless is_list(targets) and Enum.all?(targets, &valid_target?/1) do
      raise ArgumentError, "invalid CYFR_PRIVATE_EGRESS_TARGETS: expected hostnames, IPs or CIDRs"
    end

    targets
  end

  defp valid_target?(target) when is_binary(target) and target != "" do
    cond do
      Regex.match?(~r/[\x00-\x1f\x7f]/, target) -> false
      String.contains?(target, "/") -> match?({:ok, _}, Prima.Cidr.parse_cidr(target))
      match?({:ok, _}, Prima.Cidr.parse_ip(target)) -> true
      true -> valid_hostname?(target)
    end
  end

  defp valid_target?(_), do: false

  defp valid_hostname?(hostname) do
    byte_size(hostname) <= 253 and
      not Regex.match?(~r/\A[0-9.]+\z/, hostname) and
      Enum.all?(String.split(String.replace_suffix(hostname, ".", ""), "."), fn label ->
        byte_size(label) in 1..63 and
          Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\z/, label)
      end)
  end

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
            {:error, :dns_error, "DNS resolution failed for #{hostname}: #{:inet.format_error(reason)}"}
        end
    end
  end
end
