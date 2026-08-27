# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.OAuth do
  @moduledoc """
  Built-in OAuth authentication for Sanctum.

  Supports GitHub and Google via Ueberauth. Authenticated users receive
  full permissions (`:*`) — the default for personal deployments.

  ## Configuration

  Set as the auth provider in config:

      config :cyfr, auth_provider: Sanctum.Auth.OAuth

  Configure OAuth credentials via environment variables:
  - `CYFR_GITHUB_CLIENT_ID` / `CYFR_GITHUB_CLIENT_SECRET` for GitHub
  - `CYFR_GOOGLE_CLIENT_ID` / `CYFR_GOOGLE_CLIENT_SECRET` for Google

  This module proves who someone is; whether they may sign in to this server
  is the door's decision (`Sanctum.Door`), taken by the two sign-in paths
  before any session is minted.

  ## Supported Providers

  - `:github` - GitHub OAuth
  - `:google` - Google OAuth

  Other providers (Okta, Azure AD, custom OIDC) require the
  `Sanctum.Auth.OIDC` provider instead.
  """

  @behaviour Sanctum.Auth

  alias Sanctum.Auth.Identity
  alias Sanctum.Context
  alias Sanctum.Session
  alias Sanctum.Telemetry

  @supported_providers [:github, :google]

  @impl true
  def authenticate(%{provider: provider} = params) when provider in @supported_providers do
    with :ok <- check_provider_configured(provider),
         {:ok, user_info} <- extract_user_info(params) do
      ctx =
        Context.build(
          user_id: Identity.builtin_user_id(provider, user_info.id),
          email: user_info.email,
          provider: to_string(provider),
          # Start athanor-less; resolve_into/2 fills the athanor from memberships.
          athanor_id: nil,
          permissions: [:*]
        )

      # Resolve the caller's scope/athanor from their memberships.
      ctx = Sanctum.Tenancy.resolve_into(ctx, force: true)

      Telemetry.auth_event(provider, :success, %{email: user_info.email})
      {:ok, ctx}
    else
      {:error, reason} = error ->
        Telemetry.auth_event(provider, :failure, %{reason: reason})
        error
    end
  end

  def authenticate(%{provider: provider}) do
    Telemetry.auth_event(provider, :failure, %{reason: :unsupported_provider})
    {:error, {:unsupported_provider, provider}}
  end

  def authenticate(%{token: token}) when is_binary(token) do
    case Session.load(token, surface: :console) do
      {:ok, ctx} ->
        Telemetry.auth_event(:session, :success, %{user_id: ctx.user_id})
        {:ok, ctx}

      {:error, reason} ->
        Telemetry.auth_event(:session, :failure, %{reason: reason})
        {:error, reason}
    end
  end

  def authenticate(_params) do
    Telemetry.auth_event(:oauth, :failure, %{reason: :invalid_params})
    {:error, :invalid_params}
  end

  @impl true
  def current_user(conn) do
    case get_session_token(conn) do
      nil ->
        nil

      token ->
        case Session.load(token, surface: :console) do
          {:ok, ctx} -> ctx
          {:error, _} -> nil
        end
    end
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp check_provider_configured(provider) do
    if provider_configured?(provider) do
      :ok
    else
      {:error, {:provider_not_configured, provider}}
    end
  end

  defp provider_configured?(:github), do: github_config() != nil
  defp provider_configured?(:google), do: google_config() != nil
  defp provider_configured?(_), do: false

  defp github_config do
    case Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth) do
      config when is_list(config) ->
        if config[:client_id] && config[:client_secret], do: config, else: nil

      _ ->
        nil
    end
  end

  defp google_config do
    case Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth) do
      config when is_list(config) ->
        if config[:client_id] && config[:client_secret], do: config, else: nil

      _ ->
        nil
    end
  end

  defp extract_user_info(%{provider: provider, uid: uid, info: info} = auth)
       when provider in [:github, :google] do
    email = info.email || info[:email]
    extra = Map.get(auth, :extra) || %{}

    case Sanctum.Auth.EmailVerification.verify(provider, email, extra) do
      :ok -> {:ok, %{id: to_string(uid), email: email}}
      {:error, _} = err -> err
    end
  end

  defp extract_user_info(%{provider: provider, uid: uid, email: email} = auth) do
    # Email verification must run on EVERY auth shape, not only the
    # github/google `info`-bearing one — otherwise a struct that matches
    # here would bypass the check entirely.
    extra = Map.get(auth, :extra) || %{}

    case Sanctum.Auth.EmailVerification.verify(provider, email, extra) do
      :ok -> {:ok, %{id: to_string(uid), email: email}}
      {:error, _} = err -> err
    end
  end

  defp extract_user_info(_), do: {:error, :invalid_auth_data}

  # `Authorization: Bearer` and nothing else. The cookie fallback that used
  # to sit here read `"cyfr_session_token"`, a key nothing has ever written —
  # every writer and reader uses `:sanctum_session_token` — so it always
  # returned nil. Restoring it under the real key would hand `POST /mcp`,
  # which carries no CSRF protection, an ambient browser credential.
  defp get_session_token(conn), do: Sanctum.BearerToken.read(conn)
end
