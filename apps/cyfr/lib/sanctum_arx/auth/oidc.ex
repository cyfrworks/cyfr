# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 Moonmoon69, Cyfrworks.com All Rights Reserved.

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

  require Logger

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
      #=> "github|https://github.com|12345"

  """
  def authenticate(%{__struct__: Ueberauth.Auth} = auth) do
    provider = auth.provider
    # Resolve issuer first — this is a deployment-configuration assertion
    # (raises on misconfigured OIDC wiring) and must fail fast regardless of
    # user-input state like email.
    iss = resolve_issuer(auth, provider)

    email = get_email(auth)
    extra = Map.get(auth, :extra) || %{}

    case Sanctum.Auth.EmailVerification.verify(provider, email, extra) do
      :ok ->
        user = %User{
          id: User.build_id(provider, iss, to_string(auth.uid)),
          email: email,
          provider: to_string(provider),
          permissions: default_permissions()
        }

        user = resolve_membership(user)

        Sanctum.Telemetry.auth_event(provider, :success)
        {:ok, user}

      {:error, reason} = err ->
        Sanctum.Telemetry.auth_event(provider, :failure, %{reason: reason})
        err
    end
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

      auth.extra && is_map(auth.extra) && is_map(auth.extra[:raw_info]) &&
          auth.extra[:raw_info]["email"] ->
        auth.extra[:raw_info]["email"]

      auth.extra && is_map(auth.extra) && is_map(Map.get(auth.extra, :raw_info)) &&
          Map.get(auth.extra, :raw_info)["email"] ->
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

  # Resolve org/project membership for the user.
  # In Core mode, returns user unchanged (single-tenant sentinel).
  # In Arx mode, looks up memberships and auto-assigns if exactly one accepted org exists.
  # Multiple orgs: picks first accepted; an org picker UI is a future enhancement.
  # Zero memberships: user has no org access yet (handled downstream).
  defp resolve_membership(user) do
    if Application.get_env(:cyfr, :edition, :core) != :arx do
      user
    else
      case SanctumArx.Memberships.list_by_user(user.id) do
        memberships when is_list(memberships) and memberships != [] ->
          # Prefer accepted memberships; fall back to any membership
          membership =
            Enum.find(memberships, List.first(memberships), fn m ->
              m.accepted_at != nil
            end)

          project_id = resolve_default_project(membership.org_id)
          %{user | org_id: membership.org_id, project_id: project_id}

        [] ->
          # No memberships — leave org_id nil (normal for new users)
          user

        {:error, reason} ->
          Logger.error(
            "[OIDC] Failed to resolve membership for user #{user.id}: #{inspect(reason)}"
          )

          user
      end
    end
  end

  # Resolve the default project for an org. Returns the first project's ID
  # or "default" if no projects exist yet.
  defp resolve_default_project(org_id) do
    case SanctumArx.Projects.list_by_org(org_id, limit: 1) do
      [project | _] ->
        project.id

      [] ->
        "default"

      {:error, reason} ->
        Logger.error(
          "[OIDC] Failed to resolve default project for org #{org_id}: #{inspect(reason)}"
        )

        "default"
    end
  end

  defp default_permissions do
    # Default permissions for OAuth users
    [:execute, :read]
  end

  defp permissions_from_scope(scope) when is_list(scope) do
    scope
    |> Enum.map(&Sanctum.Atoms.safe_to_permission_atom/1)
    |> Enum.filter(&is_atom/1)
  end

  defp permissions_from_scope(_), do: []

  # Lane 1 (direct GitHub/Google OAuth): hardcoded provider issuer.
  # Lane 2 (enterprise OIDC via ueberauth_oidcc): pull `iss` from the id_token
  # or the strategy's urls.oidc_issuer field.
  defp resolve_issuer(_auth, provider) when provider in [:github, :google] do
    User.provider_iss(provider)
  end

  defp resolve_issuer(auth, _provider) do
    iss =
      cond do
        is_map(auth.info) and is_map(auth.info.urls) and
            is_binary(auth.info.urls[:oidc_issuer]) ->
          auth.info.urls[:oidc_issuer]

        is_map(auth.extra) and is_map(auth.extra.raw_info) and
            is_map(auth.extra.raw_info["id_token"]) and
            is_binary(auth.extra.raw_info["id_token"]["iss"]) ->
          auth.extra.raw_info["id_token"]["iss"]

        true ->
          # A correctly-configured ueberauth_oidcc strategy always populates
          # one of the two sources above (id_tokens carry `iss` per the OIDC
          # spec). Silently falling back to a sentinel would produce an id of
          # the form "oidcc|<sentinel>|<sub>" and collide across tenants.
          raise "Arx OIDC misconfiguration: no issuer on Ueberauth.Auth " <>
                  "(auth.info.urls.oidc_issuer and auth.extra.raw_info.id_token.iss both absent)"
      end

    # Reserved for direct-provider strategies (ueberauth_github, ueberauth_google).
    # Wiring ueberauth_oidcc against these would produce id = "oidcc|https://github.com|..."
    # on Arx while Core produces id = "github|https://github.com|..." — same human,
    # different id, cross-edition namespace claims break.
    if iss in ["https://github.com", "https://accounts.google.com"] do
      raise "Arx compliance violation: ueberauth_oidcc wired against a reserved issuer " <>
              "(#{iss}); use ueberauth_github or ueberauth_google directly."
    end

    iss
  end
end
