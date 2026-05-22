# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.McpServersLive do
  use PrismWeb, :live_view

  require Logger

  @placeholder_config Jason.encode!(
                        %{
                          "url" => "https://mcp.example.com/mcp",
                          "headers" => %{"Authorization" => "secret:MY_API_KEY"}
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
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.PubSub.topic("prism:mcp_servers", ctx))
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

    assign(socket, :servers, servers)
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
    assigns = assign(assigns, :placeholder_config, @placeholder_config)

    ~H"""
    <div class="space-y-6">
      <.page_header title="External MCP Servers">
        <:actions>
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
              Use <code class="text-gray-500">secret:NAME</code> in header values to reference stored secrets.
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
                <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Name</th>
                <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">URL</th>
                <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Status</th>
                <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Tools</th>
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
    </div>
    """
  end

  defp status_color("ready"), do: "green"
  defp status_color("connected"), do: "green"
  defp status_color("error"), do: "red"
  defp status_color("disconnected"), do: "yellow"
  defp status_color(_), do: "gray"
end