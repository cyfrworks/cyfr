# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.OIDCEmailVerifiedTest do
  @moduledoc """
  What an OpenID Connect issuer said of the email it asserted
  (`Sanctum.Auth.OIDC.email_verified/1`), read from the auth the
  `ueberauth_oidcc` strategy builds: proved, refused or silent. It decides
  only whether the address is written to the person's contact email
  (`Sanctum.Tenancy.Users.seen/2`); no sign-in is refused on it.
  """

  use ExUnit.Case, async: true

  alias Sanctum.Auth.OIDC

  # `%UeberauthOidcc.RawInfo{}` carries `opts/claims/userinfo/introspection`;
  # the arms are only real if they read what the strategy actually builds
  # (`Ueberauth.Strategy.Oidcc.extra/1`).
  defp auth(fields), do: %{extra: %{raw_info: struct!(UeberauthOidcc.RawInfo, fields)}}

  test "userinfo's claim is read" do
    assert OIDC.email_verified(auth(userinfo: %{"email_verified" => true})) == true
    assert OIDC.email_verified(auth(userinfo: %{"email_verified" => false})) == false
  end

  test "the id token's claims are read when userinfo says nothing" do
    assert OIDC.email_verified(auth(claims: %{"email_verified" => true})) == true
    assert OIDC.email_verified(auth(claims: %{"email_verified" => false})) == false
  end

  test "userinfo wins over the id token" do
    assert OIDC.email_verified(
             auth(claims: %{"email_verified" => true}, userinfo: %{"email_verified" => false})
           ) == false
  end

  test "silence, a claim that is no boolean, and an auth with no extra are :unknown" do
    assert OIDC.email_verified(auth(claims: %{})) == :unknown
    assert OIDC.email_verified(auth(claims: %{"email_verified" => "true"})) == :unknown
    assert OIDC.email_verified(%{}) == :unknown
  end
end
