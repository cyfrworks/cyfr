# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Session do
  @moduledoc """
  Session tool handlers for the Sanctum MCP provider — logout, whoami,
  the person's name here, their account's keys and sessions here and one
  session's end, a protected device's unlock and lock, and the caller's
  self-description resources. A command line signs in as
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

  `name` records the name the person's account holds at cyfr.run as their
  name here (`Sanctum.SignIn.record_name/2`): the person types it, with or
  without its `@`, and the registry's answer for it must name their own
  account. A name another account holds, or none, is refused in a sentence
  the person reads, and nothing is recorded. A name already recorded is
  kept; the answer is the name recorded.

  `list` answers the keys of the person's account, every one its log
  lists, with their sessions here under each, and the account page where
  a key is removed (`Sanctum.AccountKeys`).
  `end` signs one of those sessions out by its `session_id`, whichever
  browser or device holds it, their own included, and nothing else
  (`Sanctum.Session.end_own/2`): a sign-out is a session's, never a key's,
  and removing a key is the account pages'. It takes authority away and
  asks no confirmation. Both are the person's own, through an interactive
  surface (`consent: :interactive`).

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
          "name",
          "Record your account's name here",
          [
            Arg.new("name", :string,
              required: true,
              description: "name: the name your account holds at cyfr.run, with or without its @"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "session",
          "list",
          "List your account's keys and their sessions here",
          [],
          kind: :read,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "session",
          "end",
          "Sign one of your sessions here out",
          [
            Arg.new("session_id", :string,
              required: true,
              description: "end: the session, by its session_id from session.list"
            )
          ],
          reduces_authority: true,
          kind: :destructive,
          planes: [:external],
          consent: :interactive
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
        "Manage user sessions — logout, get local identity, list your account's keys and sessions here and sign one out, or unlock and lock a protected device's session. Registry identity (push tokens, namespaces) is a separate `registry` tool under Compendium.",
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

  def handle(%Context{user_id: user_id} = ctx, %{"action" => "name", "name" => name})
      when is_binary(user_id) and is_binary(name) do
    typed = name |> String.trim() |> String.trim_leading("@") |> String.downcase()

    if ctx.authenticated and Prima.PersonId.person?(user_id) do
      case Sanctum.SignIn.record_name(user_id, typed) do
        {:ok, user} -> {:ok, %{name: user.namespace}}
        {:error, reason} -> {:error, name_refusal(reason, typed)}
      end
    else
      {:error, :unauthenticated}
    end
  end

  def handle(_ctx, %{"action" => "name"}),
    do: {:error, {:invalid_argument, "Missing required argument: name"}}

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    case Sanctum.AccountKeys.list(ctx) do
      {:ok, listing} -> {:ok, listing}
      {:refused, why} -> {:error, why}
      {:error, reason} -> {:error, keys_refusal(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "end", "session_id" => id}) when is_binary(id) do
    case Sanctum.Session.end_own(ctx, id) do
      :ok -> {:ok, %{ended: true}}
      {:error, reason} -> {:error, keys_refusal(reason)}
    end
  end

  def handle(_ctx, %{"action" => "end"}),
    do: {:error, {:invalid_argument, "Missing required argument: session_id"}}

  # The terminal clause answers both shapes the dispatcher already
  # distinguishes: no `action` at all, and one this tool does not know.
  def handle(_ctx, args) do
    case args do
      %{"action" => action} -> {:error, {:unknown_action, "session.#{action}"}}
      _ -> {:error, :action_missing}
    end
  end

  # The keys' and sessions' refusals in the one refusal shape every surface
  # renders (`Prima.Refusal`); the vocabulary's own reasons pass as they are.
  defp keys_refusal(:unauthenticated),
    do: %Prima.Refusal{
      class: :unauthenticated,
      reason: :unauthenticated,
      message: "Only a person signed in here sees their keys and sessions"
    }

  defp keys_refusal(:not_found),
    do: %Prima.Refusal{
      class: :not_found,
      reason: :not_found,
      message: "No session of yours here has that id"
    }

  defp keys_refusal(reason), do: reason

  # A name's refusals, each with the sentence its person reads; the stores'
  # own reasons pass as they are.
  defp name_refusal(:invalid_name, _name),
    do:
      refused(
        :invalid_argument,
        :invalid_name,
        "A name is lowercase letters, digits and single hyphens, at most 39 characters"
      )

  defp name_refusal(:name_not_theirs, name),
    do: refused(:forbidden, :name_not_theirs, "@#{name} is another account's name, not yours")

  defp name_refusal(:name_unheld, name),
    do:
      refused(
        :not_found,
        :name_unheld,
        "No account holds @#{name} at cyfr.run: type the name you chose when you made your account"
      )

  defp name_refusal(:registry_unavailable, _name),
    do:
      refused(
        :unavailable,
        :registry_unavailable,
        "cyfr.run could not check that name just now; try again shortly"
      )

  defp name_refusal(:no_registry, _name),
    do:
      refused(
        :setup_required,
        :no_registry,
        "This CYFR is set up without cyfr.run, so it cannot check a name"
      )

  defp name_refusal(:namespace_owned_by_another_identity, name),
    do:
      refused(
        :conflict,
        :namespace_owned_by_another_identity,
        "Another person on this CYFR holds @#{name}: ask whoever runs this CYFR"
      )

  defp name_refusal(:not_owner, _name), do: {:unavailable, "Storage"}
  defp name_refusal(:database_error, _name), do: {:unavailable, "Storage"}
  defp name_refusal(reason, _name), do: reason

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
