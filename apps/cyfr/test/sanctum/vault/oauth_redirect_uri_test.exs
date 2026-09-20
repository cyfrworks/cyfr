# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Vault.OAuthRedirectUriTest do
  @moduledoc """
  Where the OAuth `redirect_uri` gets its origin.

  Checks that OAuth redirect URIs use the configured public origin, including its scheme.

  `CYFR_PUBLIC_URL` is the address this instance is reachable at from
  outside — scheme included — and is what the operator is told to set.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Vault.OAuthGrant

  setup do
    original = Application.get_env(:sanctum, :public_url)

    on_exit(fn ->
      if original,
        do: Application.put_env(:sanctum, :public_url, original),
        else: Application.delete_env(:sanctum, :public_url)
    end)

    :ok
  end

  test "the public origin carries the scheme the deployment actually serves" do
    Application.put_env(:sanctum, :public_url, "https://cyfr.example.com")

    assert OAuthGrant.redirect_uri() == "https://cyfr.example.com" <> OAuthGrant.callback_path()
  end

  test "a trailing slash does not double up" do
    Application.put_env(:sanctum, :public_url, "https://cyfr.example.com/")

    assert OAuthGrant.redirect_uri() == "https://cyfr.example.com" <> OAuthGrant.callback_path()
  end

  test "with no public origin configured it falls back to the endpoint" do
    # Local and dev deployments never set it, and there `http://host:port` is
    # exactly right. `:sanctum, :fallback_origin` is configured per
    # environment beside the endpoint's own port, and this assertion is
    # what holds the two together.
    Application.delete_env(:sanctum, :public_url)

    assert OAuthGrant.redirect_uri() ==
             EmissaryWeb.Endpoint.url() <> OAuthGrant.callback_path()
  end

  test "the path is still the one accessor" do
    assert OAuthGrant.callback_path() == "/auth/oauth/callback"
  end
end
