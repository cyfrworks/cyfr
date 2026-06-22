# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.SessionTool do
  @moduledoc """
  Session tool handlers for the Sanctum MCP provider — login, logout,
  whoami, and device-flow OAuth.

  Extracted from `Sanctum.MCP`; behaviour preserved exactly.
  """

  require Logger

  alias Sanctum.Context

  def handle(_ctx, %{"action" => "ping"}), do: {:ok, %{status: "ok"}}

  def handle(%Context{authenticated: false}, %{"action" => "whoami"}) do
    {:error, "Not authenticated. Run 'cyfr login' to sign in."}
  end

  def handle(%Context{} = ctx, %{"action" => "whoami"}) do
    # Local identity only. Registry identity (push tokens, personal namespace,
    # memberships) lives on the `registry.whoami` action under Compendium MCP
    # so the auth sliver stays Compendium-free. Clients compose the two.
    {:ok,
     %{
       user_id: ctx.user_id,
       email: derive_email(ctx),
       provider: derive_provider(ctx)
     }}
  end

  def handle(%Context{} = _ctx, %{"action" => "login"}) do
    # Login requires browser redirect in Sanctum
    {:ok, %{message: "Login requires browser authentication", redirect: "/auth/login"}}
  end

  def handle(%Context{} = _ctx, %{"action" => "logout"}) do
    # Logout is a no-op in Sanctum (stateless)
    {:ok, %{message: "Logged out successfully"}}
  end

  def handle(%Context{} = _ctx, %{"action" => "device_init"} = args) do
    if device_flow_enabled?() do
      provider = Map.get(args, "provider", "github")

      case Sanctum.Auth.DeviceFlow.init_device_flow(provider) do
        {:ok, device_info} ->
          {:ok,
           %{
             device_code: device_info.device_code,
             user_code: device_info.user_code,
             verification_uri: device_info.verification_uri,
             expires_in: device_info.expires_in,
             interval: device_info.interval
           }}

        {:error, {:client_id_not_configured, provider}} ->
          {:error,
           "#{provider} client ID not configured. Set CYFR_#{String.upcase(to_string(provider))}_CLIENT_ID"}

        {:error, {:device_code_error, code}} ->
          # Provider returned a structured error body (e.g. Google's
          # "unsupported_grant_type" when the OAuth client isn't a
          # "TV & Limited Input" type, or "invalid_client" for a bad id).
          Logger.error("[Sanctum.MCP] Device flow init rejected by provider: #{inspect(code)}")

          {:error,
           "Device flow rejected by provider: #{code}. " <>
             "For Google, the OAuth client must be type \"TV and Limited Input devices\"."}

        {:error, {:device_code_request_failed, reason}} ->
          Logger.error("[Sanctum.MCP] Device flow network error: #{inspect(reason)}")
          {:error, "Device flow request failed: #{inspect(reason)}"}
      end
    else
      {:error, device_flow_disabled_message()}
    end
  end

  def handle(
        %Context{} = _ctx,
        %{"action" => "device_poll", "device_code" => device_code} = args
      ) do
    if device_flow_enabled?() do
      provider = Map.get(args, "provider", "github")

      case Sanctum.Auth.DeviceFlow.poll_for_session(provider, device_code) do
        {:ok, result} ->
          {:ok, result}

        {:error, {:client_id_not_configured, provider}} ->
          {:error,
           "#{provider} client ID not configured. Set CYFR_#{String.upcase(to_string(provider))}_CLIENT_ID"}

        {:error, reason} when is_binary(reason) ->
          {:error, reason}

        {:error, {:token_error, code}} ->
          # Provider returned a structured error on the token exchange —
          # e.g. Google's "invalid_request" when client_secret is missing,
          # or "invalid_grant" for an expired device code.
          Logger.error("[Sanctum.MCP] Token exchange rejected by provider: #{inspect(code)}")
          {:error, "Token exchange rejected by provider: #{code}"}

        {:error, {:token_request_failed, reason}} ->
          Logger.error("[Sanctum.MCP] Token exchange network error: #{inspect(reason)}")
          {:error, "Token exchange failed: #{inspect(reason)}"}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to poll for token: #{inspect(reason)}")
          {:error, "Failed to poll for token: #{inspect(reason)}"}
      end
    else
      {:error, device_flow_disabled_message()}
    end
  end

  def handle(_ctx, %{"action" => "device_poll"}) do
    {:error, "Missing required argument: device_code"}
  end

  def handle(_ctx, _args) do
    {:error, "Invalid session action. Use: login, logout, whoami, device_init, or device_poll"}
  end

  # session.whoami helpers: derive display fields from the Context without
  # reaching into Compendium. user_id is the pipe-delimited identifier and
  # email is not carried in Context today; we best-effort reverse-engineer
  # display info from user_id when Sanctum.Session didn't persist an email
  # alongside.
  defp derive_email(%Context{email: email}) when is_binary(email) and email != "", do: email
  defp derive_email(_), do: nil

  defp derive_provider(%Context{user_id: user_id}) when is_binary(user_id) do
    case String.split(user_id, "|", parts: 3) do
      [provider, _iss, _sub] -> provider
      _ -> nil
    end
  end

  defp derive_provider(_), do: nil

  # ============================================================================
  # Auth-provider-gated helpers (shared across session handlers)
  # ============================================================================

  # Device-flow CLI auth requires the default OAuth provider. Deployments that
  # pin `:auth_provider` to a configured OIDC provider use the web OIDC flow at
  # `/auth/<provider>` — device_init/device_poll are gated off in that case.
  # Installs with `:auth_provider = nil` are treated as the default (OAuth)
  # for this check,
  # so local dev without explicit config still works.
  defp device_flow_enabled? do
    case Application.get_env(:cyfr, :auth_provider) do
      nil -> true
      Sanctum.Auth.OAuth -> true
      _ -> false
    end
  end

  defp device_flow_disabled_message do
    "Device-flow CLI auth requires the GitHub/Google OAuth provider. " <>
      "This deployment is configured with a different auth provider; " <>
      "use the web flow at `/auth/<provider>` instead."
  end
end
