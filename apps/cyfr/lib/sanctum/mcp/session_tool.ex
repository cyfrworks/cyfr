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

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.MCP assembles its roster from these.
  def definition do
    %{
      name: "session",
      title: "Session Management",
      description:
        "Manage user sessions — login, logout, get local identity, or run device-flow OAuth. " <>
          "Registry identity (push tokens, namespaces) is a separate `registry` tool under Compendium.",
      annotations: %{
        readOnlyHint: false,
        destructiveHint: false,
        # Anonymous-allowed: `whoami` and the device-flow login actions need
        # to work before a credential exists, and `logout` only ever
        # destroys the caller's own session.
        actions: %{
          "login" => %{kind: :write, planes: [:external], auth: :anonymous},
          "logout" => %{kind: :write, planes: [:external], auth: :anonymous},
          "whoami" => %{kind: :read, planes: [:external], auth: :anonymous},
          "device_init" => %{kind: :write, planes: [:external], auth: :anonymous},
          "device_poll" => %{kind: :write, planes: [:external], auth: :anonymous},
          # Point the session at another athanor the caller may work in.
          "use" => %{kind: :write, planes: [:external]}
        }
      },
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => [
              "login",
              "logout",
              "whoami",
              "device_init",
              "device_poll",
              "use"
            ],
            "description" =>
              "Action to perform. `device_init`/`device_poll` require the " <>
                "default OAuth provider (`auth_provider = Sanctum.Auth.OAuth`); " <>
                "deployments with a configured OIDC auth provider authenticate " <>
                "via the web OIDC flow at " <>
                "`/auth/<provider>`. Push-token identity (cyfr.run) lives on the " <>
                "separate `registry` tool under Compendium — see its " <>
                "`probe` and `claim_personal` actions."
          },
          "provider" => %{
            "type" => "string",
            "enum" => ["github", "google"],
            "description" => "OAuth provider for device flow"
          },
          "device_code" => %{
            "type" => "string",
            "description" => "Device code from device_init (for device_poll action)"
          },
          "athanor" => %{
            "type" => "string",
            "description" =>
              "For `use`: the athanor to work in — an id, a group slug, or @<namespace>"
          }
        },
        "required" => ["action"]
      }
    }
  end

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
       provider: derive_provider(ctx),
       athanor_id: ctx.athanor_id,
       platform_admin: ctx.platform_admin
     }}
  end

  # Point the session at another athanor the caller may work in — what a
  # non-browser client does instead of following a `/a/<athanor>` URL.
  def handle(%Context{} = ctx, %{"action" => "use", "athanor" => athanor})
      when is_binary(athanor) do
    with {:ok, resolved} <- resolve_athanor(athanor),
         {:ok, focused} <- Sanctum.Session.use_athanor(ctx, resolved.id) do
      {:ok, %{athanor: Sanctum.MCP.AthanorTool.render(resolved), scope: focused.scope}}
    else
      {:error, :not_member} ->
        {:error, "Not a member of that athanor"}

      {:error, :archived} ->
        {:error, "That athanor is archived"}

      {:error, :not_found} ->
        {:error, "Athanor not found"}

      {:error, :no_session} ->
        {:error, "session.use needs a session — a key is bound to one athanor"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, _} ->
        {:error, "Failed to switch athanor"}
    end
  end

  def handle(_ctx, %{"action" => "use"}), do: {:error, "Missing required argument: athanor"}

  def handle(%Context{} = _ctx, %{"action" => "login"}) do
    # Login requires browser redirect in Sanctum
    {:ok, %{message: "Login requires browser authentication", redirect: "/auth/login"}}
  end

  # The MCP transport is stateless; a Sanctum session is not. This action
  # used to report success without retiring anything, so `cyfr logout`
  # left a working 30-day credential behind.
  def handle(%Context{session_token_hash: hash}, %{"action" => "logout"})
      when is_binary(hash) do
    case Sanctum.Session.destroy_by_hash(hash) do
      :ok ->
        {:ok, %{message: "Logged out successfully"}}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] logout failed: #{inspect(reason)}")
        {:error, "Logout failed"}
    end
  end

  # An API key authenticated this call, so there is no session to end. Say
  # so rather than reporting a logout that did not happen — a key is
  # retired with `key.revoke`.
  def handle(%Context{authenticated: true}, %{"action" => "logout"}) do
    {:error, "No session to log out: this call authenticated with an API key. Use key.revoke."}
  end

  def handle(%Context{}, %{"action" => "logout"}) do
    {:error, "Not authenticated."}
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

        {:error, {:door, _reason}} ->
          # One message whichever branch refused; the list is not for
          # strangers to learn.
          {:error, Sanctum.Door.refusal_message()}

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
    {:error,
     "Invalid session action. Use: login, logout, whoami, device_init, device_poll, or use"}
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
  defp resolve_athanor("ath_" <> _ = id) do
    case Sanctum.Tenancy.Athanors.get(id) do
      {:ok, athanor} -> {:ok, athanor}
      _ -> {:error, :not_found}
    end
  end

  defp resolve_athanor(slug), do: Sanctum.Tenancy.Athanors.by_route_slug(slug)

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
