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

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    previous = {
      Application.get_env(:cyfr, :registry_url),
      Application.get_env(:cyfr, :oci_registry_url),
      Application.get_env(:sanctum, :registry_url)
    }

    on_exit(fn ->
      {rest, oci, sanctum} = previous
      # An unset key is restored by deleting it, never by writing nil: the
      # accessors default only on absence.
      restore = fn app, key, value ->
        if is_nil(value),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end

      restore.(:cyfr, :registry_url, rest)
      restore.(:cyfr, :oci_registry_url, oci)
      restore.(:sanctum, :registry_url, sanctum)
    end)

    # The one parse of `CYFR_REGISTRY_URL=none` sets both applications' copies.
    Application.put_env(:cyfr, :registry_url, "none")
    Application.put_env(:cyfr, :oci_registry_url, "none")
    Application.put_env(:sanctum, :registry_url, "none")

    :ok
  end

  test "the host accessors still answer strings, and nothing is configured" do
    refute RegistryHost.configured?()
    assert is_binary(RegistryHost.canonical_host())
    assert is_binary(RegistryHost.canonical_rest_host())
  end

  test "the OCI seam refuses every host, the canonical one included, typed" do
    assert {:error, %Errors{reason: :registry_unconfigured} = refusal} =
             RegistryHost.validate_host("registry.cyfr.run")

    assert Errors.to_string(refusal) =~ "CYFR_REGISTRY_URL=none"
    assert {:error, %Errors{reason: :registry_unconfigured}} = RegistryHost.validate_host("none")
  end

  test "the REST seam refuses before any I/O" do
    ctx = Sanctum.TestContext.local()

    assert {:error, %Errors{reason: :registry_unconfigured}} =
             Compendium.Registry.Client.search(ctx, %{"q" => "anything"})
  end

  test "a signed registry request and a handle resolution refuse no_registry before any I/O" do
    assert {:error, :no_registry} =
             Compendium.Registry.Client.signed("usr_none", "tokens.mint", %{"label" => "laptop"})

    assert {:error, :no_registry} = Sanctum.Handle.resolve("alice")
  end
end
