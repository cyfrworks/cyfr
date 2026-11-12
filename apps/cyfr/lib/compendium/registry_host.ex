# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.RegistryHost do
  @moduledoc """
  The canonical registry hosts for this deployment — deployment/network
  configuration, one accessor each, consumed by every module that talks
  to (or names) the remote registry: the OCI client, the REST client,
  pull, identity, sign-in, and the MCP tools. The component index
  (`Compendium.Registry`) is deliberately not the home for hostnames.
  """

  @doc """
  Whether `value` names an OCI registry: what `Sanctum.registry_url?/1`
  names, or a bracketed IPv6 literal, each with an optional port from 1 to
  65535. The OCI transport reaches an IPv6 registry by its bracketed URL
  authority; nothing signed names this host.
  """
  @spec oci_host?(term()) :: boolean()
  def oci_host?(value) when is_binary(value) do
    case Regex.run(~r/\A\[([0-9A-Fa-f:.]+)\](?::([^:]*))?\z/, value, capture: :all_but_first) do
      [address | port] ->
        match?({:ok, _}, :inet.parse_ipv6strict_address(String.to_charlist(address))) and
          Enum.all?(port, &Sanctum.port?/1)

      nil ->
        Sanctum.registry_url?(value)
    end
  end

  def oci_host?(_value), do: false

  @doc """
  Canonical OCI Distribution host for this deployment: `CYFR_OCI_REGISTRY_URL`,
  or `registry.` before the REST host (`config/runtime.exs`).
  """
  @spec canonical_host() :: String.t()
  def canonical_host, do: Application.fetch_env!(:cyfr, :oci_registry_url)

  @doc """
  Canonical REST API host for this deployment (cyfr.run `/v1/*`
  endpoints): `CYFR_REGISTRY_URL`, `cyfr.run` when unset
  (`config/runtime.exs`).
  """
  @spec canonical_rest_host() :: String.t()
  def canonical_rest_host, do: Application.fetch_env!(:cyfr, :registry_url)

  @doc """
  The base URL of a registry `host`, under the scheme its host takes
  (`Sanctum.registry_base_url/1`).
  """
  @spec base_url(String.t()) :: String.t()
  defdelegate base_url(host), to: Sanctum, as: :registry_base_url

  @doc """
  Whether an OCI registry host is this deployment's canonical one. Any
  other host is refused with a typed `Compendium.OCI.Errors`, before any
  I/O; the surfaces render it.
  """
  @spec validate_host(String.t()) :: :ok | {:error, Compendium.OCI.Errors.t()}
  def validate_host(host) do
    canonical = canonical_host()

    if host == canonical,
      do: :ok,
      else: {:error, Compendium.OCI.Errors.host_not_canonical(host, canonical)}
  end
end
