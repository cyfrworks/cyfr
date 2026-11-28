# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Vault.OAuthRedirectUriTest do
  @moduledoc """
  Where the OAuth `redirect_uri` gets its origin (`Sanctum.oauth_return_address/0`).

  A server with a browser address registers that address, scheme
  included. One with none registers `http://localhost:<port>`, on its
  private address's port: a provider accepts that over plain HTTP and
  likely refuses the private name, and the callback completes on the
  loopback listener with its single-use state alone.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Vault.OAuthGrant

  test "a server with a browser address registers that address, with its scheme" do
    Prima.Test.Env.put_app_env(:sanctum, :browser_address, "https://cyfr.example.com")

    assert OAuthGrant.redirect_uri() == "https://cyfr.example.com" <> OAuthGrant.callback_path()
  end

  test "a server with no browser address registers localhost on its private address's port" do
    Prima.Test.Env.put_app_env(:sanctum, :browser_address, nil)
    %URI{port: port} = URI.parse(Sanctum.private_address())

    assert OAuthGrant.redirect_uri() ==
             "http://localhost:#{port}" <> OAuthGrant.callback_path()

    # The private name itself is never the return address.
    refute OAuthGrant.redirect_uri() =~ Sanctum.private_address()
  end

  test "the path is still the one accessor" do
    assert OAuthGrant.callback_path() == "/auth/oauth/callback"
  end
end
