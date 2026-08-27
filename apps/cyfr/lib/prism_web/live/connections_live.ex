# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ConnectionsLive do
  @moduledoc """
  The operator's Connections (vault entries): list, create, rotate,
  re-authorize, rename, revoke, delete — all through the vault MCP verbs,
  so this surface holds no rules of its own. Material flows one way:
  forms accept field values; nothing here ever displays them.

  OAuth connections start a browser grant via `vault.authorize`; the
  callback completes it server-side and the vault PubSub topic refreshes
  this view when the entry lands.
  """

  use PrismWeb, :live_view

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe once, at mount — handle_params re-fires on every patch,
    # and PubSub's :duplicate registry would deliver every message twice.
    if connected?(socket) do
      ctx = socket.assigns[:context]
      Phoenix.PubSub.subscribe(Emissary.PubSub, Prism.Topics.vault_changed(ctx))
    end

    socket =
      socket
      |> assign(:page_title, "Connections")
      |> assign(:active_nav, "connections")
      |> assign(:entries, [])
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
    if connected?(socket) do
      {:noreply,
       socket |> fetch_entries() |> fetch_used_by() |> fetch_clients() |> assign(:loading, false)}
    else
      {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Events — create
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("show_add", %{"mode" => mode}, socket) do
    {:noreply,
     assign(socket, :show_add, if(socket.assigns.show_add == mode, do: nil, else: mode))}
  end

  # The operator's OAuth app for a provider — the client id/secret a
  # Connection's OAuth grant is obtained with. Stored per athanor; listed by
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

    case call_tool(socket, "oauth/set_client", args) do
      {:ok, _} ->
        {:noreply,
         socket
         |> fetch_clients()
         |> assign(:show_add, nil)
         |> put_flash(:info, "Client credentials stored for #{args["provider"]}.")}

      {:error, reason} ->
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

  def handle_event("create", %{"name" => name, "kind" => kind, "fields" => fields_text}, socket) do
    case parse_fields(fields_text) do
      {:ok, fields} ->
        args = %{"name" => name, "kind" => kind, "fields" => fields}

        case call_tool(socket, "vault/create", args) do
          {:ok, _} ->
            {:noreply,
             socket
             |> fetch_entries()
             |> assign(:show_add, nil)
             |> put_flash(:info, "Connection created.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Create failed: #{fmt(reason)}")}
        end

      {:error, line} ->
        {:noreply, put_flash(socket, :error, "Each line must be FIELD=value (bad: #{line})")}
    end
  end

  def handle_event("authorize_new", params, socket) do
    args =
      %{
        "action" => "authorize",
        "name" => params["name"],
        "provider_hint" => params["provider"],
        "oauth_scopes" => split_lines(params["scopes"] || "")
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

      case call_tool(socket, "vault/rotate", args) do
        {:ok, _} ->
          {:noreply,
           socket
           |> fetch_entries()
           |> assign(:rotating, nil)
           |> put_flash(:info, "Material rotated — no re-consent needed.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Rotate failed: #{fmt(reason)}")}
      end
    else
      {:error, line} ->
        {:noreply, put_flash(socket, :error, "Each line must be FIELD=value (bad: #{line})")}

      _ ->
        {:noreply, put_flash(socket, :error, "Rotate failed: bad payload revision")}
    end
  end

  def handle_event("rename", %{"id" => id, "name" => name}, socket) do
    case call_tool(socket, "vault/rename", %{"id" => id, "name" => name}) do
      {:ok, _} ->
        {:noreply, socket |> fetch_entries() |> put_flash(:info, "Renamed.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Rename failed: #{fmt(reason)}")}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case call_tool(socket, "vault/revoke", %{"id" => id}) do
      {:ok, result} ->
        affected = result[:affected] || result["affected"] || []

        message =
          case affected do
            [] -> "Connection revoked."
            list -> "Connection revoked — #{length(list)} profile(s) lose access at next run."
          end

        {:noreply, socket |> fetch_entries() |> put_flash(:info, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Revoke failed: #{fmt(reason)}")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case call_tool(socket, "vault/delete", %{"id" => id}) do
      {:ok, _} ->
        {:noreply, socket |> fetch_entries() |> put_flash(:info, "Connection deleted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{fmt(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub — the callback landing an OAuth grant refreshes the list
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:vault_entry_changed, _id, _verb}, socket) do
    {:noreply, socket |> fetch_entries() |> assign(:pending_grant, nil)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[ConnectionsLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp start_grant(socket, args) do
    case call_tool(socket, "vault/authorize", args) do
      {:ok, result} ->
        url = result[:url] || result["url"]

        {:noreply,
         socket
         |> assign(:pending_grant, url)
         |> assign(:show_add, nil)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Authorization failed: #{fmt(reason)}")}
    end
  end

  defp fetch_entries(socket) do
    case fetch_list(socket, "vault/list", :entries) do
      {:ok, list} ->
        assign(socket, :entries, Enum.map(list, &normalize_entry/1))

      {:error, message} ->
        Logger.warning("[ConnectionsLive] vault/list failed: #{message}")
        assign(socket, :entries, [])
    end
  end

  # Which MCP servers draw on each Connection (`vault:<name>` headers) —
  # shown on the row, so revoking one is done knowing what it breaks.
  defp fetch_used_by(socket) do
    used_by =
      case call_tool(socket, "mcp_servers/list", %{}) do
        {:ok, %{servers: servers}} when is_list(servers) ->
          Enum.reduce(servers, %{}, fn server, acc ->
            Enum.reduce(server[:vault_refs] || server["vault_refs"] || [], acc, fn ref, acc ->
              Map.update(acc, ref, [server[:name] || server["name"]], &[server[:name] | &1])
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

  @entry_keys ~w(id name kind provider_hint status provenance field_names oauth_scopes payload_rev last_used_at)a

  defp normalize_entry(entry) do
    Map.new(@entry_keys, fn key -> {key, entry[key]} end)
  end

  defp parse_fields(text) when is_binary(text) do
    text
    |> split_lines()
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      case String.split(line, "=", parts: 2) do
        [key, value] when key != "" -> {:cont, {:ok, Map.put(acc, String.trim(key), value)}}
        _ -> {:halt, {:error, line}}
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

  defp fmt(reason) when is_binary(reason), do: reason
  defp fmt(reason), do: inspect(reason)

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
      <.page_header title="Connections">
        <:actions>
          <.button variant="ghost" phx-click="show_add" phx-value-mode="oauth">
            Connect OAuth
          </.button>
          <.button phx-click="show_add" phx-value-mode="fields">
            Add Connection
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
        <form phx-submit="create" class="space-y-4">
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
          <.button type="submit">Create Connection</.button>
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
          <p class="text-xs text-gray-500">
            The provider's client credentials must be configured first (oauth.set_client).
          </p>
          <.button type="submit">Start authorization</.button>
        </form>
      </.card>
      
    <!-- Connections list -->
      <.card>
        <div :if={@loading} class="py-8 text-center text-gray-500">Loading...</div>
        <div :if={!@loading && @entries == []} class="py-8">
          <.empty_state message="No connections yet" />
        </div>
        <.table :if={!@loading && @entries != []} id="connections" rows={@entries}>
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
          </:col>
          <:col :let={entry} label="Holds">
            <span class="font-mono text-xs text-gray-400">
              {Enum.join(entry.field_names || [], ", ")}
            </span>
            <span :if={entry.kind == "oauth"} class="text-xs text-gray-500">
              {Enum.join(entry.oauth_scopes || [], " ")}
            </span>
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
                data-confirm="Delete this connection and erase its sealed material?"
              >
                Delete
              </.button>
            </div>
          </:col>
        </.table>
      </.card>
      
    <!-- Rotate form -->
      <.card :if={@rotating}>
        <% entry = Enum.find(@entries, &(&1.id == @rotating)) %>
        <form :if={entry} phx-submit="rotate" class="space-y-4">
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
          The OAuth app (client id and secret) an OAuth Connection is authorized through, one
          per provider. Stored sealed in this athanor; only the provider name is ever shown.
        </p>

        <form :if={@show_add == "client"} phx-submit="set_client" class="space-y-3 mb-4">
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
              <span class="font-medium text-gray-200">{c[:provider] || c["provider"]}</span>
              <span class="ml-2 text-xs text-gray-500">
                set by {c[:created_by] || c["created_by"] || "-"}
              </span>
            </span>
            <.button
              variant="ghost"
              phx-click="delete_client"
              phx-value-provider={c[:provider] || c["provider"]}
              data-confirm="Remove these client credentials? OAuth Connections for this provider cannot refresh until new ones are stored."
            >
              Remove
            </.button>
          </li>
        </ul>
      </.card>
    </div>
    """
  end

  defp used_by_line([server]), do: "used by MCP server #{server}"
  defp used_by_line(servers), do: "used by MCP servers #{Enum.join(Enum.sort(servers), ", ")}"

  defp revoke_confirm(entry, used_by) do
    base = "Profiles bound to this connection stop receiving it at their next run."

    case Map.get(used_by, entry.name, []) do
      [] -> base <> " Revoke?"
      servers -> base <> " MCP server(s) #{Enum.join(servers, ", ")} read it too. Revoke?"
    end
  end
end
