# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.ConfiguredUeberauthTest do
  @moduledoc """
  GitHub device-flow apps ship a client id and no secret. If that still
  registers Ueberauth's GitHub strategy, `GET /auth/github` raises
  ArgumentError inside `Ueberauth.Strategy.Github.OAuth.client/1`. This
  plug must drop the strategy when the web-callback credentials are
  absent so the request never 500s.
  """
  use ExUnit.Case, async: false

  alias EmissaryWeb.Plugs.ConfiguredUeberauth

  setup do
    original_providers = Application.get_env(:ueberauth, Ueberauth)
    original_github = Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)

    on_exit(fn ->
      if original_providers,
        do: Application.put_env(:ueberauth, Ueberauth, original_providers),
        else: Application.delete_env(:ueberauth, Ueberauth)

      if original_github,
        do: Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth, original_github),
        else: Application.delete_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)
    end)

    :ok
  end

  test "GET /auth/github with a GitHub strategy and no OAuth secret does not raise" do
    Application.put_env(:ueberauth, Ueberauth,
      providers: [{:github, {Ueberauth.Strategy.Github, [default_scope: "user:email"]}}]
    )

    Application.delete_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)

    conn = Plug.Test.conn(:get, "/auth/github")
    routes = ConfiguredUeberauth.init([])

    conn = ConfiguredUeberauth.call(conn, routes)

    refute conn.halted
    refute conn.status == 500
  end
end
