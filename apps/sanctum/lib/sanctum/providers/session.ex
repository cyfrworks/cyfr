# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Session do
  @moduledoc """
  Session tool handlers for the Sanctum MCP provider — logout, whoami,
  a protected device's unlock and lock,
  and the caller's self-description resources. A command line signs in as
  a protected device does (`Sanctum.DeviceUnlock`): its shell unlocks on
  its device channel and spends the ticket at `POST /device/session`.

  `unlock` and `lock` are a protected device's, through its device
  channel alone (`auth_method: :device`, a client that reports a holder):
  `unlock` with no arguments answers an `unlock` challenge, and with its
  `proof` alone a single-use `ticket`, the `session_id` it reserved and
  the ticket's `expires_at` (ms), which the device's browser, or its
  command line, redeems for its session (`Sanctum.DeviceUnlock`); `lock` with the `lock` proof the
  device signed for that session retires it, `locked: true` even when it
  is already gone. A browser's session, or any other context, is refused.

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
    Operation.tool(
      [
        Operation.new("session", "logout", "Logout session", [],
          auth: :anonymous,
          reduces_authority: true,
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
          "unlock",
          "Unlock a protected device into a browser session",
          [
            Arg.new("proof", :json,
              description:
                "unlock: the device's proof over the unlock challenge an unlock with no arguments answered"
            )
          ],
          kind: :write,
          planes: [:external]
        ),
        Operation.new(
          "session",
          "lock",
          "Lock a protected device's browser session",
          [
            Arg.new("proof", :json,
              required: true,
              description: "lock: the device's lock proof for the session its unlock reserved"
            )
          ],
          reduces_authority: true,
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
        "Manage user sessions — logout, get local identity, or unlock and lock a protected device's session. Registry identity (push tokens, namespaces) is a separate `registry` tool under Compendium.",
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
       platform_admin: ctx.platform_admin,
       session_expires_at: session_expires_at(ctx)
     }}
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

  # The caller's own self-description, from the context the transport
  # established and nothing stored: an anonymous caller reads its own
  # empty identity, never a tenant's data.
  def handle(%Context{} = ctx, %{"action" => "read_resource", "uri" => "sanctum://identity"}) do
    self_description(%{user_id: ctx.user_id, athanor_id: ctx.athanor_id, scope: ctx.scope})
  end

  def handle(%Context{} = ctx, %{"action" => "read_resource", "uri" => "sanctum://permissions"}) do
    self_description(%{permissions: permission_names(ctx.permissions)})
  end

  def handle(_ctx, %{"action" => "read_resource", "uri" => uri}) when is_binary(uri) do
    {:error, {:invalid_argument, "Unknown resource URI: #{uri}"}}
  end

  def handle(_ctx, %{"action" => "read_resource"}) do
    {:error, {:invalid_argument, "Missing required argument: uri"}}
  end

  def handle(%Context{} = ctx, %{"action" => "unlock"} = args) do
    case Sanctum.DeviceUnlock.unlock(ctx, Map.delete(args, "action")) do
      {:ok, %{challenge: challenge}} ->
        {:ok, %{challenge: Prima.DeviceCert.Challenge.encode(challenge)}}

      {:ok, answer} ->
        {:ok, answer}

      {:error, reason} ->
        {:error, device_refusal(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "lock"} = args) do
    case Sanctum.DeviceUnlock.lock(ctx, Map.delete(args, "action")) do
      {:ok, answer} -> {:ok, answer}
      {:error, reason} -> {:error, device_refusal(reason)}
    end
  end

  # The terminal clause answers both shapes the dispatcher already
  # distinguishes: no `action` at all, and one this tool does not know.
  def handle(_ctx, args) do
    case args do
      %{"action" => action} -> {:error, {:unknown_action, "session.#{action}"}}
      _ -> {:error, :action_missing}
    end
  end

  # A protected device's unlock and lock refusals, each with the sentence
  # its person reads; the stores' own reasons pass as they are.
  defp device_refusal(:not_a_device),
    do:
      refused(
        :forbidden,
        :not_a_device,
        "Only a protected device's own screen unlocks or locks its session"
      )

  defp device_refusal(:no_holder),
    do:
      refused(
        :forbidden,
        :no_holder,
        "This device keeps no protected key, so it cannot unlock: set it up again with a PIN or passphrase"
      )

  defp device_refusal(:proof_refused),
    do:
      refused(
        :unauthenticated,
        :proof_refused,
        "The device's proof was refused: unlock again"
      )

  defp device_refusal(:session_retired),
    do:
      refused(
        :conflict,
        :session_retired,
        "This unlock was locked before it finished: unlock again"
      )

  defp device_refusal(:invalid_request),
    do: {:invalid_argument, "unlock takes no arguments or its proof alone; lock takes its proof"}

  defp device_refusal(:not_standing),
    do:
      refused(
        :forbidden,
        :not_standing,
        "This device's pairing no longer stands here"
      )

  defp device_refusal(reason), do: reason

  defp refused(class, reason, message),
    do: %Prima.Refusal{class: class, reason: reason, message: message}

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

  # When the caller's session ends unless activity extends it, RFC 3339:
  # what a consent's "this session" lifetime is held to. A caller whose
  # credential is no session (an API key) has none, and neither does one
  # whose session row cannot be read now.
  defp session_expires_at(%Context{session_token_hash: hash}) when is_binary(hash) do
    case Sanctum.Session.expires_at_by_hash(hash) do
      {:ok, %DateTime{} = at} -> DateTime.to_iso8601(at)
      {:error, _unread} -> nil
    end
  end

  defp session_expires_at(_ctx), do: nil

  # ============================================================================
  # Helpers shared across session handlers
  # ============================================================================

  # The caller's permissions as the wire names them, sorted.
  defp permission_names(permissions) do
    permissions |> MapSet.to_list() |> Enum.map(&to_string/1) |> Enum.sort()
  end
end
