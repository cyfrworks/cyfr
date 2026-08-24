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
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: Ueberauth.init(opts)

  @impl Plug
  def call(conn, routes), do: Ueberauth.call(conn, ready_routes(routes))

  defp ready_routes(routes) do
    Enum.filter(routes, fn {{_path, _method}, {module, _fun, _opts}} ->
      web_oauth_ready?(module)
    end)
  end

  defp web_oauth_ready?(Ueberauth.Strategy.Github),
    do: oauth_configured?(Ueberauth.Strategy.Github.OAuth)

  defp web_oauth_ready?(Ueberauth.Strategy.Google),
    do: oauth_configured?(Ueberauth.Strategy.Google.OAuth)

  defp web_oauth_ready?(_module), do: true

  defp oauth_configured?(key) do
    case Application.get_env(:ueberauth, key) do
      config when is_list(config) ->
        present?(config[:client_id]) and present?(config[:client_secret])

      _ ->
        false
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
