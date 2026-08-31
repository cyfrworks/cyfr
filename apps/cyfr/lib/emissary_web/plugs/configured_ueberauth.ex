# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.ConfiguredUeberauth do
  @moduledoc """
  Ueberauth, but only for strategies that actually have web-callback
  credentials.

  GitHub and Google device-flow apps are configured with a client id (and,
  for Google, a token-exchange secret on `:cyfr`). Runtime still *may* list
  those names as Ueberauth providers when a client id is present. The
  GitHub strategy then `fetch_env!`s `Ueberauth.Strategy.Github.OAuth` on
  `GET /auth/github` and 500s if the web-callback secret was never set.

  Dropping unready strategies here means that request falls through to
  `AuthController.request/2` instead of crashing. Prism sign-in for
  GitHub/Google is device flow on `/login`; this plug only protects the
  leftover `/auth/:provider` path (and the OIDC strategy, which carries
  its credentials in the provider options and always stays ready).

  ## Why the routes are built per call

  `Ueberauth.init/1` reads `:ueberauth, Ueberauth` and returns the whole
  `{{path, method} => mfa}` table. Phoenix compiles a controller's plug
  pipeline with `Phoenix.plug_init_mode/0`, which is `:compile` everywhere
  except dev — and at compile time the only value present is
  `config/config.exs`'s `providers: []`, because the real list is assembled
  in `config/runtime.exs` at boot. So calling `Ueberauth.init/1` from
  `init/1` baked an empty table into the release: every `/auth/:provider`
  fell through to `AuthController.request/2`'s 404 and every callback to its
  400, which is byte-identical to the not-configured answer and therefore
  invisible to a test that only asserts the unconfigured case. Building here
  costs one `get_env` and a flat_map over two or three providers, on the
  sign-in path.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    Ueberauth.call(conn, opts |> Ueberauth.init() |> ready_routes())
  end

  defp ready_routes(routes) do
    Enum.filter(routes, fn {{_path, _method}, {module, _fun, _opts}} ->
      web_oauth_ready?(module)
    end)
  end

  # One owner for "is web OAuth configured?" — Sanctum.Auth.OAuth. This
  # plug carried its own copy (with trim semantics the owner lacked), so
  # the sign-in page and this route could disagree about the same env.
  defp web_oauth_ready?(Ueberauth.Strategy.Github),
    do: Sanctum.Auth.OAuth.web_configured?(:github)

  defp web_oauth_ready?(Ueberauth.Strategy.Google),
    do: Sanctum.Auth.OAuth.web_configured?(:google)

  defp web_oauth_ready?(_module), do: true
end
