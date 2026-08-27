# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ProviderVocabularyTest do
  @moduledoc """
  `Sanctum.Atoms` lists the sign-in providers so their atoms exist before
  anything converts a stored string into one. The list is literal — it has
  to be, because it runs at compile time — so nothing stopped it drifting,
  and it had: `okta`, `azure` and `local` are providers this server has
  never had, and it spelled the generic OIDC provider `oidc` where every
  other module spells it `oidcc`.

  A vocabulary that names three providers that do not exist and misses the
  one that does is not an allowlist; it is a list.
  """

  use ExUnit.Case, async: true

  alias Sanctum.Auth.DeviceFlow

  # The generic-OIDC provider. `Sanctum.Auth.OIDC` is the module; `:oidcc`
  # is the name it signs people in under (see `Sanctum.Auth.EmailVerification`
  # and the sign-in page's provider list).
  @oidc_provider "oidcc"

  test "the atom vocabulary is exactly the device-flow roster plus OIDC" do
    assert Enum.sort(Sanctum.Atoms.providers()) ==
             Enum.sort([@oidc_provider | DeviceFlow.providers()])
  end

  test "every named provider has a canonical issuer or is the OIDC one" do
    # A direct provider mints ids as `provider|issuer|subject`, so a name
    # with no canonical issuer cannot mint one. OIDC brings its own issuer
    # from the operator's configuration.
    for provider <- Sanctum.Atoms.providers(), provider != @oidc_provider do
      assert is_binary(Sanctum.Auth.Identity.issuer(provider)),
             "#{provider} is in the vocabulary but has no canonical issuer"
    end
  end

  test "retired names are gone" do
    for retired <- ~w(okta azure local oidc) do
      refute retired in Sanctum.Atoms.providers()
    end
  end
end
