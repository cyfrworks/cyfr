# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SettingsLive do
  @moduledoc """
  Settings: the person's own identity, sign-in doors and passkeys, their
  lite/dev preference, and, for a platform admin, the door and the
  platform settings.

  Every change is an operation through the gate, and every read of the
  person's identity is one too (`person.status`, `passkey.list`). A change
  that needs a fresh confirmation is asked through the page's system
  layer (`PrismWeb.SystemLayer.call/5`) and made again once confirmed.

    * **Identity** — whether this home holds the person's keys, their
      identifier, the directory this home pins and the head their row
      names; enrolling, a kit not yet saved, another printed kit and the
      live key's rotation (`person.rotate`). Enrollment and every kit
      render only in the system layer's recovery prompts
      (`PrismWeb.SystemLayer.Recovery`): this page never holds a seed or a
      kit line. With no directory pinned, enrollment names the setting the
      operator owes, and everything else here works as before. An
      enrollment still waiting for the directory whose seed no prompt here
      holds (the browser that began it lost it) is abandoned and begun
      again under a new kit (`person.enroll_abandon`). A person whose keys
      another home holds is told to change them there.
    * **Doors** — each linked door, unlinked through `person.unlink_door`;
      a GitHub or Google door linked through a device flow that answers a
      link ticket (`Sanctum.Auth.DeviceFlow`'s `poll_for_link/4`), and an
      OpenID Connect door through `POST /auth/link/oidcc`, whose callback
      leaves the ticket in the cookie session for this page to present
      (`person.link_door`) when it loads. A ticket from the session that
      no longer links (spent by this page's earlier load, or past its ten
      minutes) is dropped without a word.
    * **Passkeys** — registered through `passkey.register` and the system
      layer's `webauthn:create` ceremony, listed, and revoked through
      `passkey.revoke`.

  The refusals each change can meet, the last door and the last passkey
  among them, are shown as the refusal's own sentence.

  The identity controls carry `data-test` names: `identity` (with
  `data-provenance` and `data-enrollment`), `identity-identifier`,
  `identity-directory`, `identity-no-directory`, `identity-remote`,
  `identity-enroll`, `identity-abandon`, `identity-kit` (with
  `data-attempt`),
  `identity-kit-show`, `identity-add-kit`, `identity-rotate`,
  `identity-rotation`; `doors`, `door` (with `data-key`), `door-unlink`,
  `door-link-github`, `door-link-google`, `door-link-oidcc`,
  `door-link-flow`, `door-link-code`, `door-link-cancel`; `passkeys`,
  `passkey` (with `data-id` and `data-state`), `passkey-register` and
  `passkey-revoke`.
  """

  use PrismWeb, :live_view

  require Logger

  alias PrismWeb.SystemLayer
  alias PrismWeb.SystemLayer.Recovery
  alias Sanctum.Auth.DeviceFlow

  @default_link_poll_s 5

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      actor = Sanctum.Context.actor(socket.assigns[:context])
      Cyfr.Bus.subscribe(actor, Cyfr.Bus.requests(actor))
    end

    if connected?(socket) and socket.assigns.context.platform_admin do
      Cyfr.Bus.subscribe_global(Cyfr.Bus.platform_notify())
      Cyfr.Bus.subscribe_global(Cyfr.Bus.settings_changed())
    end

    socket =
      socket
      |> assign(:page_title, "Settings")
      |> assign(:active_nav, "settings")
      |> assign(:system_status, nil)
      |> assign(:log_stats, %{total: 0, errors: 0, avg_duration_ms: 0, error_rate: 0.0})
      |> assign(:door_entries, [])
      |> assign(:door_requests, [])
      |> assign(:door_value, "")
      |> assign(:door_note, "")
      |> assign(:platform_settings, [])
      |> assign(:settings_revision, nil)
      |> assign(:settings_members, [])
      |> assign(:settings_ttl_ms, nil)
      |> assign(:mode, Prism.Labels.default(socket.assigns.context))
      |> assign(:loading, true)
      |> assign(:identity, nil)
      |> assign(:identity_error, nil)
      |> assign(:enrolling, nil)
      |> assign(:passkeys, nil)
      |> assign(:passkeys_error, nil)
      |> assign(:link_flow, nil)
      |> assign(:link_ticket, session_ticket(session))
      |> assign(:client_ip, PrismWeb.AuthHelpers.socket_client_ip(socket))
      |> assign(:device_providers, DeviceFlow.configured_providers())
      |> assign(:oidc_door, is_binary(Sanctum.Auth.OIDC.issuer()))

    {:ok, socket}
  end

  # The ticket an OpenID Connect link's callback left in the cookie session
  # for this page to present (`PrismWeb.AuthController.link_ticket_key/0`).
  defp session_ticket(%{} = session) do
    case Map.get(session, PrismWeb.AuthController.link_ticket_key()) do
      %{"provider" => provider, "ticket" => ticket}
      when is_binary(provider) and is_binary(ticket) ->
        %{provider: provider, ticket: ticket}

      _none ->
        nil
    end
  end

  defp session_ticket(_session), do: nil

  @impl true
  def handle_params(_params, _uri, socket) do
    # Paint first — the system-status load probes the registry.
    if connected?(socket), do: send(self(), :load)
    {:noreply, socket}
  end

  @impl true
  def handle_event("door_form_changed", params, socket) do
    {:noreply,
     socket
     |> assign(:door_value, Map.get(params, "value", socket.assigns.door_value))
     |> assign(:door_note, Map.get(params, "note", socket.assigns.door_note))}
  end

  def handle_event("door_allow", %{"value" => value} = params, socket) do
    door_call(socket, "door/allow", %{"value" => value, "note" => params["note"]}, "Allowed.")
  end

  def handle_event("door_deny", %{"value" => value} = params, socket) do
    door_call(socket, "door/deny", %{"value" => value, "note" => params["note"]}, "Denied.")
  end

  def handle_event("door_remove", %{"id" => id}, socket) do
    door_call(socket, "door/remove", %{"id" => id}, "Entry removed.")
  end

  def handle_event("door_resolve", %{"id" => id, "decision" => decision}, socket) do
    door_call(socket, "door/resolve", %{"id" => id, "decision" => decision}, "Request resolved.")
  end

  # A change is made against the store revision the card was listed at,
  # so an operator who saved on another member since is not overwritten:
  # the write is refused and the card lists again.
  def handle_event("setting_save", %{"key" => key, "value" => value}, socket) do
    args = %{"key" => key, "value" => value, "revision" => socket.assigns.settings_revision}
    setting_call(socket, "settings/set", args, "#{key} saved.")
  end

  def handle_event("setting_reset", %{"key" => key}, socket) do
    args = %{"key" => key, "revision" => socket.assigns.settings_revision}
    setting_call(socket, "settings/reset", args, "#{key} reset to its default.")
  end

  # ---- identity --------------------------------------------------------------

  def handle_event("enroll", _params, socket), do: enroll(socket)

  # An enrollment whose seed no prompt here holds: abandoned, then begun
  # again under a new kit.
  def handle_event("abandon_enrollment", _params, socket) do
    case call_tool(socket, "person/enroll_abandon", %{}) do
      {:ok, _abandoned} ->
        socket
        |> load_identity()
        |> put_flash(:info, "The unfinished enrollment was abandoned.")
        |> enroll()

      {:error, reason} ->
        {:noreply, socket |> load_identity() |> put_flash(:error, error_message(reason))}
    end
  end

  def handle_event("show_kit", %{"attempt" => attempt_id}, socket),
    do: show_recovery(socket, &Recovery.kit(&1, attempt_id))

  def handle_event("add_kit", _params, socket), do: show_recovery(socket, &Recovery.holder/1)

  # A rotation in progress is finished under its own request id; otherwise
  # a new one begins.
  def handle_event("rotate", _params, socket) do
    request_id =
      case socket.assigns.identity do
        %{rotation: %{request_id: id}} when is_binary(id) -> id
        _none -> new_request_id("rot")
      end

    rotate(socket, request_id)
  end

  # ---- doors -----------------------------------------------------------------

  def handle_event("link_device", %{"provider" => provider}, socket)
      when provider in ["github", "google"] do
    start_link_flow(socket, String.to_existing_atom(provider))
  end

  def handle_event("link_cancel", _params, socket),
    do: {:noreply, assign(socket, :link_flow, nil)}

  def handle_event("unlink", %{"key" => key}, socket), do: unlink(socket, key)

  # ---- passkeys --------------------------------------------------------------

  # The home's creation options, handed to the browser through the system
  # layer's ceremony; the answer comes back as `:system_layer_passkey`.
  def handle_event("passkey_register", _params, socket) do
    case call_tool(socket, "passkey/register", %{}) do
      {:ok, %{public_key: public_key, registration: registration}} ->
        {:noreply, SystemLayer.create_passkey(socket, public_key, registration)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Passkey: #{error_message(reason)}")}
    end
  end

  def handle_event("passkey_revoke", %{"id" => id}, socket), do: revoke_passkey(socket, id)

  def handle_event("set_mode", %{"mode" => mode}, socket) when mode in ["lite", "dev"] do
    case Sanctum.Tenancy.Users.get(socket.assigns.context.user_id) do
      {:ok, user} ->
        # Show storage errors without closing the settings page.
        case Sanctum.Tenancy.Users.put_prefs(user, %{"mode" => mode}) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:mode, mode)
             |> assign(:ui_mode, mode)
             |> put_flash(:info, "Mode saved.")}

          {:error, reason} ->
            Logger.warning("[SettingsLive] could not save mode: #{inspect(reason)}")
            {:noreply, put_flash(socket, :error, "Couldn't save that just now.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Could not save the preference.")}
    end
  end

  @impl true
  def handle_info(:load, socket) do
    socket =
      socket
      |> load_system_status()
      |> load_log_stats()
      |> load_door()
      |> load_settings()
      |> load_prefs()
      |> load_identity()
      |> load_passkeys()
      |> assign(:loading, false)

    case socket.assigns.link_ticket do
      %{provider: provider, ticket: ticket} ->
        link(assign(socket, :link_ticket, nil), provider, ticket, from_session: true)

      nil ->
        {:noreply, socket}
    end
  end

  # A change this page asked for was confirmed: made again, once. A
  # recovery prompt that ended leaves the identity to be read again.
  def handle_info({:system_layer, prompt_id, _outcome} = report, socket) do
    case SystemLayer.reported(socket, report) do
      {:repeat, :rotate, _tool, %{"request_id" => id}, socket} ->
        rotate(socket, id)

      {:repeat, {:link, provider}, _tool, %{"ticket" => ticket}, socket} ->
        link(socket, provider, ticket, [])

      {:repeat, {:unlink, key}, _tool, _args, socket} ->
        unlink(socket, key)

      {:repeat, :passkey_register, _tool, %{"credential" => credential}, socket} ->
        register_passkey(socket, credential)

      {:repeat, {:passkey_revoke, id}, _tool, _args, socket} ->
        revoke_passkey(socket, id)

      {:ok, socket} ->
        if recovery_prompt?(prompt_id),
          do: {:noreply, socket |> recovery_ended(report) |> load_identity()},
          else: {:noreply, socket}
    end
  end

  def handle_info({:system_layer_passkey, {:ok, credential}}, socket),
    do: register_passkey(socket, credential)

  def handle_info({:system_layer_passkey, :error}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "The passkey was not created in this browser. Nothing was registered."
     )}
  end

  def handle_info(:link_poll, socket) do
    case socket.assigns.link_flow do
      %{} = flow -> poll_link_flow(socket, flow)
      nil -> {:noreply, socket}
    end
  end

  def handle_info(%Cyfr.Bus.Request{}, socket) do
    {:noreply, load_log_stats(socket)}
  end

  def handle_info(%Cyfr.Bus.Notify{athanor_id: :platform, kind: kind}, socket)
      when kind in [:allowlist_request, :allowlist_changed] do
    {:noreply, load_door(socket)}
  end

  def handle_info(%Cyfr.Bus.SettingsChanged{kind: :changed}, socket) do
    {:noreply, load_settings(socket)}
  end

  def handle_info(%Cyfr.Bus.SettingsChanged{kind: :observed}, socket), do: {:noreply, socket}

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  defp load_system_status(socket) do
    case call_tool(socket, "system/status", %{}) do
      {:ok, status} -> assign(socket, :system_status, status)
      {:error, _} -> assign(socket, :system_status, %{})
    end
  end

  defp load_log_stats(socket) do
    case call_tool(socket, "mcp_log", %{"action" => "stats"}) do
      {:ok, stats} ->
        assign(socket, :log_stats, %{
          total: stats[:total] || 0,
          errors: stats[:errors] || 0,
          avg_duration_ms: stats[:avg_duration_ms] || 0,
          error_rate: stats[:error_rate] || 0.0
        })

      _ ->
        socket
    end
  end

  defp door_call(socket, tool, args, ok_message) do
    case call_tool(socket, tool, args) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:door_value, "")
         |> assign(:door_note, "")
         |> load_door()
         |> put_flash(:info, ok_message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Door: #{error_message(reason)}")}
    end
  end

  # The door is the platform admin's; everyone else sees no section.
  defp load_door(%{assigns: %{context: %{platform_admin: true}}} = socket) do
    entries =
      case call_tool(socket, "door/list", %{}) do
        {:ok, %{entries: entries}} -> Enum.reject(entries, &(&1.status == "requested"))
        _ -> []
      end

    requests =
      case call_tool(socket, "door/requests", %{}) do
        {:ok, %{requests: requests}} -> requests
        _ -> []
      end

    socket |> assign(:door_entries, entries) |> assign(:door_requests, requests)
  end

  # A socket whose capability went since it read the door drops what it read.
  defp load_door(socket), do: socket |> assign(:door_entries, []) |> assign(:door_requests, [])

  defp setting_call(socket, tool, args, ok_message) do
    args = if is_nil(args["revision"]), do: Map.delete(args, "revision"), else: args

    case call_tool(socket, tool, args) do
      {:ok, _} ->
        {:noreply, socket |> load_settings() |> put_flash(:info, ok_message)}

      {:error, reason} ->
        {:noreply,
         socket |> load_settings() |> put_flash(:error, "Settings: #{error_message(reason)}")}
    end
  end

  # The platform settings are the operator's, like the door.
  defp load_settings(%{assigns: %{context: %{platform_admin: true}}} = socket) do
    case call_tool(socket, "settings/list", %{}) do
      {:ok, %{settings: settings} = listing} ->
        socket
        |> assign(:platform_settings, settings)
        |> assign(:settings_revision, listing.revision)
        |> assign(:settings_members, listing.members)
        |> assign(:settings_ttl_ms, listing.ttl_ms)

      _ ->
        assign(socket, :platform_settings, [])
    end
  end

  defp load_settings(socket), do: assign(socket, :platform_settings, [])

  defp setting_text(nil), do: "none"
  defp setting_text(value) when is_binary(value), do: value
  defp setting_text(value), do: to_string(value)

  defp input_text(nil), do: ""
  defp input_text(value), do: setting_text(value)

  defp source_color("deployment"), do: "yellow"
  defp source_color("operator"), do: "blue"
  defp source_color(_default), do: "gray"

  defp bound_seconds(nil), do: "-"
  defp bound_seconds(ms), do: "#{div(ms, 1000)} s"

  defp load_prefs(socket) do
    ctx = socket.assigns.context

    case Sanctum.Tenancy.Users.get(ctx.user_id) do
      {:ok, user} ->
        assign(socket, :mode, Prism.Labels.mode(Sanctum.Tenancy.Users.prefs(user)["mode"], ctx))

      _ ->
        socket
    end
  end

  # ---- identity --------------------------------------------------------------

  defp load_identity(socket) do
    case call_tool(socket, "person/status", %{}) do
      {:ok, status} -> assign(socket, identity: status, identity_error: nil)
      {:error, reason} -> assign(socket, identity: nil, identity_error: error_message(reason))
    end
  end

  # The enrollment prompt, at the directory this home pins. Until it ends,
  # its seed is held there, so no abandonment is offered beside it.
  defp enroll(socket) do
    case socket.assigns.identity do
      %{directory_url: url} when is_binary(url) ->
        show_recovery(socket, &Recovery.enrollment(&1, url), :enrolling)

      _no_directory ->
        {:noreply, put_flash(socket, :error, no_directory_sentence())}
    end
  end

  # A recovery prompt, under an id of this page's own, in the page's layer;
  # `remember` names the assign that holds its id while it is open.
  defp show_recovery(socket, build, remember \\ nil) do
    prompt_id = "recovery-" <> Integer.to_string(System.unique_integer([:positive]))

    case build.(prompt_id) do
      {:ok, prompt} ->
        SystemLayer.show(SystemLayer.layer_id(), prompt)
        {:noreply, if(remember, do: assign(socket, remember, prompt_id), else: socket)}

      {:error, :invalid_prompt} ->
        {:noreply, put_flash(socket, :error, "That cannot be shown here.")}
    end
  end

  defp recovery_prompt?("recovery-" <> _rest), do: true
  defp recovery_prompt?(_prompt_id), do: false

  # A refused prompt stays open; a confirmed or dismissed one has ended,
  # and with it whatever seed it held.
  defp recovery_ended(socket, {:system_layer, _id, {:refused, _reason}}), do: socket

  defp recovery_ended(%{assigns: %{enrolling: id}} = socket, {:system_layer, id, _ended}),
    do: assign(socket, :enrolling, nil)

  defp recovery_ended(socket, _report), do: socket

  defp new_request_id(prefix),
    do: prefix <> "_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp no_directory_sentence,
    do:
      "This home names no identity directory, so nobody enrolls here yet: its operator sets " <>
        "CYFR_DIRECTORY_URL. Everything else, local pairing included, works without it."

  defp rotate(socket, request_id) do
    case SystemLayer.call(socket, :rotate, "person/rotate", %{"request_id" => request_id}) do
      {:ok, %{phase: "completed"}, socket} ->
        {:noreply, socket |> load_identity() |> put_flash(:info, "Your live key was rotated.")}

      {:ok, %{phase: phase}, socket} ->
        {:noreply,
         socket
         |> load_identity()
         |> put_flash(:info, "The rotation stands at #{phase}; rotate again to finish it.")}

      {:asked, socket} ->
        {:noreply, socket}

      {:error, reason, socket} ->
        {:noreply, socket |> load_identity() |> put_flash(:error, error_message(reason))}
    end
  end

  # ---- doors -----------------------------------------------------------------

  defp start_link_flow(socket, provider) do
    case DeviceFlow.impl().init_device_flow(provider, socket.assigns.client_ip) do
      {:ok, info} ->
        interval = info[:interval] || @default_link_poll_s
        if connected?(socket), do: schedule_link_poll(interval)

        flow = %{
          provider: provider,
          device_code: info.device_code,
          user_code: info.user_code,
          verification_uri: info.verification_uri,
          interval: interval
        }

        {:noreply, assign(socket, :link_flow, flow)}

      {:error, {:client_id_not_configured, _provider}} ->
        {:noreply, put_flash(socket, :error, "#{provider} is not configured on this server.")}

      {:error, reason} ->
        Logger.warning(
          "[SettingsLive] a door link's device flow did not start: " <>
            Prima.LoggerContext.shape(reason)
        )

        {:noreply, put_flash(socket, :error, "Couldn't start linking. Try again in a moment.")}
    end
  end

  defp schedule_link_poll(seconds), do: Process.send_after(self(), :link_poll, seconds * 1000)

  # The provider's answer is a link ticket bound to this person and this
  # session, never a session: the page presents it to `person.link_door`.
  defp poll_link_flow(socket, flow) do
    answer =
      DeviceFlow.impl().poll_for_link(
        flow.provider,
        flow.device_code,
        socket.assigns.client_ip,
        socket.assigns.context
      )

    case answer do
      {:ok, %{status: "pending"} = result} ->
        interval = if result[:slow_down], do: flow.interval + 5, else: flow.interval
        schedule_link_poll(interval)
        {:noreply, assign(socket, :link_flow, %{flow | interval: interval})}

      {:ok, %{status: "complete", provider: provider, ticket: ticket}} ->
        link(assign(socket, :link_flow, nil), provider, ticket, [])

      {:ok, %{status: "expired"}} ->
        {:noreply,
         socket |> assign(:link_flow, nil) |> put_flash(:error, "The code expired. Link again.")}

      {:ok, %{status: "denied"}} ->
        {:noreply,
         socket
         |> assign(:link_flow, nil)
         |> put_flash(:error, "The provider was not authorized, so nothing was linked.")}

      {:error, {:door, _reason}} ->
        {:noreply,
         socket |> assign(:link_flow, nil) |> put_flash(:error, Sanctum.Door.refusal_message())}

      {:error, reason} ->
        {:noreply,
         socket |> assign(:link_flow, nil) |> put_flash(:error, "Door: #{error_message(reason)}")}
    end
  end

  defp link(socket, provider, ticket, opts) do
    args = %{"provider" => provider, "ticket" => ticket}

    case SystemLayer.call(socket, {:link, provider}, "person/link_door", args) do
      {:ok, %{linked: true, door: door}, socket} ->
        {:noreply,
         socket
         |> load_identity()
         |> put_flash(:info, "Linked #{door.provider} sign-in #{door.subject}.")}

      {:ok, %{linked: false}, socket} ->
        {:noreply, put_flash(socket, :info, "That sign-in is already one of your doors.")}

      {:asked, socket} ->
        {:noreply, socket}

      {:error, reason, socket} ->
        # A ticket the session still held from a link this page already
        # presented, or one past its ten minutes: nothing to say.
        if Keyword.get(opts, :from_session, false) and match?({:invalid_argument, _}, reason),
          do: {:noreply, socket},
          else: {:noreply, put_flash(socket, :error, "Door: #{error_message(reason)}")}
    end
  end

  defp unlink(socket, key) do
    case SystemLayer.call(socket, {:unlink, key}, "person/unlink_door", %{"door" => key}) do
      {:ok, %{unlinked: door}, socket} ->
        {:noreply,
         socket
         |> load_identity()
         |> put_flash(:info, "Unlinked #{door.provider} sign-in #{door.subject}.")}

      {:asked, socket} ->
        {:noreply, socket}

      {:error, reason, socket} ->
        {:noreply, put_flash(socket, :error, "Door: #{error_message(reason)}")}
    end
  end

  # ---- passkeys --------------------------------------------------------------

  defp load_passkeys(socket) do
    case call_tool(socket, "passkey/list", %{}) do
      {:ok, %{passkeys: passkeys}} -> assign(socket, passkeys: passkeys, passkeys_error: nil)
      {:error, reason} -> assign(socket, passkeys: nil, passkeys_error: error_message(reason))
    end
  end

  defp register_passkey(socket, credential) do
    args = %{"credential" => credential}

    case SystemLayer.call(socket, :passkey_register, "passkey/register", args) do
      {:ok, %{status: "active"}, socket} ->
        {:noreply, socket |> load_passkeys() |> put_flash(:info, "Passkey registered.")}

      {:ok, %{status: "awaiting_administrator"}, socket} ->
        {:noreply,
         socket
         |> load_passkeys()
         |> put_flash(
           :info,
           "This home's platform administrator authorizes this passkey before it counts here."
         )}

      {:ok, _other, socket} ->
        {:noreply, load_passkeys(socket)}

      {:asked, socket} ->
        {:noreply, socket}

      {:error, reason, socket} ->
        {:noreply, put_flash(socket, :error, "Passkey: #{error_message(reason)}")}
    end
  end

  defp revoke_passkey(socket, id) do
    case SystemLayer.call(socket, {:passkey_revoke, id}, "passkey/revoke", %{"passkey_id" => id}) do
      {:ok, _revoked, socket} ->
        {:noreply, socket |> load_passkeys() |> put_flash(:info, "Passkey revoked.")}

      {:asked, socket} ->
        {:noreply, socket}

      {:error, reason, socket} ->
        {:noreply, put_flash(socket, :error, "Passkey: #{error_message(reason)}")}
    end
  end

  defp short(hash) when is_binary(hash), do: String.slice(hash, 0, 16) <> "…"

  defp services_map(nil), do: %{}
  defp services_map(services) when is_map(services), do: services
  defp services_map(_), do: %{}

  defp service_dot("ok"), do: "bg-green-400"
  defp service_dot("error"), do: "bg-red-400"
  defp service_dot("degraded"), do: "bg-yellow-400"
  defp service_dot(_), do: "bg-gray-400"

  defp format_uptime(nil), do: "-"

  defp format_uptime(seconds) when is_number(seconds) do
    cond do
      seconds >= 86400 ->
        days = div(trunc(seconds), 86400)
        hours = div(rem(trunc(seconds), 86400), 3600)
        "#{days}d #{hours}h"

      seconds >= 3600 ->
        hours = div(trunc(seconds), 3600)
        mins = div(rem(trunc(seconds), 3600), 60)
        "#{hours}h #{mins}m"

      seconds >= 60 ->
        mins = div(trunc(seconds), 60)
        secs = rem(trunc(seconds), 60)
        "#{mins}m #{secs}s"

      true ->
        "#{trunc(seconds)}s"
    end
  end

  defp format_uptime(_), do: "-"

  @impl true
  def render(assigns) do
    services = services_map(f(assigns.system_status, :services))
    mcp = f(assigns.system_status, :mcp) || %{}

    assigns =
      assigns
      |> assign(:services, services)
      |> assign(:mcp, mcp)

    ~H"""
    <div class="space-y-6">
      <.page_header title="Settings">
        <:actions>
          <.link
            href={~p"/auth/logout"}
            method="post"
            class="inline-flex items-center gap-2 rounded-lg px-4 py-2 text-sm font-medium bg-gray-700 text-gray-200 hover:bg-gray-600 transition-colors"
          >
            <.icon name="logout" class="h-4 w-4" /> Sign Out
          </.link>
        </:actions>
      </.page_header>

      <div :if={@loading} class="text-center text-gray-500 py-12">Loading...</div>

      <div :if={!@loading} class="space-y-6">
        <.identity_card
          identity={@identity}
          error={@identity_error}
          remote={remote?(@identity)}
          enrolling={@enrolling}
        />

        <.doors_card
          identity={@identity}
          link_flow={@link_flow}
          device_providers={@device_providers}
          oidc_door={@oidc_door}
          return_to={PrismWeb.Focus.path(@athanor_route, "/settings")}
        />

        <.passkeys_card passkeys={@passkeys} error={@passkeys_error} />
        
    <!-- System Status -->
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-4">System Status</h3>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div>
              <dt class="text-xs text-gray-500 uppercase">Version</dt>
              <dd class="text-2xl font-bold text-white mt-1">
                {f(@system_status, :version) || "-"}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Uptime</dt>
              <dd class="text-2xl font-bold text-white mt-1">
                {format_uptime(f(@system_status, :uptime_seconds))}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">MCP Protocol</dt>
              <dd class="text-sm text-white mt-1 font-mono">
                {f(@mcp, :protocol_version) || "-"}
              </dd>
              <dd class="text-xs text-gray-500 mt-0.5">
                {f(@mcp, :tools_count) || 0} tools, {f(@mcp, :resources_count) ||
                  0} resources
              </dd>
            </div>
          </div>
        </.card>
        
    <!-- Services -->
        <.card :if={@services != %{}}>
          <h3 class="text-sm font-medium text-gray-400 mb-4">Services</h3>
          <div class="flex flex-wrap gap-x-4 gap-y-2">
            <%= for {name, status} <- Enum.sort(@services) do %>
              <span class="flex items-center gap-1.5">
                <span class={["h-2 w-2 rounded-full", service_dot(to_string(status))]} />
                <span class="text-sm text-gray-300">{name}</span>
              </span>
            <% end %>
          </div>
        </.card>
        
    <!-- Request Metrics -->
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-4">Request Metrics (1h)</h3>
          <div class="grid grid-cols-3 gap-4">
            <div>
              <dt class="text-xs text-gray-500 uppercase">Total Requests</dt>
              <dd class="text-2xl font-bold text-white mt-1">{@log_stats.total}</dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Error Rate</dt>
              <dd class={"text-2xl font-bold mt-1 #{if @log_stats.error_rate > 0, do: "text-red-400", else: "text-green-400"}"}>
                {@log_stats.error_rate}%
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Avg Duration</dt>
              <dd class="text-2xl font-bold text-white mt-1">{@log_stats.avg_duration_ms}ms</dd>
            </div>
          </div>
        </.card>
        
    <!-- The door: who may sign in (platform admins) -->
        <.card :if={@context.platform_admin}>
          <h3 class="text-sm font-medium text-gray-400 mb-1">Server allowlist — the door</h3>
          <p class="text-xs text-gray-500 mb-4">
            Who may sign in here. An email, an IdP subject, or <code>*</code>
            for anyone the provider authenticates. A deny is sticky and ejects the person.
          </p>

          <div :if={@door_requests != []} class="mb-4">
            <h4 class="text-xs text-gray-500 uppercase mb-2">Requests</h4>
            <.table id="door-requests" rows={@door_requests}>
              <:col :let={r} label="Email">{r.value}</:col>
              <:col :let={r} label="Asked by">{r.requested_by || "-"}</:col>
              <:col :let={r} label="Actions">
                <div class="flex gap-2">
                  <.button
                    variant="ghost"
                    phx-click="door_resolve"
                    phx-value-id={r.id}
                    phx-value-decision="allow"
                  >
                    Allow
                  </.button>
                  <.button
                    variant="ghost"
                    phx-click="door_resolve"
                    phx-value-id={r.id}
                    phx-value-decision="reject"
                  >
                    Reject
                  </.button>
                </div>
              </:col>
            </.table>
          </div>

          <div :if={@door_entries == []} class="py-4">
            <.empty_state message="Only the platform admins can sign in — the list is empty" />
          </div>
          <.table :if={@door_entries != []} id="door-entries" rows={@door_entries}>
            <:col :let={e} label="Entry">{e.value}</:col>
            <:col :let={e} label="Kind">{e.kind}</:col>
            <:col :let={e} label="Effect">
              <.badge color={if e.effect == "allow", do: "green", else: "red"}>{e.effect}</.badge>
            </:col>
            <:col :let={e} label="Note">{e.note || "-"}</:col>
            <:col :let={e} label="Actions">
              <.button variant="ghost" phx-click="door_remove" phx-value-id={e.id}>
                Remove
              </.button>
            </:col>
          </.table>

          <form phx-change="door_form_changed" class="mt-4 space-y-2">
            <div class="flex gap-2 items-end">
              <div class="flex-1">
                <.input name="value" value={@door_value} required placeholder="email, subject, or *" />
              </div>
              <div class="flex-1">
                <.input name="note" value={@door_note} placeholder="note (optional)" />
              </div>
              <.button
                type="button"
                phx-click="door_allow"
                phx-value-value={@door_value}
                phx-value-note={@door_note}
              >
                Allow
              </.button>
              <.button
                type="button"
                variant="ghost"
                phx-click="door_deny"
                phx-value-value={@door_value}
                phx-value-note={@door_note}
                data-confirm="Deny this person? Their sessions and keys are revoked."
              >
                Deny
              </.button>
            </div>
          </form>
        </.card>
        
    <!-- The platform settings (platform admins) -->
        <.card :if={@context.platform_admin and @platform_settings != []}>
          <h3 class="text-sm font-medium text-gray-400 mb-1">Platform settings</h3>
          <p class="text-xs text-gray-500 mb-1">
            A live change reaches new and refreshed work, not work already in flight, on
            every member within {bound_seconds(@settings_ttl_ms)}. A restart setting is
            applied at each member's next start and is pending until then. The stream
            limits (subscriptions and execution events) and the rate limits are counted
            per member: each member admits up to the limit on its own.
          </p>
          <p class="text-xs text-gray-500 mb-4" id="settings-revision">
            Store revision {@settings_revision || "-"} · observed:
            <span :for={m <- @settings_members} class="mr-2">
              {m.member} ({m.revision || "unknown"})
            </span>
          </p>
          <.table id="platform-settings" rows={@platform_settings}>
            <:col :let={s} label="Setting">
              <span class="font-mono">{s.key}</span>
              <span :if={s.variable} class="block text-xs text-gray-500">{s.variable}</span>
            </:col>
            <:col :let={s} label="Value">
              {setting_text(s.value)}
              <.badge :if={s.pending} color="yellow">pending {setting_text(s.desired)}</.badge>
            </:col>
            <:col :let={s} label="Default">{setting_text(s.default)}</:col>
            <:col :let={s} label="Source">
              <.badge color={source_color(s.source)}>{s.source}</.badge>
              <span :if={s.divergent} class="block text-xs text-yellow-400">
                pinned on {Enum.map_join(s.pins, ", ", & &1.member)} only
              </span>
            </:col>
            <:col :let={s} label="Change">
              <span :if={s.source == "deployment"} class="text-xs text-gray-500">
                set by the deployment
              </span>
              <form
                :if={s.source != "deployment"}
                id={"setting-" <> s.key}
                phx-submit="setting_save"
                class="flex gap-2 items-end"
              >
                <input type="hidden" name="key" value={s.key} />
                <.input name="value" value={input_text(s.desired)} />
                <.button type="submit" variant="ghost">Save</.button>
                <.button
                  :if={s.source == "operator"}
                  type="button"
                  variant="ghost"
                  phx-click="setting_reset"
                  phx-value-key={s.key}
                >
                  Reset
                </.button>
              </form>
            </:col>
          </.table>
        </.card>
        
    <!-- Preferences -->
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-4">Preferences</h3>
          <div class="flex items-center gap-3">
            <span class="text-sm text-gray-300">Mode</span>
            <.button
              :for={m <- ["lite", "dev"]}
              variant={if @mode == m, do: "primary", else: "ghost"}
              phx-click="set_mode"
              phx-value-mode={m}
            >
              {m}
            </.button>
          </div>
        </.card>
        
    <!-- User Profile -->
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-4">User Profile</h3>
          <dl class="grid grid-cols-2 gap-4">
            <div>
              <dt class="text-xs text-gray-500 uppercase">Namespace</dt>
              <dd class="text-sm text-white mt-1">
                {assigns[:personal_namespace_slug] || "(not claimed)"}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Email</dt>
              <dd class="text-sm text-white mt-1">{@context.email || "-"}</dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Provider</dt>
              <dd class="text-sm text-white mt-1">{@context.provider}</dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Auth Method</dt>
              <dd class="text-sm text-white mt-1">{@context.auth_method || "-"}</dd>
            </div>
            <div class="col-span-2">
              <dt class="text-xs text-gray-500 uppercase">User ID</dt>
              <dd class="text-xs text-gray-400 mt-1 font-mono break-all">{@context.user_id}</dd>
            </div>
          </dl>
        </.card>
      </div>

      <.live_component module={SystemLayer} id={SystemLayer.layer_id()} context={@context} />
    </div>
    """
  end

  defp remote?(%{provenance: "remote"}), do: true
  defp remote?(_identity), do: false

  attr :identity, :map, default: nil
  attr :error, :string, default: nil
  attr :remote, :boolean, required: true
  attr :enrolling, :string, default: nil

  # The person's identity: who holds their keys, the identifier and the
  # directory, the kits not yet saved, and what they can do here.
  defp identity_card(assigns) do
    ~H"""
    <.card>
      <section
        data-test="identity"
        data-provenance={@identity && @identity.provenance}
        data-enrollment={@identity && @identity.enrollment}
        class="space-y-3"
      >
        <h3 class="text-sm font-medium text-gray-400">Your identity</h3>

        <p :if={@error} role="alert" class="text-sm">{@error}</p>
        <p :if={is_nil(@identity) and is_nil(@error)} class="text-sm text-gray-400">
          Reading your identity.
        </p>

        <div :if={@identity} class="space-y-3">
          <dl class="grid grid-cols-3 gap-2 text-sm">
            <dt class="text-xs text-gray-500 uppercase">Identifier</dt>
            <dd class="col-span-2 font-mono break-all" data-test="identity-identifier">
              {@identity.identifier || "not enrolled"}
            </dd>
            <dt class="text-xs text-gray-500 uppercase">Directory</dt>
            <dd class="col-span-2 break-all" data-test="identity-directory">
              {@identity.directory_url || "none pinned"}
            </dd>
            <dt :if={@identity.key_epoch} class="text-xs text-gray-500 uppercase">Key epoch</dt>
            <dd :if={@identity.key_epoch} class="col-span-2 font-mono" title={@identity.key_epoch}>
              {short(@identity.key_epoch)}
            </dd>
          </dl>

          <p :if={@remote} class="text-sm" data-test="identity-remote">
            Your keys are held at another home, so your identity is enrolled, rotated and recovered there.
          </p>

          <div :if={not @remote} class="space-y-3">
            <p
              :if={@identity.enrollment == "none" and is_nil(@identity.directory_url)}
              class="text-sm"
              data-test="identity-no-directory"
            >
              {no_directory_sentence()}
            </p>

            <div
              :if={@identity.enrollment == "none" and is_binary(@identity.directory_url)}
              class="space-y-2"
            >
              <p class="text-sm text-gray-300">
                You hold keys at this home but no identifier yet. Enrolling registers one at this home's directory and prints the kit that recovers it.
              </p>
              <.button phx-click="enroll" data-test="identity-enroll">Enroll</.button>
            </div>

            <div :if={@identity.enrollment == "pending"} class="space-y-2">
              <p class="text-sm text-gray-300">
                Your enrollment is waiting for the directory's answer.
              </p>
              <div :if={is_nil(@enrolling)} class="space-y-2">
                <p class="text-sm text-gray-300">
                  Only the browser that began it holds its kit. If that browser lost it, abandon it and enroll again with a new kit; a registration the directory may already hold stays there unused.
                </p>
                <.button
                  variant="ghost"
                  phx-click="abandon_enrollment"
                  data-test="identity-abandon"
                >
                  Abandon and start again
                </.button>
              </div>
            </div>

            <ul :if={@identity.kits != []} class="space-y-2">
              <li
                :for={kit <- @identity.kits}
                class="flex items-center justify-between gap-2 text-sm"
                data-test="identity-kit"
                data-attempt={kit.attempt_id}
                data-phase={kit.phase}
              >
                <span :if={kit.deliverable}>
                  A printed kit ({kit_kind(kit)}) waits for you to say it is saved.
                </span>
                <span :if={not kit.deliverable}>
                  A printed kit ({kit_kind(kit)}) is at {kit.phase}; finish it in the prompt that began it.
                </span>
                <.button
                  :if={kit.deliverable}
                  variant="ghost"
                  phx-click="show_kit"
                  phx-value-attempt={kit.attempt_id}
                  data-test="identity-kit-show"
                >
                  Show kit
                </.button>
              </li>
            </ul>

            <div :if={@identity.enrollment == "enrolled"} class="space-y-2">
              <p class="text-sm text-gray-300">
                A printed kit recovers your identity on a fresh installation. A printed kit is the one recovery holder here; no device holds one. Add another before you rely on one: if every kit is lost, nothing can add one.
              </p>
              <p :if={@identity.rotation} class="text-sm" data-test="identity-rotation">
                A rotation of your live key stands at {@identity.rotation.phase}.
              </p>
              <div class="flex flex-wrap gap-2">
                <.button
                  :if={not Enum.any?(@identity.kits, &(&1.kind == "holder"))}
                  variant="ghost"
                  phx-click="add_kit"
                  data-test="identity-add-kit"
                >
                  Add another printed kit
                </.button>
                <.button variant="ghost" phx-click="rotate" data-test="identity-rotate">
                  {if @identity.rotation, do: "Finish the rotation", else: "Rotate the live key"}
                </.button>
              </div>
            </div>
          </div>
        </div>
      </section>
    </.card>
    """
  end

  defp kit_kind(%{kind: "enrollment"}), do: "your first"
  defp kit_kind(%{kind: "holder"}), do: "an added one"
  defp kit_kind(_kit), do: "a kit"

  attr :identity, :map, default: nil
  attr :link_flow, :map, default: nil
  attr :device_providers, :list, required: true
  attr :oidc_door, :boolean, required: true
  attr :return_to, :string, required: true

  # The doors the person signs in through here, and linking another.
  defp doors_card(assigns) do
    assigns = assign(assigns, :doors, (assigns.identity && assigns.identity.doors) || [])

    ~H"""
    <.card>
      <section data-test="doors" class="space-y-3">
        <h3 class="text-sm font-medium text-gray-400">Sign-in doors</h3>
        <p class="text-xs text-gray-500">
          The ways you sign in at this home. Linking or unlinking one needs a fresh confirmation, and a door is linked only by signing in with it, never by a matching email.
        </p>

        <p :if={@doors == []} class="text-sm text-gray-400">No door is linked.</p>
        <ul :if={@doors != []} class="divide-y divide-gray-800 text-sm">
          <li
            :for={door <- @doors}
            class="flex items-center justify-between gap-2 py-2"
            data-test="door"
            data-key={door.key}
          >
            <span>
              <span class="font-medium">{door.provider}</span>
              <span class="text-gray-400 break-all">{door.subject}</span>
            </span>
            <.button
              variant="ghost"
              phx-click="unlink"
              phx-value-key={door.key}
              data-test="door-unlink"
            >
              Unlink
            </.button>
          </li>
        </ul>

        <div :if={@link_flow} class="space-y-1 text-sm" data-test="door-link-flow">
          <p>
            Open <a
              href={@link_flow.verification_uri}
              target="_blank"
              rel="noopener noreferrer"
              class="underline"
            >{@link_flow.verification_uri}</a>, and enter
            <span class="font-mono" data-test="door-link-code">{@link_flow.user_code}</span>
            to link your {@link_flow.provider} sign-in.
          </p>
          <.button variant="ghost" phx-click="link_cancel" data-test="door-link-cancel">
            Cancel
          </.button>
        </div>

        <div :if={is_nil(@link_flow)} class="flex flex-wrap gap-2">
          <.button
            :for={provider <- @device_providers}
            variant="ghost"
            phx-click="link_device"
            phx-value-provider={provider}
            data-test={"door-link-#{provider}"}
          >
            Link {provider_name(provider)}
          </.button>
          <.link
            :if={@oidc_door}
            href={"/auth/link/oidcc?return_to=" <> URI.encode_www_form(@return_to)}
            method="post"
            data-test="door-link-oidcc"
            class="inline-flex items-center rounded-lg px-4 py-2 text-sm font-medium border border-gray-600 text-gray-200 hover:bg-gray-800"
          >
            Link your organization's sign-in
          </.link>
        </div>
      </section>
    </.card>
    """
  end

  defp provider_name(:github), do: "GitHub"
  defp provider_name(:google), do: "Google"
  defp provider_name(other), do: to_string(other)

  attr :passkeys, :list, default: nil
  attr :error, :string, default: nil

  # The person's passkeys at this home.
  defp passkeys_card(assigns) do
    ~H"""
    <.card>
      <section data-test="passkeys" class="space-y-3">
        <h3 class="text-sm font-medium text-gray-400">Passkeys at this home</h3>
        <p class="text-xs text-gray-500">
          A passkey proves it is you, here only: each home registers its own. Registering or revoking one needs a fresh confirmation, except a first one right after you signed in or restored.
        </p>

        <p :if={@error} role="alert" class="text-sm">{@error}</p>
        <p :if={@passkeys == []} class="text-sm text-gray-400">No passkey is registered here.</p>

        <ul :if={@passkeys not in [nil, []]} class="divide-y divide-gray-800 text-sm">
          <li
            :for={passkey <- @passkeys}
            class="flex items-center justify-between gap-2 py-2"
            data-test="passkey"
            data-id={passkey.id}
            data-state={passkey.state}
          >
            <span>
              <span class="font-medium">{passkey.label || "Passkey"}</span>
              <span class="text-gray-400">{passkey_state(passkey)}</span>
            </span>
            <.button
              variant="ghost"
              phx-click="passkey_revoke"
              phx-value-id={passkey.id}
              data-test="passkey-revoke"
            >
              Revoke
            </.button>
          </li>
        </ul>

        <.button phx-click="passkey_register" data-test="passkey-register">
          Register a passkey
        </.button>
      </section>
    </.card>
    """
  end

  defp passkey_state(%{state: "active", registered_at: at}), do: "registered #{at}"
  defp passkey_state(%{state: "pending"}), do: "awaiting this home's administrator"
  defp passkey_state(%{state: state}), do: state
end
