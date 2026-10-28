# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Session do
  @moduledoc """
  Session tool handlers for the Sanctum MCP provider — logout, whoami,
  focusing another athanor (`use`), device-flow OAuth, signing a command
  line in by approving it in Prism (`Sanctum.CliSignIn`), and the caller's
  self-description resources.

  `setup` is `auth: :anonymous`: the command line of a CYFR with no
  person yet (`cyfr login --setup`) presents the installation's setup
  token, and the setup admission (`Sanctum.Newcomer`) makes the first
  person, or signs them in again while they hold no sign-in method, with
  a command-line session for its machine. Any other token, or a CYFR set
  up already, is `:setup_closed`.

  `cli_begin`, `cli_poll` and `cli_cancel` are `auth: :anonymous`, as
  the device flow's actions are: the command line that calls them holds
  no credential yet, and the token `cli_begin` answers it is the only
  name `cli_poll` and `cli_cancel` take. `cli_approve`, `cli_list` and
  `cli_revoke` are the person's, through an interactive surface
  (`consent: :interactive`); approving is a sensitive change
  (`credential_issuance`, `Sanctum.Pairing`).

  `read_resource` admits an MCP `resources/read` of `sanctum://identity`
  or `sanctum://permissions`. It is `auth: :anonymous` and needs no
  permission: it answers from the caller's established context alone and
  reads no stored tenant data, so an anonymous caller is told only its
  own empty identity.
  """

  require Logger
  require Sanctum.Issuance

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
          "device_init",
          "Device init session",
          [
            Arg.new("provider", :string,
              description: "OAuth provider for device flow",
              enum: Sanctum.Auth.DeviceFlow.providers()
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
            Arg.new("machine", :string,
              description:
                "device_poll: the command line's host name, which its session is listed by in Prism"
            ),
            Arg.new("provider", :string,
              description: "OAuth provider for device flow",
              enum: Sanctum.Auth.DeviceFlow.providers()
            )
          ],
          auth: :anonymous,
          kind: :write,
          planes: [:external]
        ),
        Operation.new(
          "session",
          "cli_begin",
          "Begin signing a command line in",
          [
            Arg.new("machine", :string,
              required: true,
              description:
                "cli_begin: the command line's host name, which Prism names when it asks to approve it"
            )
          ],
          auth: :anonymous,
          kind: :write,
          planes: [:external]
        ),
        Operation.new(
          "session",
          "setup",
          "Set this CYFR up from the command line",
          [
            Arg.new("setup_token", :string,
              required: true,
              description: "setup: the installation's setup token, CYFR_SETUP_TOKEN in its .env"
            ),
            Arg.new("machine", :string,
              required: true,
              description:
                "setup: the command line's host name, which its session is listed by in Prism"
            )
          ],
          auth: :anonymous,
          kind: :write,
          planes: [:external]
        ),
        Operation.new(
          "session",
          "cli_poll",
          "Poll a command line's sign-in",
          [cli_token("cli_poll")],
          auth: :anonymous,
          kind: :read,
          planes: [:external]
        ),
        Operation.new(
          "session",
          "cli_cancel",
          "Stop a command line's sign-in",
          [cli_token("cli_cancel")],
          auth: :anonymous,
          reduces_authority: true,
          kind: :write,
          planes: [:external]
        ),
        Operation.new(
          "session",
          "cli_approve",
          "Approve a command line's sign-in",
          [
            Arg.new("approval_secret", :string,
              required: true,
              description:
                "cli_approve: the secret the command line's link carries in its fragment"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new("session", "cli_list", "List your command-line sessions", [],
          kind: :read,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "session",
          "cli_revoke",
          "Revoke a command-line session",
          [
            Arg.new("session_id", :string,
              required: true,
              description: "cli_revoke: the command-line session (ses_…), as cli_list names it"
            )
          ],
          reduces_authority: true,
          kind: :destructive,
          planes: [:external],
          consent: :interactive
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
        "Manage user sessions — logout, get local identity, focus another athanor, set this CYFR up from the command line with its setup token, run device-flow OAuth, or sign a command line in by approving it in Prism and list or revoke command-line sessions. Registry identity (push tokens, namespaces) is a separate `registry` tool under Compendium.",
      title: "Session Management"
    )
  end

  def handle(%Context{} = ctx, %{"action" => "cli_begin"} = args) do
    case Sanctum.CliSignIn.begin(args["machine"], ctx.client_ip) do
      {:ok, begun} -> {:ok, begun}
      {:error, reason} -> {:error, cli_refusal(reason)}
    end
  end

  # The installation's first person, made or signed in again by the setup
  # token (`Sanctum.Newcomer`): a command-line session for the machine.
  def handle(_ctx, %{"action" => "setup", "setup_token" => token} = args)
      when is_binary(token) do
    case Sanctum.Newcomer.admit({:setup, token}, {:command_line, args["machine"]}) do
      {:ok, %{person: person, readmitted: readmitted, session_token: session_token}} ->
        {:ok, %{session_token: session_token, user_id: person.id, readmitted: readmitted}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "cli_poll"} = args) do
    case Sanctum.CliSignIn.poll(args["session_token"], ctx.client_ip) do
      {:ok, polled} -> {:ok, polled}
      {:error, reason} -> {:error, cli_refusal(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "cli_cancel"} = args) do
    case Sanctum.CliSignIn.cancel(args["session_token"], ctx.client_ip) do
      {:ok, cancelled} -> {:ok, cancelled}
      {:error, reason} -> {:error, cli_refusal(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "cli_approve"} = args) do
    case Sanctum.CliSignIn.approve(ctx, args["approval_secret"]) do
      {:ok, approved} -> {:ok, approved}
      {:error, reason} -> {:error, cli_refusal(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "cli_list"}) do
    case Sanctum.CliSignIn.list(ctx) do
      {:ok, sessions} -> {:ok, %{sessions: Enum.map(sessions, &cli_listed/1)}}
      {:error, reason} -> {:error, cli_refusal(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "cli_revoke"} = args) do
    case Sanctum.CliSignIn.revoke(ctx, args["session_id"]) do
      {:ok, revoked} -> {:ok, revoked}
      {:error, reason} -> {:error, cli_refusal(reason)}
    end
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

  # Point the session at another athanor the caller may work in — what a
  # non-browser client does instead of following a `/a/<athanor>` URL.
  def handle(%Context{} = ctx, %{"action" => "use", "athanor" => athanor})
      when is_binary(athanor) do
    with {:ok, resolved} <- resolve_athanor(athanor),
         {:ok, focused} <- Sanctum.Session.use_athanor(ctx, resolved.id) do
      {:ok, %{athanor: Sanctum.Providers.Athanor.render(resolved), scope: focused.scope}}
    else
      # Focus answers this only to a member: a caller without a seat is
      # told what a missing athanor tells them, below.
      {:error, :archived} ->
        {:error, {:invalid_argument, "That athanor is archived"}}

      # No such athanor, or none the caller holds a seat in: one refusal,
      # naming what the caller named, for an open, an archived and an
      # absent athanor alike. A session row gone under the call (revoked
      # meanwhile) answers `:not_found` from `use_athanor/2` too, and is
      # answered so as well: naming the session instead would tell a caller
      # with no seat that the athanor exists.
      {:error, :not_found} ->
        {:error, {:not_found, "Athanor", athanor}}

      {:error, :no_session} ->
        {:error,
         {:invalid_argument, "session.use needs a session — a key is bound to one athanor"}}

      {:error, _} ->
        {:error, {:unavailable, "Storage"}}
    end
  end

  def handle(_ctx, %{"action" => "use"}),
    do: {:error, {:invalid_argument, "Missing required argument: athanor"}}

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
          Logger.warning(
            "[Sanctum.Providers.Session] Device flow init rejected by provider: #{inspect(code)}"
          )

          {:error,
           "Device flow rejected by provider: #{code}. " <>
             "For Google, the OAuth client must be type \"TV and Limited Input devices\"."}

        {:error, {:device_code_request_failed, reason}} ->
          # The reason is a transport term (a Req/Mint struct) — log it,
          # never reflect it.
          Logger.warning(
            "[Sanctum.Providers.Session] Device flow network error: #{inspect(reason)}"
          )

          {:error, {:unavailable, "The sign-in provider"}}

        {:error, {:unknown_provider, name}} ->
          {:error, {:invalid_argument, unknown_provider_message(name)}}

        # The init budget of this address or of the server is spent.
        {:error, {:rate_limited, _retry_after_s} = limited} ->
          {:error, limited}
      end
    else
      {:error, {:invalid_argument, device_flow_disabled_message()}}
    end
  end

  def handle(
        %Context{} = ctx,
        %{"action" => "device_poll", "device_code" => device_code} = args
      ) do
    with true <- device_flow_enabled?(),
         {:ok, opts} <- poll_machine(args) do
      provider = Map.get(args, "provider", "github")

      # Charged to the caller's address, as `device_init` above.
      case Sanctum.Auth.DeviceFlow.impl().poll_for_session(
             provider,
             device_code,
             ctx.client_ip,
             opts
           ) do
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
          Logger.warning(
            "[Sanctum.Providers.Session] Token exchange rejected by provider: #{inspect(code)}"
          )

          {:error, "Token exchange rejected by provider: #{code}"}

        {:error, {:token_request_failed, reason}} ->
          Logger.warning(
            "[Sanctum.Providers.Session] Token exchange network error: #{inspect(reason)}"
          )

          {:error, {:unavailable, "The sign-in provider"}}

        # The server is at capacity: a person admitted without an athanor
        # would hold a session with nowhere to work, so the door refuses and
        # the poller is told why rather than "sign-in failed" — a rate
        # limit, whose sentence is the refusal vocabulary's.
        {:error, {:limit_reached, _key, _cap}} = limit ->
          limit

        {:error, {:unknown_provider, name}} ->
          {:error, {:invalid_argument, unknown_provider_message(name)}}

        {:error, reason} ->
          Logger.warning(
            "[Sanctum.Providers.Session] Failed to poll for token: #{inspect(reason)}"
          )

          {:error, {:unavailable, "The sign-in provider"}}
      end
    else
      false -> {:error, {:invalid_argument, device_flow_disabled_message()}}
      {:error, _invalid} = refused -> refused
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
    self_description(%{permissions: permission_names(ctx.permissions)})
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

  # A command line's poll names the machine it runs on, so the session it
  # signs in is listed and revoked as that command line's; a poll that
  # names none signs in a session no list shows as one.
  defp poll_machine(%{"machine" => machine}) when not is_nil(machine) do
    with {:ok, machine} <- Sanctum.CliSignIn.machine(machine), do: {:ok, [command_line: machine]}
  end

  defp poll_machine(_args), do: {:ok, []}

  defp cli_token(action),
    do:
      Prima.Arg.new("session_token", :string,
        required: true,
        description:
          "#{action}: the session token cli_begin answered, which the command line holds"
      )

  defp cli_listed(session) do
    %{
      session_id: session.session_id,
      machine: session.machine,
      signed_in_at: Prima.Time.iso8601(session.signed_in_at),
      expires_at: Prima.Time.iso8601(session.expires_at),
      current: session.current
    }
  end

  # A command line's sign-in refusals in the one refusal shape every
  # surface renders (`Prima.Refusal`), each with the sentence its person
  # reads; the vocabulary's own reasons (a confirmation signal, a rate
  # limit, a standing or tenancy refusal) pass as they are.
  defp cli_refusal(:not_found),
    do:
      cli_refused(
        :not_found,
        :cli_sign_in_unknown,
        "This link or session is not one this CYFR knows: run cyfr login again for a new link"
      )

  defp cli_refusal(:expired),
    do:
      cli_refused(
        :conflict,
        :cli_sign_in_expired,
        "This command line's sign-in expired before it was approved: run cyfr login again"
      )

  defp cli_refusal(:approved),
    do:
      cli_refused(
        :conflict,
        :cli_sign_in_used,
        "This command line was already approved: its link signs in once"
      )

  defp cli_refusal(:cancelled),
    do:
      cli_refused(
        :conflict,
        :cli_sign_in_cancelled,
        "The command line stopped waiting: run cyfr login again"
      )

  defp cli_refusal(:session_required),
    do:
      cli_refused(
        :forbidden,
        :session_required,
        "Approve a command line from a browser signed in to this CYFR"
      )

  # A session minted as a sign-in's is: a session a restore minted, which
  # initializes no credential of its own, and a remote person's identity
  # that moved between its reads.
  defp cli_refusal(:reserved_provider),
    do:
      cli_refused(
        :forbidden,
        :reserved_provider,
        "A session from a restore approves no command line: sign in with a sign-in method of yours, then approve"
      )

  defp cli_refusal(reason) when reason in [:stale_key_epoch, :identity_key_epoch_required],
    do:
      cli_refused(
        :conflict,
        reason,
        "Your identity changed while this was approved: approve the command line again"
      )

  defp cli_refusal(reason) when Sanctum.Issuance.standing_refusal?(reason),
    do: Sanctum.Issuance.standing_refusal(reason)

  defp cli_refusal(reason), do: reason

  defp cli_refused(class, reason, message),
    do: %Prima.Refusal{class: class, reason: reason, message: message}

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

  # An archived athanor resolves like an open one, so `focus/2` decides
  # what the caller hears of it; a store that cannot answer is unavailable.
  defp resolve_athanor(segment) do
    if Sanctum.Tenancy.Athanors.athanor_id?(segment) do
      Sanctum.Tenancy.Athanors.get(segment)
    else
      Sanctum.Tenancy.Athanors.by_route_slug(segment)
    end
  end

  # The device flow is offered exactly when GitHub or Google is
  # configured (`Sanctum.Auth.DeviceFlow.configured_providers/0`).
  defp device_flow_enabled?, do: Sanctum.Auth.DeviceFlow.configured_providers() != []

  defp device_flow_disabled_message do
    "This CYFR offers no GitHub or Google sign-in. Sign in with a passkey, a device you " <>
      "connected, or `cyfr login` approved in the browser."
  end

  # The caller's permissions as the wire names them, sorted.
  defp permission_names(permissions) do
    permissions |> MapSet.to_list() |> Enum.map(&to_string/1) |> Enum.sort()
  end
end
