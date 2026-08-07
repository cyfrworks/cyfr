# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.OIDC do
  @moduledoc """
  OIDC authentication provider for `Sanctum.Auth`.

  Integrates with Ueberauth to support OAuth2/OIDC providers — GitHub and
  Google directly, plus generic OIDC issuers via `ueberauth_oidcc` (used
  by deployments that federate against an enterprise IdP).

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
      case Sanctum.Auth.OIDC.authenticate(auth) do
        {:ok, user} ->
          {:ok, session} = Sanctum.Session.create(user)
          # Redirect with session token

        {:error, reason} ->
          # Handle error
      end

  """

  @behaviour Sanctum.Auth

  alias Sanctum.Context
  alias Sanctum.Session

  @impl true
  @doc """
  Authenticate from Ueberauth.Auth struct.

  Called after successful OAuth callback with the auth struct from Ueberauth.
  Builds a `Sanctum.Context` from the OAuth provider's response and resolves
  org membership.

  ## Examples

      auth = %Ueberauth.Auth{
        uid: "12345",
        info: %{email: "alice@example.com", nickname: "alice"},
        provider: :github
      }

      {:ok, ctx} = Sanctum.Auth.OIDC.authenticate(auth)
      ctx.user_id
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
        user_id = Context.build_id(provider, iss, to_string(auth.uid))

        ctx =
          Context.build(
            user_id: user_id,
            email: email,
            provider: to_string(provider),
            namespace: Sanctum.Namespace.lookup(user_id),
            # Start org-less; resolve_into/2 fills the org from memberships.
            org_id: nil,
            permissions: default_permissions()
          )

        # Resolve the caller's scope/org/project from their memberships.
        ctx = Sanctum.Tenancy.resolve_into(ctx, force: true)

        Sanctum.Telemetry.auth_event(provider, :success)
        {:ok, ctx}

      {:error, reason} = err ->
        Sanctum.Telemetry.auth_event(provider, :failure, %{reason: reason})
        err
    end
  end

  # Authenticate with session token
  def authenticate(%{token: token}) when is_binary(token) do
    case Session.load(token) do
      {:ok, _ctx} = result ->
        Sanctum.Telemetry.auth_event(:session, :success)
        result

      {:error, reason} = result ->
        Sanctum.Telemetry.auth_event(:session, :failure, %{reason: reason})
        result
    end
  end

  def authenticate(%{api_key: api_key}) when is_binary(api_key) do
    case Sanctum.ApiKey.validate(api_key) do
      {:ok, metadata} ->
        # Single source of truth: the SAME tenant-bound context the
        # production MCP-session plug builds (org_id/project_id read from the
        # key row, namespace resolved, api_key_id for audit) — not a bespoke
        # builder that drops the tenant. In platform mode apply the same
        # require_org gate so an org-less key context never authenticates
        # (no API-key context without a resolved tenant).
        ctx = Sanctum.ApiKey.context_from_metadata(metadata)

        case gate_api_key_tenant(ctx) do
          :ok ->
            Sanctum.Telemetry.auth_event(:api_key, :success)
            {:ok, ctx}

          {:error, reason} ->
            Sanctum.Telemetry.auth_event(:api_key, :failure, %{reason: reason})
            {:error, reason}
        end

      {:error, reason} ->
        Sanctum.Telemetry.auth_event(:api_key, :failure, %{reason: reason})
        {:error, reason}
    end
  end

  def authenticate(_params) do
    Sanctum.Telemetry.auth_event(:unknown, :failure, %{reason: :invalid_credentials})
    {:error, :invalid_credentials}
  end

  # An API-key context must carry a resolved tenant. Single chokepoint —
  # `Sanctum.Context.tenant_ok/1` owns the :platform bypass and the
  # configured-policy delegation (the default policy returns :ok).
  defp gate_api_key_tenant(ctx), do: Sanctum.Context.tenant_ok(ctx)

  @impl true
  @doc """
  Get current Context from Plug connection.

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
        case Session.load(token) do
          {:ok, ctx} -> ctx
          _ -> nil
        end

      # Check Authorization header
      token = get_bearer_token(conn) ->
        case Session.load(token) do
          {:ok, ctx} -> ctx
          _ -> nil
        end

      # Check API key header
      api_key = get_api_key(conn) ->
        case authenticate(%{api_key: api_key}) do
          {:ok, ctx} -> ctx
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

  defp default_permissions do
    # Anyone who passes the operator's configured OIDC provider is fully
    # trusted, matching the OAuth/DeviceFlow providers — the console is a
    # single-operator trust boundary, and consent has its own dedicated
    # non-wildcard authorization path. (The previous [:execute, :read]
    # granted :read, an atom nothing recognizes.)
    [:*]
  end

  # Direct GitHub/Google OAuth strategies hardcode the provider's issuer.
  # The generic-OIDC path (`ueberauth_oidcc`) pulls `iss` from the id_token
  # or the strategy's `urls.oidc_issuer` field.
  defp resolve_issuer(_auth, provider) when provider in [:github, :google] do
    Context.provider_iss(provider)
  end

  defp resolve_issuer(_auth, _provider) do
    # Generic OIDC: the canonical issuer is the operator-configured value,
    # pinned at boot from CYFR_OIDC_ISSUER (config/runtime.exs). Reading it here
    # — rather than digging it out of ueberauth_oidcc's Auth struct — keeps the
    # user-id issuer deterministic and reads the SAME source as the boot
    # reserved-host check (Cyfr.Application.validate_oidc_issuer_config!/0).
    iss =
      case Application.get_env(:cyfr, :oidc_issuer) do
        issuer when is_binary(issuer) and issuer != "" ->
          issuer

        _ ->
          raise "OIDC misconfiguration: :cyfr, :oidc_issuer is not set " <>
                  "(CYFR_OIDC_ISSUER was absent at boot)."
      end

    # The canonical id format is "<provider>|<iss>|<sub>"; wiring ueberauth_oidcc
    # against a direct-provider host (github.com / accounts.google.com) would
    # produce "oidc|https://github.com|..." instead of the "github|..." form,
    # silently splitting one human into two ids across deployments. Compare on
    # the normalized host so a trailing slash, port, or scheme variant cannot
    # slip past.
    if Sanctum.Context.normalized_issuer_host(iss) in ["github.com", "accounts.google.com"] do
      raise "OIDC issuer policy violation: ueberauth_oidcc wired against a reserved issuer " <>
              "(#{iss}); use ueberauth_github or ueberauth_google directly."
    end

    iss
  end
end
