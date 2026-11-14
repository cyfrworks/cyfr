# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SettingsLive do
  @moduledoc """
  Settings: the person's name and identifier, the keys on their account
  and their sessions here, their lite/dev preference, and, for a platform
  admin, the door, the invitations to this CYFR and the platform settings.

  Every change is an operation through the gate.

    * **Your name** — the identity card (`PrismWeb.IdentityCard`): the
      person's name and their account's identifier. A person with no name
      recorded here types the name their account holds, which is recorded
      once cyfr.run says it is theirs (`session.name`). The account itself,
      its keys and its recovery code, are the account pages'.
    * **Keys on your account** — every key of the person's account, as
      its log lists them (`session.list`): a passkey by its maker and the
      date it was added ("Apple Passwords passkey, added 8 Nov 2026"), a
      device by the name its terminal or box gave here, and under each
      key the person's sessions here that it signed, by browser and
      system, when signed in and last seen, each with one **Sign out**
      that ends that session alone (`session.end`), the session this page
      stands on included, which then leaves the page. A sign-out is a
      session's, never a key's: removing a key is the account pages', and
      the card links there.
    * **AQUA's approvals** — how many hours an approval card waits for
      the person's answer before it expires (`athanor.settings`, the
      athanor's `approvals.expiry_hours`), and a link to API Keys.
    * **Decisions about the host** — for the platform administrator, the
      gate's decisions no athanor holds (`decision.list_global`), each
      opened whole (`decision.get_global`).
    * **Invitation links** — the invitations `invitation.list` answers
      the person (every one to the platform administrator, a person's own
      to anyone else), a thread's among them, each by the name it offers,
      the thread it names, its state and expiry, and, while pending,
      revoked (`invitation.revoke`). The administrator also makes one
      naming no thread (`invitation.create` with no `thread_id`),
      offering an optional name: the link is shown once with a copy
      control, and with a sentence when it opens only on this computer
      (`local_only`).

  The refusals each change can meet are shown as the refusal's own
  sentence.

  The identity card's controls carry its own `data-test` names, and this
  page's `keys`, `keys-scope`, `keys-account`, `key` (with `data-kid`),
  `session` (with `data-id`), `session-end`; `invite-cyfr`, `invitation-create`, `invitation-new`,
  `invitation-local`, `invitation-link`, `invitation-copy`, `invitation-name` and `invitation-revoke`.
  """

  use PrismWeb, :live_view

  @behaviour PrismWeb.SystemLayer.Hook
  on_mount PrismWeb.SystemLayer.Hook

  require Logger

  alias Phoenix.LiveView.JS
  alias PrismWeb.{IdentityCard, SystemLayer}

  @impl true
  def mount(_params, _session, socket) do
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
      |> assign(:invitations, [])
      |> assign(:new_link, nil)
      |> assign(:new_link_local, false)
      |> assign(:platform_settings, [])
      |> assign(:approval_hours, nil)
      |> assign(:host_decisions, [])
      |> assign(:host_decision, nil)
      |> assign(:settings_revision, nil)
      |> assign(:settings_members, [])
      |> assign(:settings_ttl_ms, nil)
      |> assign(:mode, Prism.Labels.default(socket.assigns.context))
      |> assign(:loading, true)
      |> assign(:identifier, nil)
      |> assign(:name, socket.assigns.context.namespace)
      |> assign(:name_error, nil)
      |> assign(:keys, nil)
      |> assign(:account_page, nil)
      |> assign(:keys_error, nil)

    {:ok, socket}
  end

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

  # The entry rides in `door`, never `value`: for a click LiveView sends
  # the element's own `value` under that key, a button's being empty, so
  # an entry carried there would reach the home as nothing.
  def handle_event("door_allow", %{"door" => value} = params, socket) do
    door_call(socket, "door/allow", %{"value" => value, "note" => params["note"]}, "Allowed.")
  end

  def handle_event("door_deny", %{"door" => value} = params, socket) do
    door_call(socket, "door/deny", %{"value" => value, "note" => params["note"]}, "Denied.")
  end

  def handle_event("door_remove", %{"id" => id}, socket) do
    door_call(socket, "door/remove", %{"id" => id}, "Entry removed.")
  end

  def handle_event("door_resolve", %{"id" => id, "decision" => decision}, socket) do
    door_call(socket, "door/resolve", %{"id" => id, "decision" => decision}, "Request resolved.")
  end

  # The name the person's account holds, recorded once cyfr.run says so.
  def handle_event("identity_name", %{"name" => name}, socket) when is_binary(name) do
    case call_tool(socket, "session/name", %{"name" => name}) do
      {:ok, %{name: recorded}} ->
        {:noreply, socket |> assign(:name, recorded) |> assign(:name_error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :name_error, error_message(reason))}
    end
  end

  # An invitation to this CYFR, naming no thread: the administrator's.
  def handle_event("invitation_create", params, socket) do
    args =
      case String.trim(Map.get(params, "name", "")) do
        "" -> %{}
        name -> %{"name" => name}
      end

    case call_tool(socket, "invitation/create", args) do
      {:ok, %{invitation_url: link} = answer} ->
        {:noreply,
         socket
         |> assign(:new_link, link)
         |> assign(:new_link_local, Map.get(answer, :local_only, false))
         |> load_invitations()}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not create the link: #{error_message(reason)}")}
    end
  end

  def handle_event("invitation_revoke", %{"id" => id}, socket) do
    case call_tool(socket, "invitation/revoke", %{"invitation_id" => id}) do
      {:ok, _} ->
        {:noreply, socket |> load_invitations() |> put_flash(:info, "Invitation link revoked.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not revoke: #{error_message(reason)}")}
    end
  end

  # A whole number of hours is stored; an empty field removes the stored
  # wait (a `nil` in the patch deletes the key), so AQUA's own default
  # holds again.
  def handle_event("approvals_save", %{"hours" => hours}, socket) do
    case String.trim(hours) do
      "" ->
        approvals_save(socket, nil, "Approvals wait AQUA's default time again.")

      typed ->
        case Integer.parse(typed) do
          {n, ""} when n > 0 ->
            approvals_save(socket, n, "Approvals now wait #{n} hours.")

          _not_hours ->
            {:noreply,
             put_flash(socket, :error, "Not saved: the wait is a whole number of hours.")}
        end
    end
  end

  def handle_event("host_decision", %{"id" => call_id}, socket) do
    case call_tool(socket, "decision/get_global", %{"call_id" => call_id}) do
      {:ok, %{decision: decision}} -> {:noreply, assign(socket, :host_decision, decision)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("host_decision_close", _params, socket),
    do: {:noreply, assign(socket, :host_decision, nil)}

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

  # ---- keys on your account ----------------------------------------------------

  # One session of the person's own, signed out at once; the one this page
  # stands on included, after which the page's guard lets it go.
  def handle_event("session_end", %{"id" => id}, socket) do
    case call_tool(socket, "session/end", %{"session_id" => id}) do
      {:ok, _ended} ->
        {:noreply, socket |> load_keys() |> put_flash(:info, "Signed out.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Sign out: #{error_message(reason)}")}
    end
  end

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

  defp approvals_save(socket, hours, saved) do
    args = %{"settings" => %{"approvals" => %{"expiry_hours" => hours}}}

    case call_tool(socket, "athanor/settings", args) do
      {:ok, _athanor} ->
        {:noreply, socket |> load_approvals() |> put_flash(:info, saved)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Not saved: #{error_message(reason)}")}
    end
  end

  @impl true
  def handle_info(:load, socket) do
    {:noreply,
     socket
     |> load_system_status()
     |> load_log_stats()
     |> load_door()
     |> load_invitations()
     |> load_settings()
     |> load_approvals()
     |> load_host_decisions()
     |> load_prefs()
     |> load_identifier()
     |> load_keys()
     |> assign(:loading, false)}
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
        {:noreply,
         put_flash(socket, :error, "Could not change the allowlist: #{error_message(reason)}")}
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

    socket
    |> assign(:door_entries, entries)
    |> assign(:door_requests, requests)
  end

  # A socket whose capability went since it read the door drops what it read.
  defp load_door(socket),
    do: assign(socket, door_entries: [], door_requests: [])

  # The invitations the person may see, newest first: every one to the
  # administrator, their own to anyone else, a thread's among them.
  defp load_invitations(socket) do
    invitations =
      case call_tool(socket, "invitation/list", %{}) do
        {:ok, %{invitations: invitations}} -> invitations
        _ -> []
      end

    assign(socket, :invitations, invitations)
  end

  # Where an invitation seats its newcomer: the thread's title to a viewer
  # seated there, a thread for anyone else, or this CYFR alone.
  defp invitation_place(%{thread_title: title}), do: title
  defp invitation_place(%{thread_id: _id}), do: "a thread"
  defp invitation_place(_none), do: "this CYFR"

  defp until(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> Calendar.strftime(at, "%-d %b %Y, %H:%M UTC")
      _unparsed -> iso
    end
  end

  # An entry's name, as the door answers it, everyone for `*`, or, while
  # no name is known, the identifier itself.
  defp entry_name(%{kind: "wildcard"}), do: "everyone"
  defp entry_name(%{name: name}), do: "@" <> name
  defp entry_name(%{value: value}), do: value

  # Who asked for a request: the person refused at sign-in themselves, or
  # the member who invited them.
  defp asked_by(%{requested_by: by, value: by}), do: "themselves, at sign-in"
  defp asked_by(%{requested_by: nil}), do: "-"
  defp asked_by(%{asked_by_name: name}), do: "@" <> name
  defp asked_by(%{requested_by: by}), do: by

  # What removing an entry does, asked before it is removed.
  defp remove_question(%{effect: "deny"}),
    do: "Remove this deny? The person may sign in again wherever * or an allow admits them."

  defp remove_question(%{kind: "wildcard"}),
    do:
      "Remove *? Everyone no allow names can no longer sign in, and their sessions and API " <>
        "keys here end."

  defp remove_question(_allow),
    do:
      "Remove this allow? Unless * admits them, the person can no longer sign in, and their " <>
        "sessions and API keys here end."

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

  # How long an approval card waits in the athanor this page stands in,
  # when the person set it; unset, AQUA's own default holds.
  defp load_approvals(socket) do
    hours =
      case call_tool(socket, "athanor/get", %{}) do
        {:ok, %{settings: %{"approvals" => %{"expiry_hours" => hours}}}} when is_integer(hours) ->
          hours

        _unset ->
          nil
      end

    assign(socket, :approval_hours, hours)
  end

  # The host's own decisions, the newest first: the administrator's.
  defp load_host_decisions(%{assigns: %{context: %{platform_admin: true}}} = socket) do
    case call_tool(socket, "decision/list_global", %{"limit" => 20}) do
      {:ok, %{decisions: decisions}} -> assign(socket, :host_decisions, decisions)
      _unread -> assign(socket, :host_decisions, [])
    end
  end

  defp load_host_decisions(socket), do: assign(socket, :host_decisions, [])

  defp decision_outcome(%{"admission" => "refused"} = d),
    do: "refused: " <> (d["reason"] || d["refusal_class"] || "no reason recorded")

  defp decision_outcome(%{"completion" => completion}) when is_binary(completion), do: completion
  defp decision_outcome(_admitted), do: "admitted"

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

  # The account's identifier, as this CYFR's row for the person names it.
  defp load_identifier(socket) do
    case Sanctum.Tenancy.Users.identifier(socket.assigns.context.user_id) do
      {:ok, identifier} -> assign(socket, :identifier, identifier)
      {:error, _unread} -> assign(socket, :identifier, nil)
    end
  end

  # ---- keys on your account ----------------------------------------------------

  defp load_keys(socket) do
    case call_tool(socket, "session/list", %{}) do
      {:ok, %{keys: keys, account_page: page}} ->
        assign(socket, keys: keys, account_page: page, keys_error: nil)

      {:error, reason} ->
        assign(socket, keys: nil, keys_error: error_message(reason))
    end
  end

  # A key as the card reads it: a passkey by its maker, a device by the
  # name it gave here, each with the date it was added.
  defp key_title(%{kind: "passkey", maker: maker} = key) when is_binary(maker),
    do: "#{maker} passkey, added #{day(key.added_at)}"

  defp key_title(%{kind: "passkey"} = key), do: "Passkey, added #{day(key.added_at)}"

  defp key_title(%{name: name} = key) when is_binary(name),
    do: "#{name}, added #{day(key.added_at)}"

  defp key_title(key), do: "Device, added #{day(key.added_at)}"

  defp session_title(%{browser: browser, system: system})
       when is_binary(browser) and is_binary(system),
       do: "#{browser} on #{system}"

  defp session_title(%{browser: browser}) when is_binary(browser), do: browser
  defp session_title(%{system: system}) when is_binary(system), do: system
  defp session_title(_session), do: "A session"

  defp day(iso), do: stamp(iso, "%-d %b %Y")
  defp minute(iso), do: stamp(iso, "%-d %b %Y, %H:%M UTC")

  defp stamp(iso, format) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> Calendar.strftime(at, format)
      _unreadable -> ""
    end
  end

  defp seen(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> PrismWeb.DisplayHelpers.relative_time(at)
      _unreadable -> ""
    end
  end

  # How this page's session signed in, in words: every console session
  # is an account's sign-in in a browser, a passkey's or a device's
  # approval (`Sanctum.Session`).
  defp signed_in_with(:oidc), do: "your account, in this browser"
  defp signed_in_with(:device), do: "a device of your account"
  defp signed_in_with(:api_key), do: "an API key"
  defp signed_in_with(_other), do: "-"

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
        <.card>
          <IdentityCard.card name={@name} identifier={@identifier} error={@name_error} />
        </.card>

        <.keys_card keys={@keys} error={@keys_error} account={@account_page} />

        <%!-- System Status --%>
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

        <%!-- Services --%>
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

        <%!-- The person's own athanor's requests in the last hour --%>
        <.card>
          <section id="request-stats">
            <h3 class="text-sm font-medium text-gray-400 mb-1">Your requests, last hour</h3>
            <p class="text-xs text-gray-500 mb-4">
              The calls made in your own athanor in the last hour, by you, your apps, schedules
              and API keys, and how many failed. Each call, a failed one with its reason, is on
              <.link
                navigate={PrismWeb.Focus.path(assigns[:athanor_route], "/activities")}
                class="underline"
                data-test="activities-link"
              >Activities</.link>
              (dev mode). Nobody's athanor but yours is counted here.
            </p>
            <div class="grid grid-cols-3 gap-4">
              <div>
                <dt class="text-xs text-gray-500 uppercase">Requests</dt>
                <dd class="text-2xl font-bold text-white mt-1">{@log_stats.total}</dd>
              </div>
              <div>
                <dt class="text-xs text-gray-500 uppercase">Failed</dt>
                <dd class={"text-2xl font-bold mt-1 #{if @log_stats.error_rate > 0, do: "text-red-400", else: "text-green-400"}"}>
                  {@log_stats.error_rate}%
                </dd>
              </div>
              <div>
                <dt class="text-xs text-gray-500 uppercase">Average time</dt>
                <dd class="text-2xl font-bold text-white mt-1">{@log_stats.avg_duration_ms}ms</dd>
              </div>
            </div>
          </section>
        </.card>

        <%!-- The door: who may sign in (platform admins) --%>
        <.card :if={@context.platform_admin}>
          <section id="allowlist">
            <h3 class="text-sm font-medium text-gray-400 mb-1">Server allowlist</h3>
            <p class="text-xs text-gray-500 mb-4">
              Who may sign in here. An account signs in when <code>*</code>
              or an allow names it, and a deny wins over both. Setting CYFR up and redeeming
              an invitation allow the account they admit. Allow or deny someone by their name
              (<code>@name</code>): the entry keeps the identifier that name stands for now.
              A deny stays until it is removed and ejects the person: their sessions and API
              keys here end, and their athanor is archived.
            </p>

            <div :if={@door_requests != []} class="mb-4">
              <h4 class="text-xs text-gray-500 uppercase mb-2">Requests</h4>
              <.table id="door-requests" rows={@door_requests}>
                <:col :let={r} label="Name">
                  <span data-test="door-request-name">{entry_name(r)}</span>
                </:col>
                <:col :let={r} label="Identifier">{r.value}</:col>
                <:col :let={r} label="Asked by">{asked_by(r)}</:col>
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
              <.empty_state message="No entries: no account signs in here but by an invitation" />
            </div>
            <.table :if={@door_entries != []} id="door-entries" rows={@door_entries}>
              <:col :let={e} label="Entry">{e.value}</:col>
              <:col :let={e} label="Name">
                <span data-test="door-entry-name">{entry_name(e)}</span>
              </:col>
              <:col :let={e} label="Kind">{e.kind}</:col>
              <:col :let={e} label="Effect">
                <.badge color={if e.effect == "allow", do: "green", else: "red"}>{e.effect}</.badge>
              </:col>
              <:col :let={e} label="Note">{e.note || "-"}</:col>
              <:col :let={e} label="Actions">
                <.button
                  variant="ghost"
                  phx-click="door_remove"
                  phx-value-id={e.id}
                  data-confirm={remove_question(e)}
                >
                  Remove
                </.button>
              </:col>
            </.table>

            <form id="door-entry-form" phx-change="door_form_changed" class="mt-4 space-y-2">
              <div class="flex gap-2 items-end">
                <div class="flex-1">
                  <.input
                    name="value"
                    value={@door_value}
                    required
                    placeholder="@name, or * for everyone"
                  />
                </div>
                <div class="flex-1">
                  <.input name="note" value={@door_note} placeholder="note (optional)" />
                </div>
                <.button
                  type="button"
                  phx-click="door_allow"
                  phx-value-door={@door_value}
                  phx-value-note={@door_note}
                >
                  Allow
                </.button>
                <.button
                  type="button"
                  variant="ghost"
                  phx-click="door_deny"
                  phx-value-door={@door_value}
                  phx-value-note={@door_note}
                  data-confirm="Deny this person? Their sessions and API keys here are revoked, and their athanor archived."
                >
                  Deny
                </.button>
              </div>
            </form>
          </section>
        </.card>

        <%!-- Invitation links: every one to the administrator, a person's own to anyone else --%>
        <.card :if={@context.platform_admin or @invitations != []}>
          <section id="invite-cyfr" data-test="invite-cyfr">
            <h3 class="text-sm font-medium text-gray-400 mb-1">Invitation links</h3>
            <p :if={@context.platform_admin} class="text-xs text-gray-500 mb-4">
              A link makes someone new a person here, with their own athanor. Someone who
              already has a CYFR name signs in with it from the same link. It works once and
              expires after seven days. To bring someone into a thread, invite them from the
              thread; every link, a thread's too, is listed here.
            </p>
            <p :if={!@context.platform_admin} class="text-xs text-gray-500 mb-4">
              The links you made to bring someone into a thread. Each works once and expires
              after seven days.
            </p>

            <div :if={@new_link} data-test="invitation-new" class="mb-4 space-y-2">
              <p class="text-xs text-gray-400">
                Send this link to the person you invite. It is shown only now.
              </p>
              <p :if={@new_link_local} class="text-xs text-yellow-400" data-test="invitation-local">
                This address opens only on this computer. To invite someone on another computer,
                make CYFR reachable there first with <code>cyfr access</code>.
              </p>
              <div class="flex gap-2 items-center">
                <code
                  data-test="invitation-link"
                  class="flex-1 text-xs text-gray-200 bg-gray-800 rounded px-2 py-2 break-all"
                >
                  {@new_link}
                </code>
                <.button
                  variant="ghost"
                  data-test="invitation-copy"
                  phx-click={JS.dispatch("phx:clipboard", detail: %{text: @new_link})}
                >
                  Copy
                </.button>
              </div>
            </div>

            <.table :if={@invitations != []} id="invitation-rows" rows={@invitations}>
              <:col :let={i} label="Their name">
                <span data-test="invitation-name">{i[:name] || "-"}</span>
              </:col>
              <:col :let={i} label="Into">{invitation_place(i)}</:col>
              <:col :let={i} label="State">
                <.badge color={if i[:state] == "pending", do: "green", else: "yellow"}>
                  {i[:state]}
                </.badge>
              </:col>
              <:col :let={i} label="Expires">{until(i[:expires_at])}</:col>
              <:col :let={i} label="Actions">
                <.button
                  :if={i[:state] == "pending"}
                  variant="ghost"
                  phx-click="invitation_revoke"
                  phx-value-id={i[:id]}
                  data-test="invitation-revoke"
                  data-confirm="Revoke this link? It will admit no one."
                >
                  Revoke
                </.button>
              </:col>
            </.table>

            <form
              :if={@context.platform_admin}
              id="invitation-form"
              phx-submit="invitation_create"
              class="mt-4 flex gap-2 items-end"
            >
              <label class="flex-1 text-xs text-gray-500">
                Their name (optional)
                <.input
                  name="name"
                  value=""
                  id="invitation-name"
                  placeholder="filled in on their new account page"
                />
              </label>
              <.button type="submit" data-test="invitation-create">
                Create an invitation link
              </.button>
            </form>
          </section>
        </.card>

        <%!-- The platform settings (platform admins) --%>
        <.card :if={@context.platform_admin and @platform_settings != []}>
          <h3 class="text-sm font-medium text-gray-400 mb-1">Platform settings</h3>
          <p class="text-xs text-gray-500 mb-1">
            A live change reaches new and refreshed work, not work already in flight, on
            every server within {bound_seconds(@settings_ttl_ms)}. A restart setting is
            applied at each server's next start and is pending until then. The stream
            limits (subscriptions and execution events) and the rate limits are counted
            per server: each server admits up to the limit on its own.
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
              <span :if={s[:doc]} class="block text-xs text-gray-400" data-test="setting-doc">
                {s[:doc]}
              </span>
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

        <%!-- How long AQUA's approval cards wait, and where API keys are made --%>
        <.card>
          <section id="approvals">
            <h3 class="text-sm font-medium text-gray-400 mb-1">AQUA's approvals</h3>
            <p class="text-xs text-gray-500 mb-4">
              When AQUA asks before it acts, its card waits this many hours for your answer,
              then expires, and AQUA asks again the next time. Left empty, AQUA's own default
              holds.
            </p>
            <form id="approvals-form" phx-submit="approvals_save" class="flex gap-2 items-end">
              <label class="text-xs text-gray-500">
                Hours
                <.input
                  name="hours"
                  value={@approval_hours}
                  type="number"
                  id="approval-hours"
                  placeholder="default"
                />
              </label>
              <.button type="submit" variant="ghost">Save</.button>
            </form>
            <p class="text-xs text-gray-500 mt-4" data-test="api-keys-link">
              Your own programs and scripts call CYFR as you with an API key: <.link
                navigate={PrismWeb.Focus.path(assigns[:athanor_route], "/api-keys")}
                class="underline"
              >
                API Keys
              </.link>.
            </p>
          </section>
        </.card>

        <%!-- The host's own decisions (platform admins) --%>
        <.card :if={@context.platform_admin}>
          <section id="host-decisions">
            <h3 class="text-sm font-medium text-gray-400 mb-1">Decisions about the host</h3>
            <p class="text-xs text-gray-500 mb-4">
              What the gate admitted or refused outside every athanor: sign-ins, setup and
              the other calls no athanor holds. Each person's own athanor keeps its own, which
              only they read.
            </p>
            <div :if={@host_decisions == []} class="py-2">
              <.empty_state message="No decisions about the host yet" />
            </div>
            <.table :if={@host_decisions != []} id="host-decision-rows" rows={@host_decisions}>
              <:col :let={d} label="When">{until(d["inserted_at"] || "")}</:col>
              <:col :let={d} label="Call">{d["tool"]}{if d["action"], do: "." <> d["action"]}</:col>
              <:col :let={d} label="Outcome">{decision_outcome(d)}</:col>
              <:col :let={d} label="Actions">
                <.button variant="ghost" phx-click="host_decision" phx-value-id={d["call_id"]}>
                  Open
                </.button>
              </:col>
            </.table>
            <div :if={@host_decision} id="host-decision" class="mt-4 space-y-1">
              <dl class="grid grid-cols-2 gap-x-4 gap-y-1 text-xs">
                <%= for {field, value} <- Enum.sort(@host_decision), not is_nil(value) do %>
                  <dt class="text-gray-500">{field}</dt>
                  <dd class="text-gray-200 break-all">{to_string(value)}</dd>
                <% end %>
              </dl>
              <.button variant="ghost" phx-click="host_decision_close">Close</.button>
            </div>
          </section>
        </.card>

        <%!-- Preferences --%>
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-4">Preferences</h3>
          <p id="mode-words" class="text-xs text-gray-500 mb-3">
            <strong>lite</strong>
            shows the pages for everyday work: AQUA, Files, Vault, Schedules, Webhooks,
            Programs, Settings and Legal. <strong>dev</strong>
            adds a side menu with the pages for building and looking closer: Executions, where
            each run's failure says why, Components, Builds, API Keys, Reports and more. What
            you may do is the same in both.
          </p>
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

        <%!-- User Profile --%>
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
              <dt class="text-xs text-gray-500 uppercase">Signed in with</dt>
              <dd class="text-sm text-white mt-1" data-test="auth-method">
                {signed_in_with(@context.auth_method)}
              </dd>
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

  attr :keys, :list, default: nil
  attr :error, :string, default: nil
  attr :account, :string, default: nil

  # Every key of the person's account, with their sessions here under each.
  defp keys_card(assigns) do
    ~H"""
    <.card>
      <section data-test="keys" class="space-y-3">
        <h3 class="text-sm font-medium text-gray-400">Keys on your account</h3>
        <p class="text-xs text-gray-500" data-test="keys-scope">
          Every key that can sign in as you, and where each is signed in at this CYFR.
          Signing a session out ends it here alone.
          <span :if={@account}>
            To remove a key, use <a href={@account} class="underline" data-test="keys-account">your account page</a>.
          </span>
        </p>

        <p :if={@error} role="alert" class="text-sm">{@error}</p>

        <ul class="divide-y divide-gray-800 text-sm">
          <li :for={key <- @keys || []} class="py-2 space-y-1" data-test="key" data-kid={key.kid}>
            <p>
              <span class="font-medium">{key_title(key)}</span>
              <span class="text-gray-400 font-mono">{key.code}</span>
            </p>
            <p :if={key.sessions == []} class="text-xs text-gray-500">No sessions here</p>
            <ul class="space-y-1">
              <li
                :for={session <- key.sessions}
                class="flex items-center justify-between gap-2 text-xs text-gray-400"
                data-test="session"
                data-id={session.session_id}
              >
                <span>
                  <span class="text-gray-200">{session_title(session)}</span>
                  <span :if={session.current} class="text-gray-200">(this session)</span>
                  · signed in {minute(session.signed_in_at)} · last seen {seen(session.last_seen_at)}
                </span>
                <.button
                  variant="ghost"
                  phx-click="session_end"
                  phx-value-id={session.session_id}
                  data-test="session-end"
                >
                  Sign out
                </.button>
              </li>
            </ul>
          </li>
        </ul>
      </section>
    </.card>
    """
  end
end
