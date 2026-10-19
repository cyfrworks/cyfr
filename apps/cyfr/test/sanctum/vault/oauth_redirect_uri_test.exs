# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Vault.OAuthRedirectUriTest do
  @moduledoc """
  Where the OAuth `redirect_uri` and the OpenID Connect callback get their
  origin.

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
             CyfrWeb.Endpoint.url() <> OAuthGrant.callback_path()
  end

  test "the path is still the one accessor" do
    assert OAuthGrant.callback_path() == "/auth/oauth/callback"
  end

  # The OpenID Connect sign-in's callback, the redirect URI the issuer is
  # told and the callback is checked against, is the home's own address
  # whatever the request's X-Forwarded-Proto and X-Forwarded-Host say:
  # `config/runtime.exs` names it in the strategy's options, and Ueberauth
  # builds it from the forwarded headers, which any client can send, only
  # when no option names it.
  describe "the OpenID Connect callback" do
    defmodule Strategy do
      @moduledoc false
      # Answers the callback Ueberauth resolves for the request phase.
      use Ueberauth.Strategy

      @impl Ueberauth.Strategy
      def handle_request!(conn) do
        send(self(), {:callback_url, callback_url(conn)})
        conn
      end
    end

    @root Path.expand("../../../../..", __DIR__)
    @home "https://cyfr.tail1a2b3c.ts.net"

    # The oidcc strategy's options as `config/runtime.exs` writes them for a
    # tailnet home signing in through an issuer.
    defp runtime_options do
      env = %{
        "CYFR_SECRET_KEY_BASE" => Base.encode64(:crypto.strong_rand_bytes(48)),
        "RELEASE_NAME" => "cyfr",
        "RELEASE_ROOT" => nil,
        "CYFR_DATABASE" => nil,
        "CYFR_REACH" => "tailnet",
        "CYFR_HOST" => "cyfr.tail1a2b3c.ts.net",
        "CYFR_TAILNET_NODE_ID" => "nAbc123XYZ1CNTRL",
        "CYFR_PUBLIC_URL" => @home,
        "CYFR_AUTH_PROVIDER" => "oidc",
        "CYFR_OIDC_ISSUER" => "https://auth.example.com",
        "CYFR_OIDC_CLIENT_ID" => "cyfr",
        "CYFR_OIDC_CLIENT_SECRET" => "secret"
      }

      previous = Map.new(env, fn {name, _value} -> {name, System.get_env(name)} end)
      on_exit(fn -> Enum.each(previous, &put_os_env/1) end)
      Enum.each(env, &put_os_env/1)

      config =
        Config.Reader.read!(Path.join(@root, "config/runtime.exs"),
          env: :prod,
          imports: :disabled
        )

      Enum.each(previous, &put_os_env/1)

      {Ueberauth.Strategy.Oidcc, options} = config[:ueberauth][Ueberauth][:providers][:oidcc]
      options
    end

    defp put_os_env({name, nil}), do: System.delete_env(name)
    defp put_os_env({name, value}), do: System.put_env(name, value)

    # The callback the request phase resolves for a request whose headers
    # claim another scheme, host and port, under `options`.
    defp resolved(options) do
      %{Plug.Test.conn(:get, "/auth/oidcc") | secret_key_base: String.duplicate("k", 64)}
      |> Plug.Conn.put_req_header("x-forwarded-proto", "http")
      |> Plug.Conn.put_req_header("x-forwarded-host", "evil.example:8443")
      |> Plug.Test.init_test_session(%{})
      |> Ueberauth.run_request("oidcc", {Strategy, options})

      assert_received {:callback_url, url}
      url
    end

    test "is the home's own address, whatever the forwarded headers say" do
      assert resolved(runtime_options()) == @home <> "/auth/oidcc/callback"
    end

    test "unnamed, Ueberauth would take it from the forwarded headers" do
      assert resolved(Keyword.delete(runtime_options(), :callback_url)) ==
               "http://evil.example:8443/auth/oidcc/callback"
    end
  end
end
