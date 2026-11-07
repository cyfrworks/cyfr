# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SettingsLive do
  @moduledoc """
  Settings: the person's name and identifier, the devices and passkeys of
  their account connected here, their lite/dev preference, and, for a
  platform admin, the door, the invitations to this CYFR and the platform
  settings.

  Every change is an operation through the gate. A change that needs a
  fresh confirmation is asked through the page's system layer
  (`PrismWeb.SystemLayer.call/5`) and made again once confirmed.

    * **Your name** — the identity card (`PrismWeb.IdentityCard`): the
      person's name and their account's identifier. A person with no name
      recorded here types the name their account holds, which is recorded
      once cyfr.run says it is theirs (`session.name`). The account itself,
      its keys and its recovery code, are the account pages'.
    * **Devices connected here** — the person's paired clients
      (`pairing.list`), each signed out of this CYFR through
      `pairing.revoke`, and the passkeys of their account that signed in
      here, by the short code of their key (`passkey.list`), each signed
      out of this CYFR through `passkey.revoke`. This CYFR owns only its
      own bindings: a device's key and a passkey are the account's, and
      only removing one from the account ends it everywhere.
    * **Invite to this CYFR** — the platform administrator's invitation
      links naming no thread (`invitation.create` with no `thread_id`): a
      link is shown once with a copy control, and every one naming no
      thread is listed (`invitation.list`) and, while pending, revoked
      (`invitation.revoke`). A thread's own links belong to its people.

  The refusals each change can meet are shown as the refusal's own
  sentence.

  The identity card's controls carry its own `data-test` names, and this
  page's `devices`, `devices-scope`, `device` (with `data-id`),
  `device-revoke`, `passkey` (with `data-kid`), `passkey-revoke`;
  `invite-cyfr`, `invitation-create`, `invitation-new`, `invitation-link`,
  `invitation-copy` and `invitation-revoke`.
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
      |> assign(:door_names, %{})
      |> assign(:door_requests, [])
      |> assign(:door_value, "")
      |> assign(:door_note, "")
      |> assign(:invitations, [])
      |> assign(:new_link, nil)
      |> assign(:platform_settings, [])
      |> assign(:settings_revision, nil)
      |> assign(:settings_members, [])
      |> assign(:settings_ttl_ms, nil)
      |> assign(:mode, Prism.Labels.default(socket.assigns.context))
      |> assign(:loading, true)
      |> assign(:identifier, nil)
      |> assign(:name, socket.assigns.context.namespace)
      |> assign(:name_error, nil)
      |> assign(:devices, nil)
      |> assign(:passkeys, nil)
      |> assign(:devices_error, nil)

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
  def handle_event("invitation_create", _params, socket) do
    case call_tool(socket, "invitation/create", %{}) do
      {:ok, %{invitation_url: link}} ->
        {:noreply, socket |> assign(:new_link, link) |> load_invitations()}

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

  # ---- devices connected here --------------------------------------------------

  def handle_event("device_revoke", %{"id" => id}, socket), do: revoke_device(socket, id)
  def handle_event("passkey_revoke", %{"kid" => kid}, socket), do: revoke_passkey(socket, kid)

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

  # A change this page asked for was confirmed: made again, once.
  @impl PrismWeb.SystemLayer.Hook
  def system_layer_repeat({:device_revoke, id}, _tool, _args, socket),
    do: revoke_device(socket, id)

  @impl true
  def handle_info(:load, socket) do
    {:noreply,
     socket
     |> load_system_status()
     |> load_log_stats()
     |> load_door()
     |> load_invitations()
     |> load_settings()
     |> load_prefs()
     |> load_identifier()
     |> load_devices()
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
    |> assign(:door_names, names(entries))
    |> assign(:door_requests, requests)
  end

  # A socket whose capability went since it read the door drops what it read.
  defp load_door(socket),
    do: assign(socket, door_entries: [], door_names: %{}, door_requests: [])

  # The invitations to this CYFR that name no thread, newest first: the
  # administrator's section. A thread's own are its people's.
  defp load_invitations(%{assigns: %{context: %{platform_admin: true}}} = socket) do
    invitations =
      case call_tool(socket, "invitation/list", %{}) do
        {:ok, %{invitations: invitations}} ->
          Enum.reject(invitations, &Map.has_key?(&1, :thread_id))

        _ ->
          []
      end

    assign(socket, :invitations, invitations)
  end

  defp load_invitations(socket), do: assign(socket, invitations: [], new_link: nil)

  defp until(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> Calendar.strftime(at, "%-d %b %Y, %H:%M UTC")
      _unparsed -> iso
    end
  end

  # The name each person an entry names holds here, by their id; an entry
  # made from a name shows its label instead.
  defp names(entries) do
    for %{kind: "person", value: user_id} = entry <- entries,
        is_nil(entry[:label]),
        {:ok, %{namespace: name}} when is_binary(name) <- [Sanctum.Tenancy.Users.get(user_id)],
        into: %{},
        do: {user_id, name}
  end

  # An allowlist entry's name: the person's name here, everyone for `*`,
  # or, for an entry nothing here names, where it came from.
  defp entry_name(%{kind: "wildcard"}, _names), do: "everyone"

  defp entry_name(%{value: value}, names) do
    case Map.fetch(names, value) do
      {:ok, name} -> "@" <> name
      :error -> "added from the command line"
    end
  end

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

  # The account's identifier, as this CYFR's row for the person names it.
  defp load_identifier(socket) do
    case Sanctum.Tenancy.Users.identifier(socket.assigns.context.user_id) do
      {:ok, identifier} -> assign(socket, :identifier, identifier)
      {:error, _unread} -> assign(socket, :identifier, nil)
    end
  end

  # ---- devices connected here --------------------------------------------------

  defp load_devices(socket) do
    with {:ok, devices} <- call_tool(socket, "pairing/list", %{}),
         {:ok, %{passkeys: passkeys}} <- call_tool(socket, "passkey/list", %{}) do
      assign(socket, devices: listed_devices(devices), passkeys: passkeys, devices_error: nil)
    else
      {:error, reason} ->
        assign(socket, devices: nil, passkeys: nil, devices_error: error_message(reason))
    end
  end

  # The passkeys are listed by their key from `passkey.list`, beside the
  # devices.
  defp listed_devices(%{clients: clients}) when is_list(clients), do: listed_devices(clients)

  defp listed_devices(clients) when is_list(clients),
    do: Enum.reject(clients, &(&1[:source] == "passkey"))

  defp listed_devices(_other), do: []

  defp revoke_device(socket, id) do
    case SystemLayer.call(socket, {:device_revoke, id}, "pairing/revoke", %{"client_id" => id}) do
      {:ok, _revoked, socket} ->
        {:noreply,
         socket |> load_devices() |> put_flash(:info, "Device signed out of this CYFR.")}

      {:asked, socket} ->
        {:noreply, socket}

      {:error, reason, socket} ->
        {:noreply, put_flash(socket, :error, "Device: #{error_message(reason)}")}
    end
  end

  defp revoke_passkey(socket, kid) do
    case call_tool(socket, "passkey/revoke", %{"kid" => kid}) do
      {:ok, _revoked} ->
        {:noreply,
         socket |> load_devices() |> put_flash(:info, "Passkey signed out of this CYFR.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Passkey: #{error_message(reason)}")}
    end
  end

  # The short code of a key, as a device shows its own: the first 16
  # hexadecimal digits of its kid.
  defp short_code("sha256:" <> hex), do: String.slice(hex, 0, 16)
  defp short_code(_kid), do: ""

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

        <.devices_card devices={@devices} passkeys={@passkeys} error={@devices_error} />

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

        <%!-- Request Metrics --%>
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
                <:col :let={r} label="Identifier">{r.value}</:col>
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
              <.empty_state message="No entries: no account signs in here but by an invitation" />
            </div>
            <.table :if={@door_entries != []} id="door-entries" rows={@door_entries}>
              <:col :let={e} label="Entry">{e.value}</:col>
              <:col :let={e} label="Name">
                <span :if={e[:label]} data-test="door-entry-label">@{e[:label]}</span>
                <span :if={is_nil(e[:label])} class="text-gray-400" data-test="door-entry-name">
                  {entry_name(e, @door_names)}
                </span>
              </:col>
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

        <%!-- Invitations to this CYFR, naming no thread (platform admins) --%>
        <.card :if={@context.platform_admin}>
          <section id="invite-cyfr" data-test="invite-cyfr">
            <h3 class="text-sm font-medium text-gray-400 mb-1">Invite to this CYFR</h3>
            <p class="text-xs text-gray-500 mb-4">
              A link makes someone new a person here, with their own athanor. Someone who
              already has a CYFR name signs in with it from the same link. It works once and
              expires after seven days. To bring someone into a thread, invite them from the
              thread.
            </p>

            <div :if={@new_link} data-test="invitation-new" class="mb-4 space-y-2">
              <p class="text-xs text-gray-400">
                Send this link to the person you invite. It is shown only now.
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

            <.button class="mt-4" phx-click="invitation_create" data-test="invitation-create">
              Create an invitation link
            </.button>
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

        <%!-- Preferences --%>
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

  attr :devices, :list, default: nil
  attr :passkeys, :list, default: nil
  attr :error, :string, default: nil

  # The devices and passkeys of the person's account connected here.
  defp devices_card(assigns) do
    ~H"""
    <.card>
      <section data-test="devices" class="space-y-3">
        <h3 class="text-sm font-medium text-gray-400">Devices connected here</h3>
        <p class="text-xs text-gray-500" data-test="devices-scope">
          Signing a device or passkey out ends its sessions at this CYFR alone: it stays on
          your account and can sign in here again. Removing its key from your account ends it
          everywhere.
        </p>

        <p :if={@error} role="alert" class="text-sm">{@error}</p>

        <ul class="divide-y divide-gray-800 text-sm">
          <li
            :for={device <- @devices || []}
            class="flex items-center justify-between gap-2 py-2"
            data-test="device"
            data-id={device.client_id}
          >
            <span>
              <span class="font-medium">{device.display_name || "Device"}</span>
            </span>
            <.button
              variant="ghost"
              phx-click="device_revoke"
              phx-value-id={device.client_id}
              data-test="device-revoke"
            >
              Sign out this device
            </.button>
          </li>
          <li
            :for={passkey <- @passkeys || []}
            class="flex items-center justify-between gap-2 py-2"
            data-test="passkey"
            data-kid={passkey.kid}
          >
            <span>
              <span class="font-medium">Passkey</span>
              <span class="text-gray-400 font-mono">{short_code(passkey.kid)}</span>
            </span>
            <.button
              variant="ghost"
              phx-click="passkey_revoke"
              phx-value-kid={passkey.kid}
              data-test="passkey-revoke"
            >
              Sign out this passkey
            </.button>
          </li>
        </ul>
      </section>
    </.card>
    """
  end
end
