# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.RegistryPortTest do
  @moduledoc """
  `CYFR_REGISTRY_URL=none`: no registry. Every client answers a typed
  refusal at its network seam without dialling, and the health probe says
  "disabled" rather than "down".
  """
  use ExUnit.Case, async: false

  alias Compendium.OCI.Errors
  alias Compendium.RegistryHost

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    previous = {
      Application.get_env(:cyfr, :registry_url),
      Application.get_env(:cyfr, :oci_registry_url)
    }

    Application.put_env(:cyfr, :registry_url, "none")
    Application.put_env(:cyfr, :oci_registry_url, "none")

    on_exit(fn ->
      {rest, oci} = previous
      # An unset key is restored by deleting it, never by writing nil: the
      # accessors default only on absence.
      restore = fn key, value ->
        if is_nil(value),
          do: Application.delete_env(:cyfr, key),
          else: Application.put_env(:cyfr, key, value)
      end

      restore.(:registry_url, rest)
      restore.(:oci_registry_url, oci)
    end)

    :ok
  end

  test "the host accessors still answer strings, and nothing is configured" do
    refute RegistryHost.configured?()
    assert is_binary(RegistryHost.canonical_host())
    assert is_binary(RegistryHost.canonical_rest_host())
  end

  test "the OCI seam refuses every host, the canonical one included" do
    assert {:error, message} = RegistryHost.validate_host("registry.cyfr.run")
    assert message =~ "CYFR_REGISTRY_URL=none"
    assert {:error, _} = RegistryHost.validate_host("none")
  end

  test "the REST seam refuses before any I/O" do
    ctx = Sanctum.TestContext.local()

    assert {:error, %Errors{reason: :registry_unconfigured}} =
             Compendium.Registry.Client.search(ctx, %{"q" => "anything"})

    assert {:error, %Errors{reason: :registry_unconfigured}} =
             Compendium.Registry.Client.probe_identity("github", "token")
  end
end
