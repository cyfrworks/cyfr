# SPDX-License-Identifier: Apache-2.0
# Copyright 2024 CYFR Contributors

defmodule Sanctum.Auth.SimpleOAuth do
  @moduledoc """
  Simple OAuth authentication for Sanctum.

  Supports GitHub and Google OAuth via Ueberauth for single-user scenarios.
  Authenticated users receive full permissions (`:*`).

  ## Configuration

  Set as the auth provider in config:

      config :sanctum, auth_provider: Sanctum.Auth.SimpleOAuth

  Configure OAuth credentials via environment variables:
  - `CYFR_GITHUB_CLIENT_ID` / `CYFR_GITHUB_CLIENT_SECRET` for GitHub
  - `CYFR_GOOGLE_CLIENT_ID` / `CYFR_GOOGLE_CLIENT_SECRET` for Google

  Optionally restrict to specific user(s):
  - `CYFR_ALLOWED_USER` - comma-separated list of allowed emails

  ## Supported Providers

  - `:github` - GitHub OAuth
  - `:google` - Google OAuth

  Enterprise providers (Okta, Azure AD, custom OIDC) require Sanctum Arx.
  """

  @behaviour Sanctum.Auth

  alias Sanctum.User
  alias Sanctum.Session
  alias Sanctum.Telemetry

  @supported_providers [:github, :google]

  @impl true
  def authenticate(%{provider: provider} = params) when provider in @supported_providers do
    with :ok <- check_provider_configured(provider),
         {:ok, user_info} <- extract_user_info(params),
         :ok <- check_allowed_user(user_info.email) do
      user = %User{
        id: user_info.id,
        email: user_info.email,
        provider: to_string(provider),
        permissions: [:*]
      }

      Telemetry.auth_event(provider, :success, %{email: user_info.email})
      {:ok, user}
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
    case Session.get_user(token) do
      {:ok, user} ->
        Telemetry.auth_event(:session, :success, %{user_id: user.id})
        {:ok, user}

      {:error, reason} ->
        Telemetry.auth_event(:session, :failure, %{reason: reason})
        {:error, reason}
    end
  end

  def authenticate(_params) do
    Telemetry.auth_event(:simple_oauth, :failure, %{reason: :invalid_params})
    {:error, :invalid_params}
  end

  @impl true
  def current_user(conn) do
    case get_session_token(conn) do
      nil -> nil
      token ->
        case Session.get_user(token) do
          {:ok, user} -> user
          {:error, _} -> nil
        end
    end
  end

  @doc """
  Create a session for an authenticated user.

  Call this after successful OAuth callback to create a session token.

  ## Examples

      {:ok, session} = SimpleOAuth.create_session(user)
      session.token
      #=> "abc123..."

  """
  @spec create_session(User.t()) :: {:ok, Session.session()} | {:error, term()}
  def create_session(%User{} = user) do
    Session.create(user)
  end

  @doc """
  List supported OAuth providers.

  ## Examples

      SimpleOAuth.supported_providers()
      #=> [:github, :google]

  """
  @spec supported_providers() :: [atom()]
  def supported_providers, do: @supported_providers

  @doc """
  Check if a provider is supported.

  ## Examples

      SimpleOAuth.supported_provider?(:github)
      #=> true

      SimpleOAuth.supported_provider?(:okta)
      #=> false

  """
  @spec supported_provider?(atom()) :: boolean()
  def supported_provider?(provider), do: provider in @supported_providers

  @doc """
  Get list of configured providers based on environment.

  Returns only providers that have credentials configured.
  """
  @spec configured_providers() :: [atom()]
  def configured_providers do
    @supported_providers
    |> Enum.filter(&provider_configured?/1)
  end

  @doc """
  Check if any OAuth provider is configured.
  """
  @spec any_provider_configured?() :: boolean()
  def any_provider_configured? do
    configured_providers() != []
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

  defp provider_configured?(:github) do
    github_config() != nil
  end

  defp provider_configured?(:google) do
    google_config() != nil
  end

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

  defp extract_user_info(%{provider: :github, uid: uid, info: info}) do
    {:ok, %{
      id: to_string(uid),
      email: info.email || info[:email]
    }}
  end

  defp extract_user_info(%{provider: :google, uid: uid, info: info}) do
    {:ok, %{
      id: to_string(uid),
      email: info.email || info[:email]
    }}
  end

  defp extract_user_info(%{provider: _provider, uid: uid, email: email}) do
    {:ok, %{
      id: to_string(uid),
      email: email
    }}
  end

  defp extract_user_info(_), do: {:error, :invalid_auth_data}

  defp check_allowed_user(email) do
    case allowed_users() do
      nil -> :ok
      [] -> :ok
      allowed when is_list(allowed) ->
        if email in allowed do
          :ok
        else
          {:error, :user_not_allowed}
        end
    end
  end

  defp allowed_users do
    case Application.get_env(:sanctum, :allowed_users) do
      nil -> nil
      users when is_list(users) -> users
      users when is_binary(users) ->
        users
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp get_session_token(conn) do
    # Check Authorization header first
    case get_auth_header(conn) do
      {:ok, token} -> token
      :error ->
        # Fall back to session cookie
        get_session_cookie(conn)
    end
  end

  defp get_auth_header(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> :error
    end
  end

  defp get_session_cookie(conn) do
    case conn.private[:plug_session] do
      %{"cyfr_session_token" => token} -> token
      _ -> nil
    end
  end
end
