# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Session do
  @moduledoc """
  Session tool handlers for the Sanctum MCP provider — login, logout,
  whoami, device-flow OAuth, and the caller's self-description resources.

  `read_resource` admits an MCP `resources/read` of `sanctum://identity`
  or `sanctum://permissions`. It is `auth: :anonymous` and needs no
  permission: it answers from the caller's established context alone and
  reads no stored tenant data, so an anonymous caller is told only its
  own empty identity.
  """

  require Logger

  alias Sanctum.Context

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    alias Prima.{Arg, Operation}
    # Anonymous-allowed: `whoami` and the device-flow login actions need
    # to work before a credential exists, and `logout` only ever
    # destroys the caller's own session.
    # Point the session at another athanor the caller may work in.
    Operation.tool(
      [
        Operation.new("session", "login", "Login session", [],
          auth: :anonymous,
          kind: :write,
          planes: [:external]
        ),
        Operation.new("session", "logout", "Logout session", [],
          auth: :anonymous,
          kind: :write,
          planes: [:external]
        ),
        Operation.new("session", "whoami", "Whoami session", [],
          auth: :anonymous,
          kind: :read,
          planes: [:external]
        ),
        Operation.new(
          "session",
          "device_init",
          "Device init session",
          [
            Arg.new("provider", :string,
              description: "OAuth provider for device flow",
              enum: ["github", "google"]
            )
          ],
          auth: :anonymous,
          kind: :write,
          planes: [:external]
        ),
        Operation.new(
          "session",
          "device_poll",
          "Device poll session",
          [
            Arg.new("device_code", :string,
              required: true,
              description: "Device code from device_init (for device_poll action)"
            ),
            Arg.new("provider", :string,
              description: "OAuth provider for device flow",
              enum: ["github", "google"]
            )
          ],
          auth: :anonymous,
          kind: :write,
          planes: [:external]
        ),
        Operation.new(
          "session",
          "use",
          "Use session",
          [
            Arg.new("athanor", :string,
              required: true,
              description:
                "For `use`: the athanor to work in — an id, a group slug, or @<namespace>"
            )
          ],
          kind: :write,
          planes: [:external]
        ),
        # The admission of an MCP `resources/read` of the caller's own
        # self-description (`Sanctum.Provider.resources/0`).
        Operation.new(
          "session",
          "read_resource",
          "Read a sanctum:// self-description",
          [
            Arg.new("uri", :string,
              required: true,
              description: "sanctum://identity or sanctum://permissions"
            )
          ],
          auth: :anonymous,
          kind: :read,
          planes: [:external],
          recovery: :replay_safe,
          resource_schemes: ["sanctum"]
        )
      ],
      description:
        "Manage user sessions — login, logout, get local identity, or run device-flow OAuth. Registry identity (push tokens, namespaces) is a separate `registry` tool under Compendium.",
      title: "Session Management"
    )
  end

  def handle(%Context{authenticated: false}, %{"action" => "whoami"}) do
    {:error, {:invalid_argument, "Not authenticated. Run 'cyfr login' to sign in."}}
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
         {:ok, focused} <- focus_session(ctx, resolved.id) do
      {:ok, %{athanor: Sanctum.Providers.Athanor.render(resolved), scope: focused.scope}}
    else
      {:error, :not_member} ->
        {:error, {:invalid_argument, "Not a member of that athanor"}}

      {:error, :archived} ->
        {:error, {:invalid_argument, "That athanor is archived"}}

      # Only `resolve_athanor/1` can still answer this: `focus_session/2`
      # re-tags the session row's own :not_found, so the refusal names
      # what is actually missing instead of blaming the athanor that
      # resolved a line above.
      {:error, :not_found} ->
        {:error, {:not_found, "Athanor", athanor}}

      {:error, :no_session} ->
        {:error,
         {:invalid_argument, "session.use needs a session — a key is bound to one athanor"}}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, _} ->
        {:error, {:unavailable, "Storage"}}
    end
  end

  def handle(_ctx, %{"action" => "use"}),
    do: {:error, {:invalid_argument, "Missing required argument: athanor"}}

  def handle(%Context{} = _ctx, %{"action" => "login"}) do
    # Login requires browser redirect in Sanctum
    {:ok, %{message: "Login requires browser authentication", redirect: "/auth/login"}}
  end

  # Revoke the Sanctum session authenticated by this request.
  def handle(%Context{session_token_hash: hash}, %{"action" => "logout"})
      when is_binary(hash) do
    case Sanctum.Session.destroy_by_hash(hash) do
      :ok ->
        {:ok, %{message: "Logged out successfully"}}

      {:error, reason} ->
        Logger.warning("[Sanctum.Providers.Session] logout failed: #{inspect(reason)}")
        {:error, {:unavailable, "Storage"}}
    end
  end

  # An API key authenticated this call, so there is no session to end. Say
  # so rather than reporting a logout that did not happen — a key is
  # retired with `key.revoke`.
  def handle(%Context{authenticated: true}, %{"action" => "logout"}) do
    {:error,
     {:invalid_argument,
      "No session to log out: this call authenticated with an API key. Use key.revoke."}}
  end

  def handle(%Context{}, %{"action" => "logout"}) do
    {:error, {:invalid_argument, "Not authenticated."}}
  end

  def handle(%Context{} = ctx, %{"action" => "device_init"} = args) do
    if device_flow_enabled?() do
      provider = Map.get(args, "provider", "github")

      # The caller's address, so this anonymous action has a budget of its
      # own. The transport meters every `/mcp` method together, which
      # bounds one address but not several between them — the global
      # ceiling is a circuit breaker, not a per-caller budget.
      case Sanctum.Auth.DeviceFlow.impl().init_device_flow(provider, ctx.client_ip) do
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
          Logger.warning("[Sanctum.Providers.Session] Device flow init rejected by provider: #{inspect(code)}")

          {:error,
           "Device flow rejected by provider: #{code}. " <>
             "For Google, the OAuth client must be type \"TV and Limited Input devices\"."}

        {:error, {:device_code_request_failed, reason}} ->
          # The reason is a transport term (a Req/Mint struct) — log it,
          # never reflect it.
          Logger.warning("[Sanctum.Providers.Session] Device flow network error: #{inspect(reason)}")
          {:error, {:unavailable, "The sign-in provider"}}

        {:error, {:unknown_provider, name}} ->
          {:error, {:invalid_argument, unknown_provider_message(name)}}
      end
    else
      {:error, {:invalid_argument, device_flow_disabled_message()}}
    end
  end

  def handle(
        %Context{} = ctx,
        %{"action" => "device_poll", "device_code" => device_code} = args
      ) do
    if device_flow_enabled?() do
      provider = Map.get(args, "provider", "github")

      # Charged to the caller's address, as `device_init` above.
      case Sanctum.Auth.DeviceFlow.impl().poll_for_session(provider, device_code, ctx.client_ip) do
        {:ok, result} ->
          {:ok, Sanctum.Auth.DeviceFlow.wire(result)}

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
          Logger.warning("[Sanctum.Providers.Session] Token exchange rejected by provider: #{inspect(code)}")
          {:error, "Token exchange rejected by provider: #{code}"}

        {:error, {:token_request_failed, reason}} ->
          Logger.warning("[Sanctum.Providers.Session] Token exchange network error: #{inspect(reason)}")
          {:error, {:unavailable, "The sign-in provider"}}

        # The server is at capacity: a person admitted without an athanor
        # would hold a session with nowhere to work, so the door refuses and
        # the poller is told why rather than "sign-in failed".
        {:error, {:limit_reached, :mint_per_hour, _cap}} ->
          {:error, "This server is admitting new people slowly right now — try again shortly"}

        {:error, {:limit_reached, _key, _cap}} ->
          {:error, "This server is full and cannot make you an athanor — ask its operator"}

        {:error, {:unknown_provider, name}} ->
          {:error, {:invalid_argument, unknown_provider_message(name)}}

        {:error, reason} ->
          Logger.warning("[Sanctum.Providers.Session] Failed to poll for token: #{inspect(reason)}")
          {:error, {:unavailable, "The sign-in provider"}}
      end
    else
      {:error, {:invalid_argument, device_flow_disabled_message()}}
    end
  end

  def handle(_ctx, %{"action" => "device_poll"}) do
    {:error, {:invalid_argument, "Missing required argument: device_code"}}
  end

  # The caller's own self-description, from the context the transport
  # established and nothing stored: an anonymous caller reads its own
  # empty identity, never a tenant's data.
  def handle(%Context{} = ctx, %{"action" => "read_resource", "uri" => "sanctum://identity"}) do
    self_description(%{user_id: ctx.user_id, athanor_id: ctx.athanor_id, scope: ctx.scope})
  end

  def handle(%Context{} = ctx, %{"action" => "read_resource", "uri" => "sanctum://permissions"}) do
    self_description(%{permissions: Sanctum.Providers.Shared.format_permissions(ctx.permissions)})
  end

  def handle(_ctx, %{"action" => "read_resource", "uri" => uri}) when is_binary(uri) do
    {:error, {:invalid_argument, "Unknown resource URI: #{uri}"}}
  end

  def handle(_ctx, %{"action" => "read_resource"}) do
    {:error, {:invalid_argument, "Missing required argument: uri"}}
  end

  # The terminal clause answers both shapes the dispatcher already
  # distinguishes: no `action` at all, and one this tool does not know.
  def handle(_ctx, args) do
    case args do
      %{"action" => action} -> {:error, {:unknown_action, "session.#{action}"}}
      _ -> {:error, :action_missing}
    end
  end

  # `provider` on device_init/device_poll comes straight from the caller. A
  # name this server does not know is a mistake worth naming, not a crash and
  # not an inspect of an internal tuple.
  defp unknown_provider_message(name) do
    "Unknown sign-in provider #{inspect(to_string(name))}. " <>
      "This server knows: #{Enum.join(Sanctum.Auth.DeviceFlow.providers(), ", ")}."
  end

  defp self_description(fields) do
    content =
      case Jason.encode(fields) do
        {:ok, json} -> json
        {:error, _} -> ~s({"error":"encoding_error"})
      end

    {:ok, %{content: content, mimeType: Prima.MediaType.json()}}
  end

  # session.whoami helpers: the display fields the Context carries.
  defp derive_email(%Context{email: email}) when is_binary(email) and email != "", do: email
  defp derive_email(_), do: nil

  defp derive_provider(%Context{provider: provider}) when is_binary(provider) and provider != "",
    do: provider

  defp derive_provider(_), do: nil

  # ============================================================================
  # Auth-provider-gated helpers (shared across session handlers)
  # ============================================================================

  # `Sanctum.Session.use_athanor/2` answers `:not_found` when the SESSION
  # row is gone — the athanor resolved a line earlier. Two sources for one
  # tag made the refusal a structured falsehood a client could branch on;
  # this names the one that is actually missing.
  defp focus_session(ctx, athanor_id) do
    case Sanctum.Session.use_athanor(ctx, athanor_id) do
      {:error, :not_found} -> {:error, :no_session}
      other -> other
    end
  end

  defp resolve_athanor(segment) do
    if Sanctum.Tenancy.Athanors.athanor_id?(segment) do
      case Sanctum.Tenancy.Athanors.get(segment) do
        {:ok, athanor} -> {:ok, athanor}
        _ -> {:error, :not_found}
      end
    else
      Sanctum.Tenancy.Athanors.by_route_slug(segment)
    end
  end

  # Device-flow CLI auth requires the default OAuth provider. Deployments that
  # pin `:auth_provider` to a configured OIDC provider use the web OIDC flow at
  # `/auth/oidcc` — device_init/device_poll are gated off in that case.
  # Installs with `:auth_provider = nil` are treated as the default (OAuth)
  # for this check,
  # so local dev without explicit config still works.
  defp device_flow_enabled? do
    case Sanctum.Auth.provider() do
      nil -> true
      Sanctum.Auth.OAuth -> true
      _ -> false
    end
  end

  defp device_flow_disabled_message do
    "Device-flow CLI auth requires the GitHub/Google OAuth provider. " <>
      "This deployment is configured with a different auth provider; " <>
      "use the web flow at `/auth/oidcc` instead."
  end
end
