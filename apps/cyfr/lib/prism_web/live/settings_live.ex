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

    * **Instance entries** (platform admins) — the credentials this
      instance offers to the people on it, owned by no athanor: each
      entry's provider, destination, audience, component policy, caps,
      status and last use, and every change through `instance_entry.*`.
      The page never holds a value: a new entry's key, and a rotation's,
      is typed in the system layer's credential prompt, which the card
      raises with everything else it collected (`target: :instance`). A
      new entry's destination is prefilled from the newest shipped
      catalyst of its provider in the administrator's own athanor
      (`component.list`, `component.inspect`): the need's hosts, and its
      paths where it declares them. The audience lists people who have
      signed in (`instance_entry.people`, read in id order). A save sends
      only the administrator's own edit of what the form showed: an
      audience saved is that edit applied to the entry's audience read at
      submit, and read again when a widening's proof lands, and a cap
      saved is one changed from the value the form was drawn with, so a
      change made elsewhere meanwhile stands. A read that fails is shown
      as such, never as nobody or no use. A change that needs a fresh
      confirmation (entering a key, widening an audience, a policy from
      `shipped` to `any`) is asked through the page's system layer and
      made again once confirmed: an audience as the edit applied to the
      audience then stored, asked afresh when that is not the change
      proven. A narrowing needs the session alone.
    * **Use** (platform admins) — each entry's requests by person and day
      over the last seven days, and its day totals
      (`instance_entry.usage`).

  Both instance-entry cards, and the people the picker offers, read again
  on every `Cyfr.Bus.instance_entries/0` announcement.

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
  `passkey-revoke`. The instance-entry cards carry `instance-entries`,
  `instance-entry` (with `data-id`), `instance-create`, `instance-error`,
  `instance-people`, `instance-policy` and `instance-use`.
  """

  use PrismWeb, :live_view

  require Logger

  alias PrismWeb.SystemLayer
  alias PrismWeb.SystemLayer.{Prompt, Recovery}
  alias Sanctum.Auth.DeviceFlow

  @default_link_poll_s 5

  # The days of use the Use card reads for each entry, today included.
  @instance_days 7
  @instance_kinds ~w(api_key bundle)
  @instance_policies ~w(any shipped)

  # The new-entry form as typed. It never holds a value: the key is typed
  # in the system layer's prompt alone.
  @instance_draft %{
    "name" => "",
    "provider_hint" => "",
    "kind" => "api_key",
    "destination_hosts" => "",
    "destination_scheme" => "https",
    "destination_port" => "",
    "destination_methods" => "",
    "destination_paths" => "",
    "component_policy" => "any",
    "audience" => "everyone",
    "members" => [],
    "person_daily" => "",
    "total_daily" => ""
  }

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      actor = Sanctum.Context.actor(socket.assigns[:context])
      Cyfr.Bus.subscribe(actor, Cyfr.Bus.requests(actor))
    end

    if connected?(socket) and socket.assigns.context.platform_admin do
      Cyfr.Bus.subscribe_global(Cyfr.Bus.platform_notify())
      Cyfr.Bus.subscribe_global(Cyfr.Bus.settings_changed())
      Cyfr.Bus.subscribe_global(Cyfr.Bus.instance_entries())
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
      |> assign(:instance_entries, [])
      |> assign(:instance_usage, %{})
      |> assign(:instance_people, [])
      |> assign(:instance_people_error, nil)
      |> assign(:instance_prefill, %{})
      |> assign(:instance_draft, @instance_draft)
      |> assign(:instance_error, nil)
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

  # ---- instance entries ------------------------------------------------------

  def handle_event("instance_draft", params, socket),
    do: {:noreply, assign(socket, instance_draft: draft(socket, params), instance_error: nil)}

  # Everything an entry is but its key, held to the card's rules; the key
  # is then asked in the system layer, which makes the entry.
  def handle_event("instance_create", params, socket) do
    draft = draft(socket, params)
    socket = assign(socket, :instance_draft, draft)

    case instance_create_args(draft) do
      {:ok, %{"audience" => "listed"}} when is_binary(socket.assigns.instance_people_error) ->
        {:noreply, assign(socket, :instance_error, people_unread())}

      {:ok, args} ->
        {:noreply,
         socket |> assign(:instance_error, nil) |> ask_value(:create, args["name"], args)}

      {:error, sentence} ->
        {:noreply, assign(socket, :instance_error, sentence)}
    end
  end

  # The prompt takes one value, so only an entry of one field rotates here.
  def handle_event("instance_rotate", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.instance_entries, &(&1.id == id)) do
      %{field_names: [field], payload_rev: rev, name: name} ->
        args = %{"entry_id" => id, "expected_payload_rev" => rev}
        {:noreply, ask_value(socket, :rotate, name, args, field)}

      %{} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Instance entries: this entry holds several fields, so it rotates through " <>
             "instance_entry.rotate, not here."
         )}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("instance_rebind", %{"entry_id" => id} = params, socket) do
    args = %{"entry_id" => id, "destination" => SystemLayer.destination_params(params)}

    instance_call(
      socket,
      "instance_entry/rebind",
      args,
      "Destination saved: every consent that binds the entry asks again."
    )
  end

  # An audience is saved as the administrator's own edit of what the form
  # showed (`audience_edit/1`: the audience chosen, the people added and
  # removed), never as the whole list the form holds: the people re-read
  # first, then the edit applied to the entry's audience read afresh
  # (`save_audience/3`). Someone the form had no checkbox for, added
  # elsewhere since, is kept; an unedited save changes nothing. With the
  # people unread no audience is saved, whatever the form sends.
  def handle_event("instance_audience", %{"entry_id" => id} = params, socket) do
    socket = load_instance_people(socket)

    case socket.assigns.instance_people_error do
      nil -> save_audience(socket, id, audience_edit(params))
      _unread -> {:noreply, put_flash(socket, :error, "Instance entries: " <> people_unread())}
    end
  end

  # A policy that is neither word is refused here, and the operation
  # refuses it again whoever sends it.
  def handle_event("instance_policy", %{"entry_id" => id} = params, socket) do
    case policy(params["component_policy"]) do
      {:ok, policy} ->
        set_policy(socket, id, %{"entry_id" => id, "component_policy" => policy})

      {:error, sentence} ->
        {:noreply, put_flash(socket, :error, "Instance entries: " <> sentence)}
    end
  end

  # A blank cap takes the platform default and `0` admits no use: each is
  # sent as it means, `null` and `0`. Only a cap changed from the value the
  # form was drawn with (its `_loaded` field) is sent, so a change another
  # administrator made to the other cap meanwhile stands; a form with
  # nothing changed sends nothing.
  def handle_event("instance_caps", %{"entry_id" => id} = params, socket) do
    with {:ok, changed} <- changed_caps(params) do
      if changed == %{} do
        {:noreply, put_flash(socket, :info, "Nothing changed.")}
      else
        args = Map.put(changed, "entry_id", id)
        instance_call(socket, "instance_entry/set_caps", args, "Caps saved.")
      end
    else
      {:error, sentence} ->
        {:noreply, put_flash(socket, :error, "Instance entries: " <> sentence)}
    end
  end

  def handle_event("instance_revoke", %{"id" => id}, socket),
    do: instance_call(socket, "instance_entry/revoke", %{"entry_id" => id}, "Entry revoked.")

  def handle_event("instance_delete", %{"id" => id}, socket),
    do: instance_call(socket, "instance_entry/delete", %{"entry_id" => id}, "Entry deleted.")

  @impl true
  def handle_info(:load, socket) do
    socket =
      socket
      |> load_system_status()
      |> load_log_stats()
      |> load_door()
      |> load_settings()
      |> load_instance()
      |> load_instance_people()
      |> load_instance_prefill()
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

      # The proven widening is made again as the administrator's edit of
      # the audience as it stands now, not as the list computed before the
      # prompt: someone listed or removed elsewhere meanwhile stays so.
      {:repeat, {:instance_audience, id, edit}, _tool, _confirmed, socket} ->
        save_audience(socket, id, edit)

      {:repeat, {:instance_policy, id}, _tool, args, socket} ->
        set_policy(socket, id, args)

      {:ok, socket} ->
        cond do
          recovery_prompt?(prompt_id) ->
            {:noreply, socket |> recovery_ended(report) |> load_identity()}

          instance_prompt?(prompt_id) ->
            {:noreply, instance_prompt_ended(socket, report)}

          true ->
            {:noreply, socket}
        end
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

  # The announcement carries an entry id and a kind; the cards read the
  # entries again through the operations, and the picker's people with
  # them, so a person another client listed has a checkbox here.
  def handle_info(%Cyfr.Bus.InstanceEntryChanged{}, socket),
    do: {:noreply, socket |> load_instance() |> load_instance_people()}

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

  # ---- instance entries ------------------------------------------------------

  # The entries and each one's use, the operator's like the door; a socket
  # whose capability went drops what it read.
  defp load_instance(%{assigns: %{context: %{platform_admin: true}}} = socket) do
    case call_tool(socket, "instance_entry/list", %{}) do
      {:ok, %{entries: entries}} ->
        usage = Map.new(entries, &{&1.id, entry_usage(socket, &1.id)})
        assign(socket, instance_entries: entries, instance_usage: usage)

      {:error, reason} ->
        socket
        |> assign(instance_entries: [], instance_usage: %{})
        |> put_flash(:error, "Instance entries: #{error_message(reason)}")
    end
  end

  defp load_instance(socket), do: assign(socket, instance_entries: [], instance_usage: %{})

  # An entry's use, or why it could not be read: a read that failed is
  # never shown as no use.
  defp entry_usage(socket, id) do
    case call_tool(socket, "instance_entry/usage", %{"entry_id" => id, "days" => @instance_days}) do
      {:ok, %{people: people, totals: totals}} -> %{people: people, totals: totals}
      {:error, reason} -> {:unread, error_message(reason)}
    end
  end

  # The people an audience may list, or why they could not be read: the
  # picker then says so and saves no audience, rather than offering no one.
  defp load_instance_people(%{assigns: %{context: %{platform_admin: true}}} = socket) do
    case call_tool(socket, "instance_entry/people", %{}) do
      {:ok, %{people: people}} ->
        assign(socket, instance_people: people, instance_people_error: nil)

      {:error, reason} ->
        assign(socket, instance_people: [], instance_people_error: error_message(reason))
    end
  end

  defp load_instance_people(socket),
    do: assign(socket, instance_people: [], instance_people_error: nil)

  defp people_unread,
    do:
      "the people on this instance could not be read, so no one can be listed now; " <>
        "load the page again"

  # What a new entry of a provider is prefilled with: the need of that
  # provider in the newest shipped catalyst that declares one, among the
  # catalysts of the administrator's own athanor, its hosts and, where it
  # declares them, its paths. A catalyst the athanor wrote or pulled is
  # never a source: only what the install media ships.
  defp load_instance_prefill(%{assigns: %{context: %{platform_admin: true}}} = socket) do
    shipped =
      case call_tool(socket, "component/list", %{"type" => "catalyst"}) do
        {:ok, %{components: rows}} -> Enum.filter(rows, &(f(&1, :provenance) == "bundled"))
        _unread -> []
      end

    prefill =
      shipped
      |> Prima.Semver.sort_desc_by(&to_string(f(&1, :version)))
      |> Enum.reduce(%{}, fn row, acc ->
        row |> shipped_needs(socket) |> Enum.reduce(acc, &put_prefill/2)
      end)

    assign(socket, :instance_prefill, prefill)
  end

  defp load_instance_prefill(socket), do: assign(socket, :instance_prefill, %{})

  defp shipped_needs(row, socket) do
    with ref when is_binary(ref) <- f(row, :component_ref),
         {:ok, inspected} <- call_tool(socket, "component/inspect", %{"reference" => ref}),
         needs when is_list(needs) <-
           inspected
           |> f(:manifest)
           |> Prima.Manifest.decode()
           |> Prima.Manifest.Needs.from_manifest() do
      Enum.filter(needs, &(&1.kind in @instance_kinds))
    else
      _unread -> []
    end
  end

  # The newest catalyst's need of a provider stands; an older one does not
  # replace it.
  defp put_prefill(need, acc),
    do: Map.put_new(acc, need.qualifier, %{hosts: need.hosts, paths: need.paths})

  # The create form as typed: choosing a provider whose shipped need
  # declares a destination fills in its hosts and, where declared, its
  # paths, and leaves everything else as the administrator typed it.
  defp draft(socket, params) do
    previous = socket.assigns.instance_draft

    draft =
      @instance_draft
      |> Map.merge(Map.take(params, Map.keys(@instance_draft)))
      |> Map.put("members", members(params))

    provider = draft["provider_hint"]
    chosen? = provider != previous["provider_hint"]

    case socket.assigns.instance_prefill do
      %{^provider => prefill} when chosen? ->
        draft
        |> put_prefilled("destination_hosts", prefill.hosts)
        |> put_prefilled("destination_paths", prefill.paths)

      _no_prefill ->
        draft
    end
  end

  defp put_prefilled(draft, _key, []), do: draft
  defp put_prefilled(draft, key, words), do: Map.put(draft, key, Enum.join(words, " "))

  defp members(params) do
    case Map.get(params, "members") do
      list when is_list(list) -> Enum.filter(list, &(is_binary(&1) and &1 != ""))
      _none -> []
    end
  end

  # The card's rules, before the key is asked: a name and a provider, a
  # destination naming its hosts, methods and paths, one of the two kinds
  # and policies, an audience, and caps that are whole numbers or blank.
  defp instance_create_args(draft) do
    destination = SystemLayer.destination_params(draft)
    missing = for key <- ~w(hosts methods paths), Map.get(destination, key, []) == [], do: key
    name = String.trim(to_string(draft["name"]))
    provider = String.trim(to_string(draft["provider_hint"]))

    with :ok <- named(name, "Name the entry."),
         :ok <- named(provider, "Name the provider it is for, for example openai.com."),
         :ok <- destination_named(missing),
         {:ok, kind} <- kind(draft["kind"]),
         {:ok, policy} <- policy(draft["component_policy"]),
         {:ok, audience, members} <- audience(draft),
         {:ok, person} <- cap(draft["person_daily"]),
         {:ok, total} <- cap(draft["total_daily"]) do
      {:ok,
       %{
         "name" => name,
         "kind" => kind,
         "provider_hint" => provider,
         "destination" => destination,
         "component_policy" => policy,
         "audience" => audience,
         "members" => members
       }
       |> put_cap("person_daily", person)
       |> put_cap("total_daily", total)}
    end
  end

  defp named("", sentence), do: {:error, sentence}
  defp named(_text, _sentence), do: :ok

  defp destination_named([]), do: :ok

  defp destination_named(missing),
    do:
      {:error,
       "The destination names no #{Enum.join(missing, " and no ")}: an instance entry names " <>
         "where its key may go, its hosts, methods and paths."}

  defp kind(kind) when kind in @instance_kinds, do: {:ok, kind}

  defp kind(_kind),
    do:
      {:error,
       "An instance entry is an API key or a bundle of fields: one of kind oauth is refused " <>
         "until this instance can dispense an OAuth token itself."}

  defp policy(policy) when policy in @instance_policies, do: {:ok, policy}

  defp policy(_policy),
    do: {:error, "Choose Any consented component or Unmodified shipped components."}

  defp audience(%{"audience" => "everyone"}), do: {:ok, "everyone", []}
  defp audience(%{"audience" => "listed", "members" => members}), do: {:ok, "listed", members}
  defp audience(_draft), do: {:error, "Offer it to everyone, or to the people listed."}

  # A blank cap is `nil`, the platform default; a whole number is the
  # entry's own, `0` admitting no use.
  defp cap(text) when is_binary(text) do
    case String.trim(text) do
      "" ->
        {:ok, nil}

      trimmed ->
        case Integer.parse(trimmed) do
          {number, ""} when number >= 0 -> {:ok, number}
          _not_a_count -> {:error, cap_refusal()}
        end
    end
  end

  defp cap(nil), do: {:ok, nil}
  defp cap(_other), do: {:error, cap_refusal()}

  # The caps a form changed: each as typed, held to `cap/1`, when it
  # differs from the value the form was drawn with (`<cap>_loaded`).
  defp changed_caps(params) do
    Enum.reduce_while(~w(person_daily total_daily), {:ok, %{}}, fn key, {:ok, acc} ->
      with {:ok, typed} <- cap(params[key]),
           {:ok, loaded} <- cap(params[key <> "_loaded"]) do
        {:cont, {:ok, if(typed == loaded, do: acc, else: Map.put(acc, key, typed))}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp cap_refusal,
    do:
      "A cap is a whole number of requests a day: 0 admits no use, and a blank takes the " <>
        "platform default."

  defp put_cap(args, _key, nil), do: args
  defp put_cap(args, key, cap), do: Map.put(args, key, cap)

  # The system layer's credential prompt for an instance entry's key: the
  # card's arguments for the operation, the value typed there alone.
  defp ask_value(socket, operation, name, arguments, field \\ Prompt.default_field()) do
    SystemLayer.show(SystemLayer.layer_id(), %{
      id: "instance-#{operation}-#{System.unique_integer([:positive])}",
      kind: :credential_entry,
      action: :credential_entry,
      subject: %{
        name: name,
        field: field,
        target: :instance,
        operation: operation,
        arguments: arguments
      }
    })

    socket
  end

  defp instance_prompt?("instance-" <> _rest), do: true
  defp instance_prompt?(_prompt_id), do: false

  # A key the prompt saved: the entries read again, and a new entry's form
  # emptied. A prompt dismissed or refused leaves the card as it was.
  defp instance_prompt_ended(socket, {:system_layer, "instance-create-" <> _, :confirmed}) do
    socket
    |> assign(:instance_draft, @instance_draft)
    |> load_instance()
    |> put_flash(:info, "Instance entry created.")
  end

  defp instance_prompt_ended(socket, {:system_layer, "instance-rotate-" <> _, :confirmed}),
    do: socket |> load_instance() |> put_flash(:info, "Key rotated.")

  defp instance_prompt_ended(socket, _report), do: socket

  defp instance_call(socket, tool, args, ok_message) do
    case call_tool(socket, tool, args) do
      {:ok, _result} ->
        {:noreply, socket |> load_instance() |> put_flash(:info, ok_message)}

      {:error, reason} ->
        {:noreply, instance_refused(socket, reason)}
    end
  end

  defp instance_refused(socket, reason),
    do:
      socket
      |> load_instance()
      |> put_flash(:error, "Instance entries: #{error_message(reason)}")

  # The entry's audience as stored now, read at submit.
  defp fresh_audience(socket, id) do
    case call_tool(socket, "instance_entry/list", %{}) do
      {:ok, %{entries: entries}} ->
        case Enum.find(entries, &(&1.id == id)) do
          %{audience: audience, members: members} ->
            {:ok, %{audience: audience, members: members}}

          nil ->
            {:error, :not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The administrator's own edit of what the form showed: the audience
  # they chose, when it differs from the one the form showed
  # (`audience_shown`), and the people they checked and unchecked against
  # those the form showed checked (`members_shown`).
  defp audience_edit(params) do
    checked = MapSet.new(members(params))
    shown = MapSet.new(members(%{"members" => params["members_shown"]}))

    %{
      audience: if(params["audience"] != params["audience_shown"], do: params["audience"]),
      adds: checked |> MapSet.difference(shown) |> Enum.sort(),
      removes: shown |> MapSet.difference(checked) |> Enum.sort()
    }
  end

  # `edit` applied to the audience as stored now, and the sentence a save
  # that changes nothing says. Nobody the edit does not name is touched, so
  # a person the form had no checkbox for stays listed, and one removed
  # elsewhere is not added back. A removal from a list the audience no
  # longer has, since it became everyone elsewhere, has no effect, and the
  # sentence says so.
  defp edited_audience(fresh, edit) do
    audience = edit.audience || fresh.audience

    members =
      fresh.members
      |> MapSet.new()
      |> MapSet.union(MapSet.new(edit.adds))
      |> MapSet.difference(MapSet.new(edit.removes))

    members = if audience == "listed", do: Enum.sort(members), else: []

    unchanged =
      if is_nil(edit.audience) and fresh.audience == "everyone" and edit.removes != [],
        do:
          "The audience is everyone now, set elsewhere, so removing someone from its list " <>
            "changes nothing.",
        else: "Nothing changed."

    {%{"audience" => audience, "members" => members}, unchanged}
  end

  # Save `edit` against the entry's audience read now. The call is keyed by
  # the edit itself, so the repeat after a widening's proof applies it again
  # to a fresh read (`{:repeat, {:instance_audience, id, edit}, …}`): the
  # same result is made with the proof, and a different one is asked
  # afresh when it widens, since the proof binds the audience it was given
  # over, and written when it does not. An edit that leaves the audience as
  # read sends nothing, a first save and a repeat alike: the owner compares
  # with a read of its own taken a moment later, so the list read here,
  # sent back, could write over a change landing between the two reads.
  # A proof held for the edit never stays behind: it leaves the page by the
  # one dispatch it binds or is released (`let_go/3`), on an edit that now
  # changes nothing and on a fresh read that fails. A raise or a navigation
  # ends the page, and its held secret with it.
  defp save_audience(socket, id, edit) do
    tag = {:instance_audience, id, edit}

    case fresh_audience(socket, id) do
      {:ok, fresh} ->
        {args, unchanged} = edited_audience(fresh, edit)

        if args == %{"audience" => fresh.audience, "members" => Enum.sort(fresh.members)} do
          case let_go(socket, tag, :nothing_to_change) do
            {:let_go, socket} ->
              {:noreply, socket |> load_instance() |> put_flash(:info, unchanged)}

            {:kept_until_expiry, socket} ->
              {:noreply,
               socket
               |> load_instance()
               |> put_flash(:error, "Instance entries: #{unchanged} #{withdraw_failed()}")}
          end
        else
          set_audience(socket, tag, Map.put(args, "entry_id", id), unchanged)
        end

      {:error, reason} ->
        case let_go(socket, tag, reason) do
          {:let_go, socket} ->
            {:noreply, instance_refused(socket, reason)}

          {:kept_until_expiry, socket} ->
            {:noreply,
             socket
             |> load_instance()
             |> put_flash(
               :error,
               "Instance entries: #{error_message(reason)} #{withdraw_failed()}"
             )}
        end
    end
  end

  # A held proof for `tag` let go with no dispatch: its record cancelled and
  # its prompt told why. A cancel that fails still drops the secret, and the
  # caller says, in the one message it shows, that the record ends at its
  # expiry.
  defp let_go(socket, tag, reason) do
    case SystemLayer.release(socket, tag, reason) do
      {:cancel_failed, socket} -> {:kept_until_expiry, socket}
      {_released_or_none, socket} -> {:let_go, socket}
    end
  end

  defp withdraw_failed, do: "The approval could not be withdrawn; it ends when it expires."

  # A widening asks for a fresh confirmation through the page's layer and
  # is made again once confirmed; a narrowing is saved with the session.
  defp set_audience(socket, tag, args, unchanged) do
    case SystemLayer.call(socket, tag, "instance_entry/set_audience", args) do
      {:ok, %{changed: changed}, socket} ->
        message = if changed, do: "Audience saved.", else: unchanged
        {:noreply, socket |> load_instance() |> put_flash(:info, message)}

      {:asked, socket} ->
        {:noreply, socket}

      {:error, reason, socket} ->
        {:noreply, instance_refused(socket, reason)}
    end
  end

  defp set_policy(socket, id, args) do
    tool = "instance_entry/set_component_policy"

    case SystemLayer.call(socket, {:instance_policy, id}, tool, args) do
      {:ok, %{changed: changed}, socket} ->
        message = if changed, do: "Component policy saved.", else: "The policy is already that."
        {:noreply, socket |> load_instance() |> put_flash(:info, message)}

      {:asked, socket} ->
        {:noreply, socket}

      {:error, reason, socket} ->
        {:noreply, instance_refused(socket, reason)}
    end
  end

  # What a blank cap becomes: the platform setting's value, as the
  # platform settings card lists it.
  defp platform_cap(settings, key) do
    case Enum.find(settings, &(&1.key == key)) do
      %{value: value} when is_integer(value) -> value
      _unread -> nil
    end
  end

  defp cap_text(nil, default) when is_integer(default),
    do: "the platform default, #{default} a day"

  defp cap_text(nil, _default), do: "the platform default"
  defp cap_text(0, _default), do: "0: no use is admitted"
  defp cap_text(cap, _default), do: "#{cap} a day"

  # What the cap as typed admits: a blank, the platform default's value;
  # 0, no use at all.
  defp cap_hint(typed, default) do
    case String.trim(to_string(typed)) do
      "" -> "Blank: " <> cap_text(nil, default) <> ". 0 admits no use."
      "0" -> "0: no use is admitted."
      _number -> "A blank takes " <> cap_text(nil, default) <> "; 0 admits no use."
    end
  end

  defp input_cap(nil), do: ""
  defp input_cap(cap), do: Integer.to_string(cap)

  defp policy_label("any"), do: "Any consented component"
  defp policy_label("shipped"), do: "Unmodified shipped components"
  defp policy_label(other), do: to_string(other)

  defp audience_label(%{audience: "everyone"}, _names), do: "everyone on this instance"
  defp audience_label(%{members: []}, _names), do: "nobody listed"

  defp audience_label(%{members: members}, names),
    do: "listed: " <> Enum.map_join(members, ", ", &Map.get(names, &1, &1))

  defp audience_label(_entry, _names), do: "-"

  defp people_names(people), do: Map.new(people, &{&1.id, &1.display_name})

  # Where an entry's key may go, in one line.
  defp destination_text(%{} = destination) do
    hosts = Enum.join(Map.get(destination, "hosts", []), ", ")

    [
      "#{Map.get(destination, "scheme", "https")}://#{hosts}",
      if(port = Map.get(destination, "port"), do: ":#{port}"),
      if(methods = Map.get(destination, "methods"), do: " · #{Enum.join(methods, " ")}"),
      if(paths = Map.get(destination, "paths"), do: " · #{Enum.join(paths, " ")}")
    ]
    |> Enum.join()
  end

  defp destination_text(_none), do: "no destination"

  defp destination_words(%{} = destination, key),
    do: Enum.join(Map.get(destination, key, []), " ")

  defp destination_words(_none, _key), do: ""

  defp last_use(nil), do: "never"
  defp last_use(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
  defp last_use(other), do: to_string(other)

  # One entry's use as the card draws it: its rows, or why it could not be
  # read. A use that was not read is never drawn as no use.
  defp use_state(%{people: _, totals: _} = usage, names), do: {:rows, use_rows(usage, names)}
  defp use_state({:unread, sentence}, _names), do: {:unread, sentence}
  defp use_state(_not_read, _names), do: {:unread, "it was not read"}

  # The Use card's rows for one entry: each day of the window with use,
  # newest first, with the day's total and each person's count.
  defp use_rows(%{people: people, totals: totals}, names) do
    totals
    |> Enum.sort_by(& &1.day, {:desc, Date})
    |> Enum.map(fn %{day: day, count: total} ->
      persons =
        for %{day: ^day, user_id: user_id, count: count} <- people,
            do: "#{Map.get(names, user_id, user_id)} #{count}"

      %{day: Date.to_iso8601(day), total: total, people: Enum.join(persons, ", ")}
    end)
  end

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
                data-confirm="Deny this person? Their sessions and keys are revoked."
              >
                Deny
              </.button>
            </div>
          </form>
        </.card>

        <%!-- The platform settings (platform admins) --%>
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

        <%!-- Instance entries (platform admins) --%>
        <.instance_entries_card
          :if={@context.platform_admin}
          entries={@instance_entries}
          people={@instance_people}
          people_error={@instance_people_error}
          prefill={@instance_prefill}
          draft={@instance_draft}
          error={@instance_error}
          person_default={platform_cap(@platform_settings, "instance_entry_person_daily")}
          total_default={platform_cap(@platform_settings, "instance_entry_total_daily")}
        />

        <.instance_use_card
          :if={@context.platform_admin}
          entries={@instance_entries}
          usage={@instance_usage}
          people={@instance_people}
        />

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

  attr :entries, :list, required: true
  attr :people, :list, required: true
  attr :people_error, :string, default: nil
  attr :prefill, :map, required: true
  attr :draft, :map, required: true
  attr :error, :string, default: nil
  attr :person_default, :integer, default: nil
  attr :total_default, :integer, default: nil

  # The credentials this instance offers: each entry and its controls, and
  # the form a new one starts from. No value is ever on this card.
  defp instance_entries_card(assigns) do
    assigns = assign(assigns, :names, people_names(assigns.people))

    ~H"""
    <.card>
      <section data-test="instance-entries" class="space-y-4">
        <h3 class="text-sm font-medium text-gray-400">Instance entries</h3>
        <p class="text-xs text-gray-500">
          Credentials this instance offers to the people on it, owned by no athanor. Instance
          entries are API keys or bundles of fields: creating one of kind oauth is refused until
          this instance can dispense an OAuth token itself. An instance entry is attach-only: its
          key is never handed to a component; CYFR attaches it to requests bound for its
          destination. Its key is typed in a prompt and never shown again.
        </p>

        <p :if={@entries == []} class="text-sm text-gray-400">No instance entry yet.</p>

        <div
          :for={entry <- @entries}
          class="space-y-2 rounded-md border border-gray-800 p-3 text-sm"
          data-test="instance-entry"
          data-id={entry.id}
        >
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <span>
              <span class="font-medium">{entry.name}</span>
              <span class="ml-2 font-mono text-xs text-gray-500">{entry.id}</span>
            </span>
            <span class="text-xs" data-test="instance-status">{entry.status}</span>
          </div>
          <dl class="grid grid-cols-3 gap-1 text-xs">
            <dt class="text-gray-500">Provider</dt>
            <dd class="col-span-2">{entry.provider_hint} · {entry.kind}</dd>
            <dt class="text-gray-500">Goes to</dt>
            <dd class="col-span-2 font-mono" data-test="instance-destination">
              {destination_text(entry.destination)}
            </dd>
            <dt class="text-gray-500">Offered to</dt>
            <dd class="col-span-2" data-test="instance-audience">
              {audience_label(entry, @names)}
            </dd>
            <dt class="text-gray-500">Components</dt>
            <dd class="col-span-2" data-test="instance-policy-shown">
              {policy_label(entry.component_policy)}
            </dd>
            <dt class="text-gray-500">Caps</dt>
            <dd class="col-span-2" data-test="instance-caps">
              each person {cap_text(entry.person_daily, @person_default)}; everyone together {cap_text(
                entry.total_daily,
                @total_default
              )}
            </dd>
            <dt class="text-gray-500">Last use</dt>
            <dd class="col-span-2">{last_use(entry.last_used_at)}</dd>
          </dl>

          <div class="flex flex-wrap gap-2">
            <.button
              :if={length(entry.field_names) == 1}
              variant="ghost"
              phx-click="instance_rotate"
              phx-value-id={entry.id}
            >
              Rotate the key
            </.button>
            <.button
              variant="ghost"
              phx-click="instance_revoke"
              phx-value-id={entry.id}
              data-confirm="Revoke this instance entry? Every consent that binds it, in every athanor, stops until granted again."
            >
              Revoke
            </.button>
            <.button
              variant="ghost"
              phx-click="instance_delete"
              phx-value-id={entry.id}
              data-confirm="Delete this instance entry and erase its key?"
            >
              Delete
            </.button>
          </div>

          <details class="space-y-3">
            <summary class="cursor-pointer text-xs text-gray-400">Change</summary>

            <form
              id={"instance-policy-" <> entry.id}
              phx-submit="instance_policy"
              class="space-y-1"
              data-test="instance-policy"
            >
              <input type="hidden" name="entry_id" value={entry.id} />
              <.policy_control selected={entry.component_policy} />
              <.button type="submit" variant="ghost">Save the policy</.button>
            </form>

            <form
              id={"instance-audience-" <> entry.id}
              phx-submit="instance_audience"
              class="space-y-1"
            >
              <input type="hidden" name="entry_id" value={entry.id} />
              <.audience_control
                audience={entry.audience}
                members={entry.members}
                people={@people}
                people_error={@people_error}
                prefix={"audience-" <> entry.id}
              />
              <.button
                type="submit"
                variant="ghost"
                disabled={@people_error != nil}
                data-test="instance-audience-save"
              >
                Save the audience
              </.button>
            </form>

            <form id={"instance-caps-" <> entry.id} phx-submit="instance_caps" class="space-y-1">
              <input type="hidden" name="entry_id" value={entry.id} />
              <%!-- What the form was drawn with: only a cap changed from it is sent. --%>
              <input
                type="hidden"
                name="person_daily_loaded"
                value={input_cap(entry.person_daily)}
              />
              <input type="hidden" name="total_daily_loaded" value={input_cap(entry.total_daily)} />
              <.caps_control
                person={input_cap(entry.person_daily)}
                total={input_cap(entry.total_daily)}
                person_default={@person_default}
                total_default={@total_default}
              />
              <.button type="submit" variant="ghost">Save the caps</.button>
            </form>

            <form
              id={"instance-rebind-" <> entry.id}
              phx-submit="instance_rebind"
              class="space-y-1"
            >
              <input type="hidden" name="entry_id" value={entry.id} />
              <.destination_control
                hosts={destination_words(entry.destination, "hosts")}
                scheme={entry.destination && entry.destination["scheme"]}
                port={entry.destination && entry.destination["port"]}
                methods={destination_words(entry.destination, "methods")}
                paths={destination_words(entry.destination, "paths")}
              />
              <p class="text-xs text-gray-500">
                Moving the destination asks every consent that binds the entry again.
              </p>
              <.button type="submit" variant="ghost">Save the destination</.button>
            </form>
          </details>
        </div>

        <form
          id="instance-create"
          phx-change="instance_draft"
          phx-submit="instance_create"
          class="space-y-3 border-t border-gray-800 pt-4"
          data-test="instance-create"
        >
          <h4 class="text-xs uppercase text-gray-500">A new instance entry</h4>
          <div class="grid grid-cols-3 gap-2">
            <div>
              <label class="block text-xs text-gray-500 mb-1" for="instance-name">Name</label>
              <.input id="instance-name" name="name" value={@draft["name"]} required />
            </div>
            <div>
              <label class="block text-xs text-gray-500 mb-1" for="instance-provider">
                Provider
              </label>
              <input
                id="instance-provider"
                name="provider_hint"
                value={@draft["provider_hint"]}
                list="instance-providers"
                placeholder="openai.com"
                required
                class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white"
              />
              <datalist id="instance-providers">
                <option :for={provider <- Enum.sort(Map.keys(@prefill))} value={provider} />
              </datalist>
            </div>
            <div>
              <label class="block text-xs text-gray-500 mb-1" for="instance-kind">Kind</label>
              <select
                id="instance-kind"
                name="kind"
                class="w-full rounded-md border-gray-600 bg-transparent text-sm"
              >
                <option value="api_key" selected={@draft["kind"] == "api_key"}>API key</option>
                <option value="bundle" selected={@draft["kind"] == "bundle"}>
                  Bundle of fields
                </option>
              </select>
            </div>
          </div>

          <.destination_control
            hosts={@draft["destination_hosts"]}
            scheme={@draft["destination_scheme"]}
            port={@draft["destination_port"]}
            methods={@draft["destination_methods"]}
            paths={@draft["destination_paths"]}
          />
          <p class="text-xs text-gray-500">
            The hosts, and the paths where they are declared, are filled in from the newest
            shipped catalyst of the provider. An instance entry names its hosts, methods and
            paths.
          </p>

          <.policy_control selected={@draft["component_policy"]} />

          <.audience_control
            audience={@draft["audience"]}
            members={@draft["members"]}
            people={@people}
            people_error={@people_error}
            prefix="create"
          />

          <.caps_control
            person={@draft["person_daily"]}
            total={@draft["total_daily"]}
            person_default={@person_default}
            total_default={@total_default}
          />

          <p :if={@error} role="alert" class="text-sm text-red-400" data-test="instance-error">
            {@error}
          </p>

          <.button type="submit">Enter the key</.button>
        </form>
      </section>
    </.card>
    """
  end

  attr :selected, :string, default: "any"

  # One control, two options: no component is picked here.
  defp policy_control(assigns) do
    ~H"""
    <fieldset class="space-y-1">
      <legend class="text-xs uppercase text-gray-500">Which components may use it</legend>
      <label class="flex items-center gap-2 text-sm">
        <input type="radio" name="component_policy" value="any" checked={@selected == "any"} />
        Any consented component
      </label>
      <label class="flex items-center gap-2 text-sm">
        <input
          type="radio"
          name="component_policy"
          value="shipped"
          checked={@selected == "shipped"}
        /> Unmodified shipped components
      </label>
      <p class="text-xs text-gray-500">
        Any component a person consents to can use this account within these destination methods and paths, including operations shipped components do not use.
      </p>
    </fieldset>
    """
  end

  attr :audience, :string, default: "everyone"
  attr :members, :list, default: []
  attr :people, :list, required: true
  attr :people_error, :string, default: nil
  attr :prefix, :string, required: true

  # Everyone, or the people listed: a person is picked from those who have
  # signed in here, never typed. When they could not be read the picker
  # says so, rather than offering no one.
  defp audience_control(assigns) do
    assigns = assign(assigns, :members, assigns.members || [])

    ~H"""
    <fieldset class="space-y-1" data-test="instance-people">
      <legend class="text-xs uppercase text-gray-500">Offered to</legend>
      <%!-- What the form showed: a save sends only what was changed from it. --%>
      <input type="hidden" name="audience_shown" value={@audience} />
      <input
        :for={person <- Enum.filter(@people, &(&1.id in @members))}
        type="hidden"
        name="members_shown[]"
        value={person.id}
      />
      <label class="flex items-center gap-2 text-sm">
        <input type="radio" name="audience" value="everyone" checked={@audience == "everyone"} />
        Everyone on this instance
      </label>
      <label class="flex items-center gap-2 text-sm">
        <input type="radio" name="audience" value="listed" checked={@audience == "listed"} />
        The people listed
      </label>
      <div class="flex flex-wrap gap-x-4 gap-y-1 pl-6">
        <label :for={person <- @people} class="flex items-center gap-1 text-sm">
          <input
            type="checkbox"
            name="members[]"
            value={person.id}
            checked={person.id in @members}
            id={"#{@prefix}-member-#{person.id}"}
          />
          {person.display_name}
        </label>
      </div>
      <p :if={@people_error} role="alert" class="text-xs text-red-400" data-test="people-error">
        The people on this instance could not be read, so no one can be listed now: {@people_error}
      </p>
      <p class="text-xs text-gray-500">
        A person who has not signed in yet cannot be added.
      </p>
    </fieldset>
    """
  end

  attr :person, :string, default: ""
  attr :total, :string, default: ""
  attr :person_default, :integer, default: nil
  attr :total_default, :integer, default: nil

  # Two caps of requests a day. A blank takes the platform default, shown
  # with its value; 0 admits no use.
  defp caps_control(assigns) do
    ~H"""
    <fieldset class="grid grid-cols-2 gap-2">
      <legend class="text-xs uppercase text-gray-500">Requests a day</legend>
      <div>
        <label class="block text-xs text-gray-500 mb-1">Each person</label>
        <.input name="person_daily" value={@person} />
        <p class="text-xs text-gray-500" data-test="cap-person">
          {cap_hint(@person, @person_default)}
        </p>
      </div>
      <div>
        <label class="block text-xs text-gray-500 mb-1">Everyone together</label>
        <.input name="total_daily" value={@total} />
        <p class="text-xs text-gray-500" data-test="cap-total">
          {cap_hint(@total, @total_default)}
        </p>
      </div>
    </fieldset>
    """
  end

  attr :hosts, :string, default: ""
  attr :scheme, :string, default: "https"
  attr :port, :any, default: nil
  attr :methods, :string, default: ""
  attr :paths, :string, default: ""

  defp destination_control(assigns) do
    ~H"""
    <fieldset class="grid grid-cols-2 gap-2">
      <legend class="text-xs uppercase text-gray-500">Where its key may go</legend>
      <div class="col-span-2">
        <label class="block text-xs text-gray-500 mb-1">Hosts</label>
        <.input name="destination_hosts" value={@hosts} placeholder="api.example.com" />
      </div>
      <div>
        <label class="block text-xs text-gray-500 mb-1">Scheme</label>
        <select
          name="destination_scheme"
          class="w-full rounded-md border-gray-600 bg-transparent text-sm"
        >
          <option value="https" selected={@scheme != "http"}>https</option>
          <option value="http" selected={@scheme == "http"}>http</option>
        </select>
      </div>
      <div>
        <label class="block text-xs text-gray-500 mb-1">Port (optional)</label>
        <.input name="destination_port" value={@port && to_string(@port)} placeholder="443" />
      </div>
      <div>
        <label class="block text-xs text-gray-500 mb-1">Methods</label>
        <.input name="destination_methods" value={@methods} placeholder="GET POST" />
      </div>
      <div>
        <label class="block text-xs text-gray-500 mb-1">Path prefixes</label>
        <.input name="destination_paths" value={@paths} placeholder="/v1/" />
      </div>
    </fieldset>
    """
  end

  attr :entries, :list, required: true
  attr :usage, :map, required: true
  attr :people, :list, required: true

  # Each entry's requests over the last seven days: each day's total and
  # each person's count.
  defp instance_use_card(assigns) do
    assigns = assign(assigns, :names, people_names(assigns.people))

    ~H"""
    <.card>
      <section data-test="instance-use" class="space-y-3">
        <h3 class="text-sm font-medium text-gray-400">Use</h3>
        <p class="text-xs text-gray-500">
          Requests through each instance entry over the last seven days, by person and in all,
          counted by UTC day.
        </p>
        <p :if={@entries == []} class="text-sm text-gray-400">No instance entry yet.</p>
        <div
          :for={entry <- @entries}
          class="text-sm"
          data-test="instance-use-entry"
          data-id={entry.id}
        >
          <h4 class="font-medium">{entry.name}</h4>
          <% use = use_state(@usage[entry.id], @names) %>
          <p
            :if={match?({:unread, _}, use)}
            role="alert"
            class="text-xs text-red-400"
            data-test="instance-use-unread"
          >
            Its use could not be read: {elem(use, 1)}
          </p>
          <p :if={use == {:rows, []}} class="text-xs text-gray-400">
            No use in these days.
          </p>
          <table :if={match?({:rows, [_ | _]}, use)} class="w-full text-xs">
            <thead>
              <tr class="text-left text-gray-500">
                <th>Day</th>
                <th>In all</th>
                <th>By person</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- elem(use, 1)} data-day={row.day}>
                <td class="font-mono">{row.day}</td>
                <td>{row.total}</td>
                <td>{row.people}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </.card>
    """
  end
end
