# SPDX-License-Identifier: FSL-1.1-MIT
# Copyright 2024 CYFR Inc. All Rights Reserved.

defmodule SanctumArx.Auth.OIDC do
  @moduledoc """
  OIDC authentication provider for Managed/Enterprise CYFR.

  Integrates with Ueberauth to support OAuth2/OIDC providers like GitHub, Google,
  and generic OIDC providers.

  ## Configuration

  Configure providers in `config/runtime.exs`:

      # GitHub OAuth
      export CYFR_GITHUB_CLIENT_ID=xxx
      export CYFR_GITHUB_CLIENT_SECRET=xxx

      # Google OAuth
      export CYFR_GOOGLE_CLIENT_ID=xxx
      export CYFR_GOOGLE_CLIENT_SECRET=xxx

      # Generic OIDC
      export CYFR_OIDC_ISSUER=https://auth.example.com
      export CYFR_OIDC_CLIENT_ID=xxx
      export CYFR_OIDC_CLIENT_SECRET=xxx

  ## Usage

  This provider is used by `EmissaryWeb.AuthController` to handle OAuth callbacks:

      # In AuthController.callback/2
      case SanctumArx.Auth.OIDC.authenticate(auth) do
        {:ok, user} ->
          {:ok, session} = Sanctum.Session.create(user)
          # Redirect with session token

        {:error, reason} ->
          # Handle error
      end

  """

  @behaviour Sanctum.Auth

  alias Sanctum.User
  alias Sanctum.Session

  @impl true
  @doc """
  Authenticate user from Ueberauth.Auth struct.

  Called after successful OAuth callback with the auth struct from Ueberauth.
  Creates a User struct from the OAuth provider's response.

  ## Examples

      # After successful OAuth callback
      auth = %Ueberauth.Auth{
        uid: "12345",
        info: %{email: "alice@example.com", nickname: "alice"},
        provider: :github
      }

      {:ok, user} = SanctumArx.Auth.OIDC.authenticate(auth)
      user.id
      #=> "12345"

  """
  def authenticate(%{__struct__: Ueberauth.Auth} = auth) do
    provider = auth.provider

    user = %User{
      id: to_string(auth.uid),
      email: get_email(auth),
      provider: to_string(provider),
      permissions: default_permissions()
    }

    Sanctum.Telemetry.auth_event(provider, :success)
    {:ok, user}
  end

  # Authenticate with session token
  def authenticate(%{token: token}) when is_binary(token) do
    case Session.get_user(token) do
      {:ok, _user} = result ->
        Sanctum.Telemetry.auth_event(:session, :success)
        result

      {:error, reason} = result ->
        Sanctum.Telemetry.auth_event(:session, :failure, %{reason: reason})
        result
    end
  end

  def authenticate(%{api_key: api_key}) when is_binary(api_key) do
    case Sanctum.ApiKey.validate(api_key) do
      {:ok, key_info} ->
        # Create a user from API key info
        user = %User{
          id: "api_key:#{key_info.name}",
          email: nil,
          provider: "api_key",
          permissions: permissions_from_scope(key_info.scope)
        }

        Sanctum.Telemetry.auth_event(:api_key, :success)
        {:ok, user}

      {:error, reason} ->
        Sanctum.Telemetry.auth_event(:api_key, :failure, %{reason: reason})
        {:error, reason}
    end
  end

  def authenticate(_params) do
    Sanctum.Telemetry.auth_event(:unknown, :failure, %{reason: :invalid_credentials})
    {:error, :invalid_credentials}
  end

  @impl true
  @doc """
  Get current user from Plug connection.

  Looks for authentication in the following order:
  1. Session token in conn.assigns[:session_token]
  2. Authorization header with Bearer token
  3. API key in X-API-Key header

  Returns nil if no valid authentication found.
  """
  def current_user(conn) do
    cond do
      # Check session token in assigns
      token = conn.assigns[:session_token] ->
        case Session.get_user(token) do
          {:ok, user} -> user
          _ -> nil
        end

      # Check Authorization header
      token = get_bearer_token(conn) ->
        case Session.get_user(token) do
          {:ok, user} -> user
          _ -> nil
        end

      # Check API key header
      api_key = get_api_key(conn) ->
        case authenticate(%{api_key: api_key}) do
          {:ok, user} -> user
          _ -> nil
        end

      true ->
        nil
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp get_email(auth) do
    cond do
      auth.info && is_map(auth.info) && Map.get(auth.info, :email) ->
        Map.get(auth.info, :email)

      auth.extra && is_map(auth.extra) && is_map(auth.extra[:raw_info]) && auth.extra[:raw_info]["email"] ->
        auth.extra[:raw_info]["email"]

      auth.extra && is_map(auth.extra) && is_map(Map.get(auth.extra, :raw_info)) && Map.get(auth.extra, :raw_info)["email"] ->
        Map.get(auth.extra, :raw_info)["email"]

      true ->
        nil
    end
  end

  defp get_bearer_token(%Plug.Conn{} = conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp get_bearer_token(_conn), do: nil

  defp get_api_key(%Plug.Conn{} = conn) do
    case Plug.Conn.get_req_header(conn, "x-api-key") do
      [key] -> key
      _ -> nil
    end
  end

  defp get_api_key(_conn), do: nil

  defp default_permissions do
    # Default permissions for OAuth users
    [:execute, :read]
  end

  defp permissions_from_scope(scope) when is_list(scope) do
    Enum.map(scope, fn s ->
      try do
        String.to_existing_atom(s)
      rescue
        ArgumentError -> String.to_atom(s)
      end
    end)
  end

  defp permissions_from_scope(_), do: []
end
