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

  @default_oci_host "registry.cyfr.run"
  @default_rest_host "cyfr.run"

  # `CYFR_REGISTRY_URL=none`: this deployment talks to no registry at all.
  # The accessors still answer a string — the host is interpolated into
  # messages and credential keys all over the tree — and the two network
  # seams (`Compendium.Registry.Transport`, `validate_host/1`) refuse
  # before any I/O. Personhood does not depend on it (`Sanctum.SignIn`);
  # publishing and pulling do, and say so.
  @none "none"

  @doc """
  Whether a remote registry is configured at all. An appliance that runs
  only what it ships sets `CYFR_REGISTRY_URL=none` and every registry
  client answers `:registry_unconfigured` instead of dialling.
  """
  @spec configured?() :: boolean()
  def configured?, do: canonical_rest_host() != @none

  @doc "The sentinel that means no registry."
  @spec none() :: String.t()
  def none, do: @none

  @doc """
  Canonical OCI Distribution host for this deployment.

  Defaults to `"registry.cyfr.run"`. Self-hosted deployments override via
  `CYFR_OCI_REGISTRY_URL` (wired in `config/runtime.exs`).
  """
  @spec canonical_host() :: String.t()
  def canonical_host,
    do: Application.get_env(:cyfr, :oci_registry_url, @default_oci_host)

  @doc """
  Canonical REST API host for this deployment (cyfr.run `/v1/*`
  endpoints).

  Defaults to `"cyfr.run"`. Self-hosted deployments override via
  `CYFR_REGISTRY_URL`.
  """
  @spec canonical_rest_host() :: String.t()
  def canonical_rest_host,
    do: Application.get_env(:cyfr, :registry_url, @default_rest_host)

  @doc """
  Validate that an OCI registry hostname matches the canonical host for
  this deployment. Rejects any other host with an explanatory error
  tuple.
  """
  @spec validate_host(String.t()) :: :ok | {:error, String.t()}
  def validate_host(host) do
    canonical = canonical_host()

    cond do
      not configured?() ->
        {:error, "No registry is configured on this server (CYFR_REGISTRY_URL=none)."}

      host == canonical ->
        :ok

      true ->
        {:error, "This deployment only supports #{canonical}, got: #{host}."}
    end
  end
end
