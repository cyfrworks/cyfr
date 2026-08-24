# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.McpServersLive do
  @moduledoc """
  External MCP servers registered with the athanor — list / add / delete /
  test / refresh / enable / disable over the `mcp_servers` tool. Tools a
  server exposes reach AQUA as `<name>:<tool>`.

  Built-in preset: the **mcp-bridge** gateway, the sidecar in the docker
  stack that wraps stdio/npx MCP servers (filesystem, github, …) behind one
  HTTP endpoint. CYFR sees one external server called `bridge`; the
  gateway's admin tools (`bridge:list_backends`, `bridge:add_backend`,
  `bridge:remove_backend`, `bridge:restart_backend`) let a member manage
  the stdio backends from this page once the bridge is registered. The URL
  `http://mcp-bridge:8001/mcp` resolves inside the compose network; the
  browser never connects to it directly. The bridge boots closed behind
  `MCP_BRIDGE_TOKEN`; the preset sends it as `Authorization:
  vault:mcp_bridge_token` — a Connection named `mcp_bridge_token` holding
  the same value.
  """

  use PrismWeb, :live_view

  require Logger

  @bridge_name "bridge"
  @bridge_url "http://mcp-bridge:8001/mcp"
  @bridge_headers %{"Authorization" => "vault:mcp_bridge_token"}

  @placeholder_config Jason.encode!(
                        %{
                          "url" => "https://mcp.example.com/mcp",
                          "headers" => %{"Authorization" => "vault:my-connection"}
                        },
                        pretty: true
                      )

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "MCP Servers")
      |> assign(:active_nav, "mcp_servers")
      |> assign(:servers, [])
      |> assign(:show_add, false)
      |> assign(:loading, true)
      |> assign(:expanded_name, nil)
      |> assign(:detail, nil)
      |> assign(:json_error, nil)
      |> assign(:backends, [])
      |> assign(:show_add_backend, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_add", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add, !socket.assigns.show_add)
     |> assign(:json_error, nil)}
  end

  def handle_event("add_server", %{"name" => name, "config" => config_json}, socket) do
    with {:name, true} <- {:name, name != ""},
         {:json, {:ok, config}} <- {:json, Jason.decode(config_json)},
         {:url, true} <- {:url, is_binary(config["url"]) and config["url"] != ""} do
      case call_tool(socket, "mcp_servers/create", %{"name" => name, "config" => config}) do
        {:ok, _result} ->
          {:noreply,
           socket
           |> refresh_servers()
           |> assign(:show_add, false)
           |> assign(:json_error, nil)
           |> put_flash(:info, "Server '#{name}' added.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to add: #{inspect(reason)}")}
      end
    else
      {:name, _} ->
        {:noreply, assign(socket, :json_error, "Name is required.")}

      {:json, {:error, %Jason.DecodeError{} = err}} ->
        {:noreply, assign(socket, :json_error, "Invalid JSON: #{Exception.message(err)}")}

      {:url, _} ->
        {:noreply, assign(socket, :json_error, "Config must include a \"url\" field.")}
    end
  end

  # Register the local mcp-bridge gateway with the preset entry.
  def handle_event("setup_bridge", _params, socket) do
    case call_tool(socket, "mcp_servers/create", %{
           "name" => @bridge_name,
           "config" => %{"url" => @bridge_url, "headers" => @bridge_headers}
         }) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_servers()
         |> put_flash(
           :info,
           "MCP Bridge registered. Store the bridge token as a Connection named " <>
             "mcp_bridge_token, then add backends below."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to register the bridge: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_add_backend", _params, socket) do
    {:noreply, assign(socket, :show_add_backend, !socket.assigns.show_add_backend)}
  end

  def handle_event("add_backend", %{"name" => name, "command" => command}, socket) do
    name = String.trim(name)
    command = String.trim(command)

    if name == "" or command == "" do
      {:noreply, put_flash(socket, :error, "A backend needs a name and a command.")}
    else
      case call_tool(socket, bridge_tool("add_backend"), %{"name" => name, "command" => command}) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:show_add_backend, false)
           |> refresh_backends()
           |> put_flash(:info, "Backend '#{name}' added.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Bridge: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("remove_backend", %{"name" => name}, socket) do
    case call_tool(socket, bridge_tool("remove_backend"), %{"name" => name}) do
      {:ok, _} ->
        {:noreply, socket |> refresh_backends() |> put_flash(:info, "Backend '#{name}' removed.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Bridge: #{inspect(reason)}")}
    end
  end

  def handle_event("restart_backend", %{"name" => name}, socket) do
    case call_tool(socket, bridge_tool("restart_backend"), %{"name" => name}) do
      {:ok, _} ->
        {:noreply,
         socket |> refresh_backends() |> put_flash(:info, "Backend '#{name}' restarted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Bridge: #{inspect(reason)}")}
    end
  end

  def handle_event("refresh_backends", _params, socket) do
    {:noreply, refresh_backends(socket)}
  end

  def handle_event("delete", %{"name" => name}, socket) do
    case call_tool(socket, "mcp_servers/delete", %{"name" => name}) do
      {:ok, _} ->
        servers = Enum.reject(socket.assigns.servers, &(&1[:name] == name))

        expanded_name =
          if socket.assigns.expanded_name == name, do: nil, else: socket.assigns.expanded_name

        {:noreply,
         socket
         |> assign(:servers, servers)
         |> assign(:expanded_name, expanded_name)
         |> assign(:detail, if(expanded_name == nil, do: nil, else: socket.assigns.detail))
         |> put_flash(:info, "Server '#{name}' deleted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_enabled", %{"name" => name, "enabled" => enabled}, socket) do
    action = if enabled == "true", do: "disable", else: "enable"

    case call_tool(socket, "mcp_servers/#{action}", %{"name" => name}) do
      {:ok, _} ->
        {:noreply, refresh_servers(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  def handle_event("test", %{"name" => name}, socket) do
    case call_tool(socket, "mcp_servers/test", %{"name" => name}) do
      {:ok, result} ->
        status = result[:status] || "unknown"

        {:noreply,
         socket
         |> refresh_servers()
         |> put_flash(:info, "Test #{name}: #{status}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Test failed: #{inspect(reason)}")}
    end
  end

  def handle_event("refresh", %{"name" => name}, socket) do
    case call_tool(socket, "mcp_servers/refresh", %{"name" => name}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_servers()
         |> put_flash(:info, "Refreshed #{name}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Refresh failed: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_expand", %{"name" => name}, socket) do
    if socket.assigns.expanded_name == name do
      {:noreply,
       socket
       |> assign(:expanded_name, nil)
       |> assign(:detail, nil)}
    else
      detail =
        case call_tool(socket, "mcp_servers/get", %{"name" => name}) do
          {:ok, result} -> normalize_keys(result)
          {:error, _} -> nil
        end

      # Sync the list row with fresh status/tool_count from the detail
      servers =
        if detail do
          Enum.map(socket.assigns.servers, fn s ->
            if s[:name] == name do
              s
              |> Map.put(:status, detail[:status])
              |> Map.put(:tool_count, length(detail[:tools] || []))
            else
              s
            end
          end)
        else
          socket.assigns.servers
        end

      {:noreply,
       socket
       |> assign(:servers, servers)
       |> assign(:expanded_name, name)
       |> assign(:detail, detail)}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if connected?(socket) do
      ctx = socket.assigns[:context]
      Phoenix.PubSub.subscribe(Emissary.PubSub, Prism.Topics.mcp_servers(ctx))
      {:noreply, socket |> refresh_servers() |> assign(:loading, false)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:mcp_servers_changed, socket) do
    {:noreply, refresh_servers(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[McpServersLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp refresh_servers(socket) do
    servers =
      case call_tool(socket, "mcp_servers/list", %{}) do
        {:ok, %{servers: list}} -> list
        {:ok, %{"servers" => list}} -> list
        _ -> []
      end
      |> Enum.map(&normalize_keys/1)

    socket
    |> assign(:servers, servers)
    |> refresh_backends()
  end

  # The bridge's own backends, when the bridge is registered and answering.
  defp refresh_backends(socket) do
    if bridge_ready?(socket.assigns.servers) do
      backends =
        case call_tool(socket, bridge_tool("list_backends"), %{}) do
          {:ok, result} -> coerce_backends(result)
          {:error, _} -> []
        end

      assign(socket, :backends, backends)
    else
      assign(socket, :backends, [])
    end
  end

  defp bridge_entry(servers), do: Enum.find(servers, &(&1[:name] == @bridge_name))

  defp bridge_ready?(servers) do
    case bridge_entry(servers) do
      %{enabled: true, status: status} -> status in ["ready", "connected"]
      _ -> false
    end
  end

  defp bridge_tool(tool), do: @bridge_name <> ":" <> tool

  # The bridge answers as MCP content (a JSON text block) or, in-process, as
  # the decoded map; either way the list is under "backends".
  defp coerce_backends(result) do
    obj =
      case result do
        %{"content" => [%{"text" => text} | _]} when is_binary(text) ->
          case Jason.decode(text) do
            {:ok, %{} = m} -> m
            _ -> %{}
          end

        %{} = m ->
          m

        _ ->
          %{}
      end

    (obj["backends"] || obj[:backends] || [])
    |> Enum.map(fn b ->
      %{
        name: to_string(b["name"] || b[:name] || ""),
        command: to_string(b["command"] || b[:command] || ""),
        status: to_string(b["status"] || b[:status] || "unknown"),
        tool_count: b["tool_count"] || b[:tool_count] || 0,
        error: b["error"] || b[:error]
      }
    end)
  end

  @known_server_keys %{
    "name" => :name,
    "url" => :url,
    "enabled" => :enabled,
    "status" => :status,
    "tool_count" => :tool_count,
    "tools" => :tools,
    "config" => :config,
    "server_info" => :server_info,
    "error" => :error,
    "count" => :count,
    "servers" => :servers,
    "action" => :action
  }

  defp normalize_keys(%{} = map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {Map.get(@known_server_keys, k, k), v}
      {k, v} -> {k, v}
    end)
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:placeholder_config, @placeholder_config)
      |> assign(:bridge, bridge_entry(assigns.servers))
      |> assign(:bridge_ready, bridge_ready?(assigns.servers))

    ~H"""
    <div class="space-y-6">
      <.page_header title="External MCP Servers">
        <:actions>
          <.button :if={!@loading and is_nil(@bridge)} variant="ghost" phx-click="setup_bridge">
            + Setup MCP Bridge
          </.button>
          <.button phx-click="toggle_add">
            {if @show_add, do: "Cancel", else: "Add Server"}
          </.button>
        </:actions>
      </.page_header>

      <.card :if={@show_add}>
        <form phx-submit="add_server" class="space-y-4">
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">Name</label>
            <.input name="name" required placeholder="notion" class="max-w-xs font-mono" />
          </div>
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">
              Config (mcp.json format)
            </label>
            <.textarea
              name="config"
              rows="6"
              required
              placeholder={@placeholder_config}
              class="font-mono"
            />
            <p class="text-xs text-gray-600 mt-1">
              Use <code class="text-gray-500">vault:CONNECTION</code>
              in header values to reference a stored Connection
              (create one on the Connections page).
            </p>
          </div>
          <div :if={@json_error} class="text-sm text-red-400">{@json_error}</div>
          <.button type="submit">Add Server</.button>
        </form>
      </.card>

      <.card>
        <div :if={@loading} class="py-8 text-center text-gray-500">Loading...</div>
        <div :if={!@loading && @servers == []} class="py-8">
          <.empty_state message="No external MCP servers configured" />
        </div>
        <div :if={!@loading && @servers != []} class="overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-800">
            <thead>
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Name
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  URL
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Status
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Tools
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-800">
              <%= for server <- @servers do %>
                <tr
                  class="cursor-pointer hover:bg-gray-800/50 transition-colors"
                  phx-click="toggle_expand"
                  phx-value-name={server[:name]}
                >
                  <td class="px-4 py-3 text-sm whitespace-nowrap">
                    <span class="font-mono text-blue-400">{server[:name]}</span>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-300 whitespace-nowrap">
                    <span class="text-gray-400 text-xs font-mono truncate max-w-xs inline-block">
                      {server[:url]}
                    </span>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-300 whitespace-nowrap">
                    <.badge color={status_color(server[:status])}>
                      {server[:status] || "unknown"}
                    </.badge>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-300 whitespace-nowrap">
                    {server[:tool_count] || 0}
                  </td>
                </tr>
                <tr :if={@expanded_name == server[:name]} class="bg-gray-900/60">
                  <td colspan="4" class="px-4 py-4">
                    <div class="space-y-4">
                      <div :if={@detail && (@detail[:tools] || []) != []} class="space-y-2">
                        <h4 class="text-sm font-medium text-gray-400 mb-2">
                          Discovered Tools ({length(@detail[:tools] || [])})
                        </h4>
                        <div class="space-y-1">
                          <div
                            :for={tool <- @detail[:tools] || []}
                            class="flex items-baseline gap-2 text-sm px-2 py-1 rounded bg-gray-800/50"
                          >
                            <span class="font-mono text-blue-400">
                              {tool["name"]}
                            </span>
                            <span class="text-gray-500 text-xs truncate">
                              {tool["description"]}
                            </span>
                          </div>
                        </div>
                      </div>
                      <div class="flex gap-2 pt-2 border-t border-gray-800">
                        <.button
                          variant="ghost"
                          phx-click="toggle_enabled"
                          phx-value-name={server[:name]}
                          phx-value-enabled={to_string(server[:enabled])}
                        >
                          {if server[:enabled] == true, do: "Disable", else: "Enable"}
                        </.button>
                        <.button
                          variant="ghost"
                          phx-click="test"
                          phx-value-name={server[:name]}
                        >
                          Test
                        </.button>
                        <.button
                          variant="ghost"
                          phx-click="refresh"
                          phx-value-name={server[:name]}
                        >
                          Refresh
                        </.button>
                        <.button
                          variant="ghost"
                          phx-click="delete"
                          phx-value-name={server[:name]}
                          data-confirm="Delete this server?"
                        >
                          Delete
                        </.button>
                      </div>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </.card>

      <.card :if={@bridge}>
        <div class="flex items-center justify-between mb-3">
          <div>
            <h3 class="text-sm font-medium text-gray-200">Bridge backends</h3>
            <p class="text-xs text-gray-500 mt-0.5">
              stdio / npx MCP servers the <span class="font-mono">bridge</span>
              gateway runs; their tools surface as <span class="font-mono">bridge:&lt;backend&gt;__&lt;tool&gt;</span>.
            </p>
          </div>
          <div class="flex gap-2">
            <.button variant="ghost" phx-click="refresh_backends" disabled={!@bridge_ready}>
              Refresh
            </.button>
            <.button variant="ghost" phx-click="toggle_add_backend" disabled={!@bridge_ready}>
              {if @show_add_backend, do: "Cancel", else: "Add backend"}
            </.button>
          </div>
        </div>

        <p :if={!@bridge_ready} class="text-xs text-amber-400">
          The bridge is registered but not answering yet — check the
          <span class="font-mono">mcp-bridge</span>
          container and the <span class="font-mono">mcp_bridge_token</span>
          Connection,
          then Test the server above.
        </p>

        <form
          :if={@show_add_backend and @bridge_ready}
          phx-submit="add_backend"
          class="space-y-3 mb-4"
        >
          <div class="grid gap-3 md:grid-cols-2">
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Name</label>
              <.input name="name" required placeholder="fs" class="font-mono" />
            </div>
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Command</label>
              <.input
                name="command"
                required
                placeholder="npx -y @modelcontextprotocol/server-filesystem /data"
                class="font-mono"
              />
            </div>
          </div>
          <.button type="submit">Add backend</.button>
        </form>

        <div :if={@bridge_ready and @backends == []} class="py-4 text-sm text-gray-500">
          No backends yet.
        </div>
        <div :if={@backends != []} class="overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-800">
            <thead>
              <tr>
                <th class="px-4 py-2 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Name
                </th>
                <th class="px-4 py-2 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Command
                </th>
                <th class="px-4 py-2 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Status
                </th>
                <th class="px-4 py-2 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Tools
                </th>
                <th class="px-4 py-2"></th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-800">
              <tr :for={b <- @backends}>
                <td class="px-4 py-2 text-sm font-mono text-blue-400 whitespace-nowrap">{b.name}</td>
                <td class="px-4 py-2 text-xs font-mono text-gray-400 truncate max-w-md">
                  {b.command}
                </td>
                <td class="px-4 py-2 text-sm whitespace-nowrap">
                  <.badge color={status_color(b.status)}>{b.status}</.badge>
                  <span :if={b.error} class="ml-2 text-xs text-red-400 truncate">{b.error}</span>
                </td>
                <td class="px-4 py-2 text-sm text-gray-300">{b.tool_count}</td>
                <td class="px-4 py-2 text-right whitespace-nowrap">
                  <.button variant="ghost" phx-click="restart_backend" phx-value-name={b.name}>
                    Restart
                  </.button>
                  <.button
                    variant="ghost"
                    phx-click="remove_backend"
                    phx-value-name={b.name}
                    data-confirm={"Remove backend '#{b.name}'?"}
                  >
                    Remove
                  </.button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.card>
    </div>
    """
  end

  defp status_color("ready"), do: "green"
  defp status_color("connected"), do: "green"
  defp status_color("running"), do: "green"
  defp status_color("error"), do: "red"
  defp status_color("crashed"), do: "red"
  defp status_color("disconnected"), do: "yellow"
  defp status_color("starting"), do: "yellow"
  defp status_color(_), do: "gray"
end
