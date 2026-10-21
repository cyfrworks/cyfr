# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ProviderVocabularyTest do
  @moduledoc """
  The sign-in roster (`Prima.SignInProviders`) is the device-flow
  providers and `oidcc` for generic OIDC, and every provider it names
  mints identifiers under a canonical issuer.
  """

  use ExUnit.Case, async: true

  alias Sanctum.Auth.DeviceFlow

  # The generic-OIDC provider. `Sanctum.Auth.OIDC` is the module; `:oidcc`
  # is the name it signs people in under (see `Sanctum.Auth.EmailVerification`
  # and the sign-in page's provider list).
  @oidc_provider "oidcc"

  test "the roster is exactly the device-flow providers plus OIDC" do
    assert Enum.sort(Prima.SignInProviders.all()) ==
             Enum.sort([@oidc_provider | DeviceFlow.providers()])
  end

  test "every named provider has a canonical issuer or is the OIDC one" do
    # A direct provider's identity key is `provider|issuer|subject`, so a
    # name with no canonical issuer cannot make one. OIDC brings its own
    # issuer from the operator's configuration.
    for provider <- Prima.SignInProviders.all(), provider != @oidc_provider do
      assert is_binary(Sanctum.Auth.Identity.issuer(provider)),
             "#{provider} is in the roster but has no canonical issuer"
    end
  end
end
