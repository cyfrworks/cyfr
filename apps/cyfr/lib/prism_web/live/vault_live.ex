# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.VaultLive do
  @moduledoc """
  The operator's vault entries: list, create, rotate, re-authorize,
  revoke, delete — all through the vault MCP verbs (rename exists as a
  vault verb but has no control here yet), so this
  surface holds no rules of its own. Material flows one way: forms
  accept field values; nothing here ever displays them.

  OAuth entries start a browser grant via `vault.authorize`; the
  callback completes it server-side and the vault PubSub topic refreshes
  this view when the entry lands.

  Every new entry names where its material may go — the destination's
  hosts, and optionally its scheme, port, methods and paths — and whether
  a component may read it. This page is reached with no installed need
  behind it, so it prefills neither: the person types the destination,
  and disclosure is off until they turn it on
  (`PrismWeb.SystemLayer.destination_params/1`). Each entry's row shows
  where it goes and whether components may read it: an attach-only
  entry's value is never handed to a component, and CYFR attaches it to
  requests bound for the entry's destination. Each entry the athanor uses
  by default for its provider (`vault.list`'s `defaults`) says so.

  "Provided by this instance" lists the instance entries offered to the
  person (`instance_entry.offered`): each one's provider, destination and
  component policy, and how many requests the person made through it
  today, never anyone else's count; when that reached the person's own
  daily cap, it says the limit is reached and resets at midnight UTC,
  when the day a claim counts on ends. "Use by default for <provider>" makes
  one the athanor's default for its provider (`vault.set_default`), which
  a consent of that provider then suggests in this athanor alone. The
  section reads again on every `Cyfr.Bus.instance_entries/0`
  announcement, which names an entry and a kind and nothing the person
  is not offered.

  Entering material — an entry, its rotation, an OAuth grant, an OAuth
  app's client credentials — is a sensitive change: the page asks for a
  fresh confirmation through its system layer
  (`PrismWeb.SystemLayer.call/5`), which shows the request as this page's
  own. A typed value is never held here while it waits: the forms keep
  what was typed in the browser, which submits the same form again once
  the record is confirmed, and the page makes the change then. A grant,
  which carries no typed secret, the page starts again itself.
  """

  use PrismWeb, :live_view

  alias PrismWeb.SystemLayer
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe once, at mount — handle_params re-fires on every patch,
    # and PubSub's :duplicate registry would deliver every message twice.
    if connected?(socket) do
      actor = Sanctum.Context.actor(socket.assigns[:context])
      Cyfr.Bus.subscribe(actor, Cyfr.Bus.vault_changed(actor))
      Cyfr.Bus.subscribe_global(Cyfr.Bus.instance_entries())
    end

    socket =
      socket
      |> assign(:page_title, "Vault")
      |> assign(:active_nav, "vault")
      |> assign(:entries, [])
      |> assign(:defaults, %{})
      |> assign(:offered, [])
      |> assign(:offered_error, nil)
      |> assign(:used_by, %{})
      |> assign(:clients, [])
      |> assign(:show_add, nil)
      |> assign(:pending_grant, nil)
      |> assign(:rotating, nil)
      |> assign(:loading, true)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    # Paint the frame first; the three fetches land in :load.
    if connected?(socket), do: send(self(), :load)
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Events — create
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("show_add", %{"mode" => mode}, socket) do
    {:noreply,
     assign(socket, :show_add, if(socket.assigns.show_add == mode, do: nil, else: mode))}
  end

  # The operator's OAuth app for a provider — the client id/secret an
  # entry's OAuth grant is obtained with. Stored per athanor; listed by
  # provider name only, never the secret.
  def handle_event(
        "set_client",
        %{"provider" => provider, "client_id" => client_id} = params,
        socket
      ) do
    args = %{
      "provider" => String.trim(provider),
      "client_id" => String.trim(client_id),
      "client_secret" => blank_to_nil(params["client_secret"])
    }

    case SystemLayer.call(socket, :set_client, "oauth/set_client", args, form: client_form()) do
      {:ok, _, socket} ->
        {:noreply,
         socket
         |> fetch_clients()
         |> assign(:show_add, nil)
         |> put_flash(:info, "Client credentials stored for #{args["provider"]}.")}

      {:asked, socket} ->
        {:noreply, socket}

      {:error, reason, socket} ->
        {:noreply, put_flash(socket, :error, "Could not store: #{fmt(reason)}")}
    end
  end

  def handle_event("delete_client", %{"provider" => provider}, socket) do
    case call_tool(socket, "oauth/delete_client", %{"provider" => provider}) do
      {:ok, _} ->
        {:noreply, socket |> fetch_clients() |> put_flash(:info, "Client credentials removed.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not remove: #{fmt(reason)}")}
    end
  end

  def handle_event(
        "create",
        %{"name" => name, "kind" => kind, "fields" => fields_text} = params,
        socket
      ) do
    case parse_fields(fields_text) do
      {:ok, fields} ->
        args = %{
          "name" => name,
          "kind" => kind,
          "fields" => fields,
          "destination" => SystemLayer.destination_params(params),
          "disclose" => SystemLayer.disclose_param(params)
        }

        case SystemLayer.call(socket, :create, "vault/create", args, form: create_form()) do
          {:ok, _, socket} ->
            {:noreply,
             socket
             |> fetch_entries()
             |> assign(:show_add, nil)
             |> put_flash(:info, "Entry created.")}

          {:asked, socket} ->
            {:noreply, socket}

          {:error, reason, socket} ->
            {:noreply, put_flash(socket, :error, "Create failed: #{fmt(reason)}")}
        end

      {:error, number} ->
        {:noreply, unreadable(socket, :create, bad_line(number))}
    end
  end

  def handle_event("authorize_new", params, socket) do
    args =
      %{
        "action" => "authorize",
        "name" => params["name"],
        "provider_hint" => params["provider"],
        "oauth_scopes" => split_lines(params["scopes"] || ""),
        "destination" => SystemLayer.destination_params(params),
        "disclose" => SystemLayer.disclose_param(params)
      }
      |> maybe_endpoints(params)

    start_grant(socket, args)
  end

  def handle_event("reauthorize", %{"id" => id}, socket) do
    start_grant(socket, %{"action" => "authorize", "id" => id})
  end

  def handle_event("dismiss_grant", _params, socket) do
    {:noreply, assign(socket, :pending_grant, nil)}
  end

  # ---------------------------------------------------------------------------
  # Events — per-entry
  # ---------------------------------------------------------------------------

  def handle_event("show_rotate", %{"id" => id}, socket) do
    {:noreply, assign(socket, :rotating, if(socket.assigns.rotating == id, do: nil, else: id))}
  end

  def handle_event(
        "rotate",
        %{"entry_id" => id, "fields" => fields_text, "payload_rev" => rev},
        socket
      ) do
    with {:ok, fields} <- parse_fields(fields_text),
         {rev_int, ""} <- Integer.parse(rev) do
      args = %{
        "action" => "rotate",
        "id" => id,
        "fields" => fields,
        "expected_payload_rev" => rev_int
      }

      case SystemLayer.call(socket, {:rotate, id}, "vault/rotate", args, form: rotate_form(id)) do
        {:ok, _, socket} ->
          {:noreply,
           socket
           |> fetch_entries()
           |> assign(:rotating, nil)
           |> put_flash(:info, "Material rotated — no re-consent needed.")}

        {:asked, socket} ->
          {:noreply, socket}

        {:error, reason, socket} ->
          {:noreply, put_flash(socket, :error, "Rotate failed: #{fmt(reason)}")}
      end
    else
      {:error, number} ->
        {:noreply, unreadable(socket, {:rotate, id}, bad_line(number))}

      _ ->
        {:noreply, unreadable(socket, {:rotate, id}, "Rotate failed: bad payload revision")}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case call_tool(socket, "vault/revoke", %{"id" => id}) do
      {:ok, result} ->
        affected = result[:affected] || []

        message =
          case affected do
            [] -> "Entry revoked."
            list -> "Entry revoked — #{length(list)} profile(s) lose access at next run."
          end

        {:noreply, socket |> fetch_entries() |> put_flash(:info, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Revoke failed: #{fmt(reason)}")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case call_tool(socket, "vault/delete", %{"id" => id}) do
      {:ok, _} ->
        {:noreply, socket |> fetch_entries() |> put_flash(:info, "Entry deleted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{fmt(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # Events — provided by this instance
  # ---------------------------------------------------------------------------

  # The athanor's default for the provider becomes this instance entry: a
  # consent of that provider here suggests it, and binds nothing until the
  # person commits it.
  def handle_event("use_by_default", %{"id" => id, "provider" => provider}, socket) do
    args = %{"provider_hint" => provider, "instance_entry_id" => id}

    case call_tool(socket, "vault/set_default", args) do
      {:ok, _} ->
        {:noreply,
         socket
         |> fetch_entries()
         |> put_flash(:info, "Used by default for #{provider} in this athanor.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Not made the default: #{fmt(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub — the callback landing an OAuth grant refreshes the list
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:load, socket) do
    {:noreply,
     socket
     |> fetch_entries()
     |> fetch_offered()
     |> fetch_used_by()
     |> fetch_clients()
     |> assign(:loading, false)}
  end

  def handle_info(%Cyfr.Bus.VaultEntryChanged{}, socket) do
    {:noreply, socket |> fetch_entries() |> assign(:pending_grant, nil)}
  end

  # An instance entry changed somewhere on this instance: what is offered
  # to this person is read again under their own context, and the
  # defaults with it, since a deleted entry is no athanor's default.
  def handle_info(%Cyfr.Bus.InstanceEntryChanged{}, socket) do
    {:noreply, socket |> fetch_offered() |> fetch_entries()}
  end

  # A change this page asked for was confirmed: a grant is started again
  # here, once; a typed form is submitted again by the browser.
  def handle_info({:system_layer, _id, _outcome} = report, socket) do
    case SystemLayer.reported(socket, report) do
      {:repeat, :authorize, _tool, args, socket} -> start_grant(socket, args)
      {:ok, socket} -> {:noreply, socket}
    end
  end

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp start_grant(socket, args) do
    case SystemLayer.call(socket, :authorize, "vault/authorize", args) do
      {:ok, result, socket} ->
        url = result[:url]

        {:noreply,
         socket
         |> assign(:pending_grant, url)
         |> assign(:show_add, nil)}

      {:asked, socket} ->
        {:noreply, socket}

      {:error, reason, socket} ->
        {:noreply, put_flash(socket, :error, "Authorization failed: #{fmt(reason)}")}
    end
  end

  # The forms that carry typed material, each kept as typed by the browser
  # (`phx-update="ignore"`) so it can be submitted again once its
  # confirmation is given.
  defp rotate_form(entry_id), do: "vault-rotate-form-" <> entry_id
  defp create_form, do: "vault-create-form"

  # A form this page sends again once its change is confirmed, arriving
  # with values that no longer read, dispatches nothing: the proof held for
  # it is let go (`SystemLayer.release/3`), its record cancelled, rather
  # than kept for a later submit to spend. The form's error is shown, and a
  # cancel that fails, which still drops the secret, is said in the same
  # message: the record ends at its expiry.
  defp unreadable(socket, tag, message) do
    case SystemLayer.release(socket, tag, :form_unreadable) do
      {:cancel_failed, socket} ->
        put_flash(
          socket,
          :error,
          message <> ". The approval could not be withdrawn; it ends when it expires."
        )

      {_released_or_none, socket} ->
        put_flash(socket, :error, message)
    end
  end

  # A line that does not read is named by its number, never its content: a
  # value pasted without its FIELD= would otherwise be shown back.
  defp bad_line(number), do: "Each line must be FIELD=value (line #{number} is not)"

  defp client_form, do: "vault-client-form"

  # The athanor's entries and its default per provider, read together.
  defp fetch_entries(socket) do
    case call_tool(socket, "vault/list", %{}) do
      {:ok, %{entries: list} = listing} when is_list(list) ->
        socket
        |> assign(:entries, Enum.map(list, &normalize_entry/1))
        |> assign(:defaults, Map.get(listing, :defaults) || %{})

      {:ok, other} ->
        Logger.warning("[VaultLive] vault/list failed: #{fmt({:unexpected_shape, other})}")
        assign(socket, entries: [], defaults: %{})

      {:error, reason} ->
        Logger.warning("[VaultLive] vault/list failed: #{fmt(reason)}")
        assign(socket, entries: [], defaults: %{})
    end
  end

  # The instance entries offered to this person, with their own use today:
  # an entry not offered to them is never read, so never shown. A read that
  # failed says so, and is never drawn as nothing offered.
  defp fetch_offered(socket) do
    case fetch_list(socket, "instance_entry/offered", :entries) do
      {:ok, offered} ->
        assign(socket, offered: offered, offered_error: nil)

      {:error, message} ->
        Logger.warning("[VaultLive] instance_entry/offered failed: #{message}")
        assign(socket, offered: [], offered_error: message)
    end
  end

  # Which MCP servers draw on each entry (headers referencing it) —
  # shown on the row, so revoking one is done knowing what it breaks.
  defp fetch_used_by(socket) do
    used_by =
      case call_tool(socket, "mcp_servers/list", %{}) do
        {:ok, %{servers: servers}} when is_list(servers) ->
          Enum.reduce(servers, %{}, fn server, acc ->
            Enum.reduce(server[:vault_refs] || [], acc, fn ref, acc ->
              Map.update(acc, ref, [server[:name]], &[server[:name] | &1])
            end)
          end)

        _ ->
          %{}
      end

    assign(socket, :used_by, used_by)
  end

  defp fetch_clients(socket) do
    clients =
      case call_tool(socket, "oauth/list", %{}) do
        {:ok, %{providers: rows}} when is_list(rows) -> rows
        _ -> []
      end

    assign(socket, :clients, clients)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)

  @entry_keys ~w(id name kind provider_hint status provenance field_names oauth_scopes destination attach_only payload_rev last_used_at)a

  defp normalize_entry(entry) do
    Map.new(@entry_keys, fn key -> {key, entry[key]} end)
  end

  defp parse_fields(text) when is_binary(text) do
    text
    |> split_lines()
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}}, fn {line, number}, {:ok, acc} ->
      case String.split(line, "=", parts: 2) do
        [key, value] when key != "" -> {:cont, {:ok, Map.put(acc, String.trim(key), value)}}
        _ -> {:halt, {:error, number}}
      end
    end)
  end

  defp split_lines(text) do
    text
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_endpoints(args, %{"authorize_url" => auth, "token_url" => token})
       when auth != "" and token != "" do
    Map.put(args, "oauth_endpoints", %{"authorize_url" => auth, "token_url" => token})
  end

  defp maybe_endpoints(args, _params), do: args

  # Renders through the console's one refusal seam — never `inspect/1`,
  # which put internal terms on the page.
  defp fmt(reason), do: error_message(reason)

  # Where an entry's material may go, in one line: scheme and hosts, the
  # port, and the methods and paths it is held to when it names them.
  defp destination_line(%{} = destination) do
    hosts = Enum.join(Map.get(destination, "hosts", []), ", ")

    [
      "#{Map.get(destination, "scheme", "https")}://#{hosts}",
      if(port = Map.get(destination, "port"), do: ":#{port}"),
      if(methods = Map.get(destination, "methods"), do: " · #{Enum.join(methods, " ")}"),
      if(paths = Map.get(destination, "paths"), do: " · #{Enum.join(paths, " ")}")
    ]
    |> Enum.join()
  end

  defp destination_line(_none), do: "no destination"

  # Whether this athanor's default for `provider` is the entry `target`
  # names, from the same rows `vault.list` answers.
  defp default?(defaults, provider, target) when is_binary(provider) and provider != "",
    do: Map.get(defaults, provider) == target

  defp default?(_defaults, _provider, _target), do: false

  defp policy_label("any"), do: "Any consented component"
  defp policy_label("shipped"), do: "Unmodified shipped components"
  defp policy_label(other), do: to_string(other)

  defp used_today(0), do: "none today"
  defp used_today(1), do: "1 request today"
  defp used_today(count) when is_integer(count), do: "#{count} requests today"
  defp used_today(_unread), do: "-"

  defp status_class("active"), do: "text-emerald-500"
  defp status_class("needs_reauth"), do: "text-amber-500"
  defp status_class(_), do: "text-red-500"

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.page_header title="Vault">
        <:actions>
          <.button variant="ghost" phx-click="show_add" phx-value-mode="oauth">
            Authorize OAuth
          </.button>
          <.button phx-click="show_add" phx-value-mode="fields">
            Add entry
          </.button>
        </:actions>
      </.page_header>

      <.card :if={@pending_grant}>
        <div class="space-y-2">
          <p class="text-sm">
            Continue in your browser to finish authorizing. This page updates when the
            provider redirects back.
          </p>
          <div class="flex items-center gap-3">
            <a
              href={@pending_grant}
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex items-center rounded-md bg-indigo-600 px-3 py-2 text-sm font-semibold text-white hover:bg-indigo-500"
            >
              Open provider consent
            </a>
            <.button variant="ghost" phx-click="dismiss_grant">Dismiss</.button>
          </div>
        </div>
      </.card>
      
    <!-- Add: sealed fields -->
      <.card :if={@show_add == "fields"}>
        <form id={create_form()} phx-update="ignore" phx-submit="create" class="space-y-4">
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Name</label>
              <.input name="name" required placeholder="My Supabase" />
            </div>
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Kind</label>
              <select name="kind" class="w-full rounded-md border-gray-600 bg-transparent text-sm">
                <option value="api_key">api_key</option>
                <option value="bundle">bundle</option>
              </select>
            </div>
          </div>
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">
              Fields — one FIELD=value per line, sealed at rest
            </label>
            <textarea
              name="fields"
              rows="4"
              required
              placeholder="SUPABASE_URL=https://…\nSUPABASE_ANON_KEY=…"
              class="w-full rounded-md border-gray-600 bg-transparent font-mono text-sm"
            ></textarea>
          </div>
          <.destination_inputs prefix="create" />
          <.button type="submit">Create entry</.button>
        </form>
      </.card>
      
    <!-- Add: OAuth grant -->
      <.card :if={@show_add == "oauth"}>
        <form phx-submit="authorize_new" class="space-y-4">
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Name</label>
              <.input name="name" required placeholder="My Google" />
            </div>
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Provider</label>
              <.input name="provider" required placeholder="google" />
            </div>
          </div>
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">
              Scopes — one per line
            </label>
            <textarea
              name="scopes"
              rows="2"
              class="w-full rounded-md border-gray-600 bg-transparent font-mono text-sm"
            ></textarea>
          </div>
          <details>
            <summary class="text-xs text-gray-500 cursor-pointer">
              Custom endpoints (unknown providers)
            </summary>
            <div class="grid grid-cols-2 gap-4 mt-2">
              <div>
                <label class="block text-xs text-gray-500 uppercase mb-1">Authorize URL</label>
                <.input name="authorize_url" placeholder="https://…" />
              </div>
              <div>
                <label class="block text-xs text-gray-500 uppercase mb-1">Token URL</label>
                <.input name="token_url" placeholder="https://…" />
              </div>
            </div>
          </details>
          <.destination_inputs prefix="oauth" />
          <p class="text-xs text-gray-500">
            The provider's client credentials must be configured first (oauth.set_client).
          </p>
          <.button type="submit">Start authorization</.button>
        </form>
      </.card>
      
    <!-- Entries list -->
      <.card>
        <div :if={@loading} class="py-8 text-center text-gray-500">Loading...</div>
        <div :if={!@loading && @entries == []} class="py-8">
          <.empty_state message="No vault entries yet" />
        </div>
        <.table :if={!@loading && @entries != []} id="vault-entries" rows={@entries}>
          <:col :let={entry} label="Name">
            <div class="space-y-1">
              <span class="font-medium">{entry.name}</span>
              <div class="text-xs text-gray-500 font-mono">{entry.id}</div>
              <div :if={Map.get(@used_by, entry.name, []) != []} class="text-xs text-amber-400/90">
                {used_by_line(@used_by[entry.name])}
              </div>
            </div>
          </:col>
          <:col :let={entry} label="Kind">
            <span class="font-mono text-xs">{entry.kind}</span>
            <span :if={entry.provider_hint not in [nil, ""]} class="text-xs text-gray-500">
              · {entry.provider_hint}
            </span>
            <div
              :if={default?(@defaults, entry.provider_hint, %{vault_entry_id: entry.id})}
              class="text-xs text-emerald-400"
              data-test="entry-default"
            >
              default for {entry.provider_hint}
            </div>
          </:col>
          <:col :let={entry} label="Holds">
            <span class="font-mono text-xs text-gray-400">
              {Enum.join(entry.field_names || [], ", ")}
            </span>
            <span :if={entry.kind == "oauth"} class="text-xs text-gray-500">
              {Enum.join(entry.oauth_scopes || [], " ")}
            </span>
          </:col>
          <:col :let={entry} label="Goes to">
            <div class="font-mono text-xs" data-test="entry-destination">
              {destination_line(entry.destination)}
            </div>
            <div class="text-xs text-gray-500" data-test="entry-disclosure">
              {if entry.attach_only == false,
                do: "disclosed: components read it",
                else:
                  "attach-only: never handed to a component; CYFR attaches it to requests " <>
                    "bound for its destination"}
            </div>
          </:col>
          <:col :let={entry} label="Status">
            <span class={["text-xs font-medium", status_class(entry.status)]}>
              {entry.status}
            </span>
          </:col>
          <:col :let={entry} label="Actions">
            <div class="flex flex-wrap gap-1">
              <.button
                :if={entry.kind != "oauth"}
                variant="ghost"
                phx-click="show_rotate"
                phx-value-id={entry.id}
              >
                Rotate
              </.button>
              <.button
                :if={entry.kind == "oauth"}
                variant="ghost"
                phx-click="reauthorize"
                phx-value-id={entry.id}
              >
                Re-authorize
              </.button>
              <.button
                variant="ghost"
                phx-click="revoke"
                phx-value-id={entry.id}
                data-confirm={revoke_confirm(entry, @used_by)}
              >
                Revoke
              </.button>
              <.button
                variant="ghost"
                phx-click="delete"
                phx-value-id={entry.id}
                data-confirm="Delete this entry and erase its sealed material?"
              >
                Delete
              </.button>
            </div>
          </:col>
        </.table>
      </.card>

      <%!-- Provided by this instance: the instance entries offered to this person --%>
      <.card>
        <section data-test="instance-offered" class="space-y-2">
          <h3 class="text-sm font-medium text-gray-400">Provided by this instance</h3>
          <p class="text-xs text-gray-500">
            Accounts this instance's administrator offers to you. Each is attach-only: its value
            is never handed to a component, and CYFR attaches it to requests bound for its
            destination. Your use today counts your own requests alone.
          </p>
          <p
            :if={@offered_error}
            role="alert"
            class="text-xs text-red-400"
            data-test="instance-offered-unread"
          >
            This instance's entries could not be read: {@offered_error}
          </p>
          <div
            :if={!@loading && is_nil(@offered_error) && @offered == []}
            class="text-xs text-gray-500"
          >
            This instance offers you no entry.
          </div>
          <ul :if={@offered != []} class="divide-y divide-gray-800">
            <li
              :for={offer <- @offered}
              class="flex flex-wrap items-center justify-between gap-2 py-2 text-sm"
              data-test="offered-entry"
              data-id={offer.id}
            >
              <div class="space-y-1">
                <div>
                  <span class="font-medium">{offer.name}</span>
                  <span class="text-xs text-gray-500">· {offer.provider_hint}</span>
                </div>
                <div class="font-mono text-xs" data-test="offered-destination">
                  {destination_line(offer.destination)}
                </div>
                <div class="text-xs text-gray-500" data-test="offered-policy">
                  {policy_label(offer.component_policy)}
                </div>
                <div class="text-xs text-gray-500" data-test="offered-use">
                  Your use: {used_today(offer.used_today)}
                  <span :if={offer.cap_reached} data-test="offered-cap-reached">
                    Your daily limit is reached; it resets at midnight UTC.
                  </span>
                </div>
              </div>
              <span
                :if={default?(@defaults, offer.provider_hint, %{instance_entry_id: offer.id})}
                class="text-xs text-emerald-400"
                data-test="offered-default"
              >
                default for {offer.provider_hint}
              </span>
              <.button
                :if={
                  offer.provider_hint not in [nil, ""] and
                    not default?(@defaults, offer.provider_hint, %{instance_entry_id: offer.id})
                }
                variant="ghost"
                phx-click="use_by_default"
                phx-value-id={offer.id}
                phx-value-provider={offer.provider_hint}
                data-test="offered-use-by-default"
              >
                Use by default for {offer.provider_hint}
              </.button>
            </li>
          </ul>
        </section>
      </.card>
      
    <!-- Rotate form -->
      <.card :if={@rotating}>
        <% entry = Enum.find(@entries, &(&1.id == @rotating)) %>
        <form
          :if={entry}
          id={rotate_form(entry.id)}
          phx-update="ignore"
          phx-submit="rotate"
          class="space-y-4"
        >
          <input type="hidden" name="entry_id" value={entry.id} />
          <input type="hidden" name="payload_rev" value={entry.payload_rev} />
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">
              New material for {entry.name} — every field, one FIELD=value per line
              ({Enum.join(entry.field_names || [], ", ")})
            </label>
            <textarea
              name="fields"
              rows="4"
              required
              class="w-full rounded-md border-gray-600 bg-transparent font-mono text-sm"
            ></textarea>
          </div>
          <p class="text-xs text-gray-500">
            Rotation replaces material only — bindings and consents are untouched.
          </p>
          <.button type="submit">Rotate material</.button>
        </form>
      </.card>
      
    <!-- OAuth client credentials: the operator's app per provider -->
      <.card>
        <div class="flex items-center justify-between mb-2">
          <h3 class="text-sm font-medium text-gray-400">OAuth client credentials</h3>
          <.button variant="ghost" phx-click="show_add" phx-value-mode="client">
            {if @show_add == "client", do: "Cancel", else: "Set client"}
          </.button>
        </div>
        <p class="text-xs text-gray-500 mb-3">
          The OAuth app (client id and secret) an OAuth vault entry is authorized through, one
          per provider. Stored sealed in this athanor; only the provider name is ever shown.
        </p>

        <form
          :if={@show_add == "client"}
          id={client_form()}
          phx-update="ignore"
          phx-submit="set_client"
          class="space-y-3 mb-4"
        >
          <div class="grid grid-cols-3 gap-3">
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Provider</label>
              <.input name="provider" required placeholder="google" />
            </div>
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Client id</label>
              <.input name="client_id" required placeholder="…apps.googleusercontent.com" />
            </div>
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Client secret</label>
              <.input name="client_secret" type="password" placeholder="(public clients: empty)" />
            </div>
          </div>
          <.button type="submit">Store client credentials</.button>
        </form>

        <div :if={@clients == []} class="text-xs text-gray-500">No client credentials stored.</div>
        <ul :if={@clients != []} class="divide-y divide-gray-800">
          <li
            :for={c <- @clients}
            class="flex items-center justify-between py-2 text-sm"
          >
            <span>
              <span class="font-medium text-gray-200">{c[:provider]}</span>
              <span class="ml-2 text-xs text-gray-500">
                set by {c[:created_by] || "-"}
              </span>
            </span>
            <.button
              variant="ghost"
              phx-click="delete_client"
              phx-value-provider={c[:provider]}
              data-confirm="Remove these client credentials? OAuth entries for this provider cannot refresh until new ones are stored."
            >
              Remove
            </.button>
          </li>
        </ul>
      </.card>

      <.live_component module={SystemLayer} id={SystemLayer.layer_id()} context={@context} />
    </div>
    """
  end

  # The destination and disclosure a new entry names, asked of the person:
  # nothing is prefilled, and disclosure is off until it is turned on.
  attr :prefix, :string, required: true

  defp destination_inputs(assigns) do
    ~H"""
    <fieldset class="space-y-2" data-test={"#{@prefix}-destination"}>
      <legend class="text-xs text-gray-500 uppercase">Where its material may go</legend>
      <div>
        <label class="block text-xs text-gray-500 mb-1">
          Hosts — for example api.example.com, or *.example.com
        </label>
        <.input name="destination_hosts" required placeholder="api.example.com" />
      </div>
      <div class="grid grid-cols-2 gap-4">
        <div>
          <label class="block text-xs text-gray-500 mb-1">Scheme</label>
          <select
            name="destination_scheme"
            class="w-full rounded-md border-gray-600 bg-transparent text-sm"
          >
            <option value="https">https</option>
            <option value="http">http</option>
          </select>
        </div>
        <div>
          <label class="block text-xs text-gray-500 mb-1">Port (optional)</label>
          <.input name="destination_port" placeholder="443" />
        </div>
      </div>
      <div class="grid grid-cols-2 gap-4">
        <div>
          <label class="block text-xs text-gray-500 mb-1">Methods (optional)</label>
          <.input name="destination_methods" placeholder="GET POST" />
        </div>
        <div>
          <label class="block text-xs text-gray-500 mb-1">Path prefixes (optional)</label>
          <.input name="destination_paths" placeholder="/v1/" />
        </div>
      </div>
      <label class="flex items-start gap-2 text-sm">
        <input type="checkbox" name="disclose" value="true" data-test={"#{@prefix}-disclose"} />
        <span>
          Let components read the value itself. Left off, the value is never handed to a
          component: CYFR attaches it to requests bound for the entry's destination, and a
          component asking for it is refused.
        </span>
      </label>
    </fieldset>
    """
  end

  defp used_by_line([server]), do: "used by MCP server #{server}"
  defp used_by_line(servers), do: "used by MCP servers #{Enum.join(Enum.sort(servers), ", ")}"

  defp revoke_confirm(entry, used_by) do
    base = "Profiles bound to this entry stop receiving it at their next run."

    case Map.get(used_by, entry.name, []) do
      [] -> base <> " Revoke?"
      servers -> base <> " MCP server(s) #{Enum.join(servers, ", ")} read it too. Revoke?"
    end
  end
end
