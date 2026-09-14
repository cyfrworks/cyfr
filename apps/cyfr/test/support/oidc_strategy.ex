# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.OidcStrategy do
  @moduledoc """
  A stand-in OIDC issuer, as an Ueberauth strategy. The request phase sends
  the browser straight back to the callback with the `sub` and `email` it
  was asked for; the callback names that person with a verified email.
  Ueberauth's state check runs between the two, so a trace through
  `/auth/oidcc` crosses the plug, its cookie and the controller as a real
  issuer's would.
  """

  use Ueberauth.Strategy

  alias Ueberauth.Auth.{Credentials, Extra, Info}

  @impl Ueberauth.Strategy
  def handle_request!(conn) do
    identity = [sub: conn.params["sub"], email: conn.params["email"]]
    redirect!(conn, callback_url(conn, with_state_param(identity, conn)))
  end

  @impl Ueberauth.Strategy
  def handle_callback!(conn), do: conn

  @impl Ueberauth.Strategy
  def uid(conn), do: conn.params["sub"]

  @impl Ueberauth.Strategy
  def info(conn), do: %Info{email: conn.params["email"], name: "Trace"}

  @impl Ueberauth.Strategy
  def credentials(_conn), do: %Credentials{token: "oidc-access", expires: false}

  @impl Ueberauth.Strategy
  def extra(conn) do
    %Extra{
      raw_info: %{userinfo: %{"email" => conn.params["email"], "email_verified" => true}}
    }
  end
end
