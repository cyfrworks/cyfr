# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.McpServersLive do
  @moduledoc """
  External MCP servers registered with the athanor — list / add / delete /
  test / refresh / enable / disable / restart over the `mcp_servers` tool.
  Tools a server exposes reach AQUA as `<name>:<tool>`.

  Two ways to add one:

    * **Add stdio server** — one stdio backend (a command such as
      `npx -y @modelcontextprotocol/server-github` and its env) that the MCP
      bridge runs under a uid of its own. Env values are `vault:ENTRY`
      templates; only the non-secret names `Emissary.MCP.BackendDefinition`
      lists may hold a literal. More backends for one server go through the
      config form.
    * **Add server** — the config as JSON: an http server's `url` and
      `headers`, or a stdio server's `transport` and `backends`.

  An expanded stdio server shows what the bridge reports for each backend
  and offers Restart, which releases its backends and starts them again.
  """

  use PrismWeb, :live_view

  @placeholder_config Jason.encode!(
                        %{
                          "url" => "https://mcp.example.com/mcp",
                          "headers" => %{"Authorization" => "Bearer vault:my-connection"}
                        },
                        pretty: true
                      )

  @placeholder_env "GITHUB_PERSONAL_ACCESS_TOKEN=vault:github-token"

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe once, at mount — handle_params re-fires on every patch,
    # and PubSub's :duplicate registry would deliver every message twice.
    if connected?(socket) do
      actor = Sanctum.Context.actor(socket.assigns[:context])
      Cyfr.Bus.subscribe(actor, Cyfr.Bus.mcp_servers(actor))
    end

    socket =
      socket
      |> assign(:page_title, "MCP Servers")
      |> assign(:active_nav, "mcp_servers")
      |> assign(:servers, [])
      |> assign(:show_add, nil)
      |> assign(:loading, true)
      |> assign(:expanded_name, nil)
      |> assign(:detail, nil)
      |> assign(:form_error, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_add", %{"form" => form}, socket) when form in ["config", "stdio"] do
    show = if socket.assigns.show_add == form, do: nil, else: form
    {:noreply, socket |> assign(:show_add, show) |> assign(:form_error, nil)}
  end

  def handle_event("add_server", %{"name" => name, "config" => config_json}, socket) do
    with {:name, true} <- {:name, name != ""},
         {:json, {:ok, %{} = config}} <- {:json, Jason.decode(config_json)} do
      create(socket, name, config)
    else
      {:name, _} ->
        {:noreply, assign(socket, :form_error, "Name is required.")}

      {:json, {:error, %Jason.DecodeError{} = err}} ->
        {:noreply, assign(socket, :form_error, "Invalid JSON: #{Exception.message(err)}")}

      {:json, _} ->
        {:noreply, assign(socket, :form_error, "Config must be a JSON object.")}
    end
  end

  def handle_event("add_stdio", params, socket) do
    name = String.trim(params["name"] || "")
    backend = String.trim(params["backend"] || "")
    command = String.trim(params["command"] || "")

    with {:filled, true} <- {:filled, name != "" and backend != "" and command != ""},
         {:ok, env} <- parse_env(params["env"] || "") do
      config = %{
        "transport" => "stdio",
        "backends" => [%{"name" => backend, "command" => command, "env" => env}]
      }

      create(socket, name, config)
    else
      {:filled, false} ->
        {:noreply, assign(socket, :form_error, "Name, backend name and command are required.")}

      {:error, message} ->
        {:noreply, assign(socket, :form_error, message)}
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
        {:noreply, put_flash(socket, :error, "Failed to delete: #{error_message(reason)}")}
    end
  end

  def handle_event("toggle_enabled", %{"name" => name, "enabled" => enabled}, socket) do
    action = if enabled == "true", do: "disable", else: "enable"

    case call_tool(socket, "mcp_servers/#{action}", %{"name" => name}) do
      {:ok, _} ->
        {:noreply, refresh_servers(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{error_message(reason)}")}
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
        {:noreply, put_flash(socket, :error, "Test failed: #{error_message(reason)}")}
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
        {:noreply, put_flash(socket, :error, "Refresh failed: #{error_message(reason)}")}
    end
  end

  def handle_event("restart", %{"name" => name}, socket) do
    case call_tool(socket, "mcp_servers/restart", %{"name" => name}) do
      {:ok, result} ->
        {:noreply,
         socket
         |> refresh_servers()
         |> expand_server(name)
         |> put_flash(:info, "Restarted #{name}: #{result[:status] || "unknown"}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Restart failed: #{error_message(reason)}")}
    end
  end

  def handle_event("toggle_expand", %{"name" => name}, socket) do
    if socket.assigns.expanded_name == name do
      {:noreply,
       socket
       |> assign(:expanded_name, nil)
       |> assign(:detail, nil)}
    else
      {:noreply, expand_server(socket, name)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Paint the frame first — refresh_servers probes every server.
    if connected?(socket) do
      send(self(), :load)

      # `ui.mcp_server.focus` navigates here with `?name=`, the agent's half
      # of the act a person performs by clicking the row. Deferred behind
      # `:load` for the same reason as the list itself: the detail read
      # probes the server, and `handle_params` must not hold the paint.
      case params["name"] do
        name when is_binary(name) and name != "" -> send(self(), {:focus, name})
        _ -> :ok
      end
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:load, socket) do
    {:noreply, socket |> refresh_servers() |> assign(:loading, false)}
  end

  def handle_info({:focus, name}, socket) do
    if socket.assigns.expanded_name == name do
      {:noreply, socket}
    else
      {:noreply, expand_server(socket, name)}
    end
  end

  def handle_info(%Cyfr.Bus.McpServers{}, socket) do
    {:noreply, refresh_servers(socket)}
  end

  def handle_info(msg, socket) do
    Cyfr.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  defp create(socket, name, config) do
    case call_tool(socket, "mcp_servers/create", %{"name" => name, "config" => config}) do
      {:ok, result} ->
        {:noreply,
         socket
         |> refresh_servers()
         |> assign(:show_add, nil)
         |> assign(:form_error, nil)
         |> put_flash(:info, "Server '#{name}' added (#{result[:status] || "saved"}).")}

      {:error, reason} ->
        {:noreply, assign(socket, :form_error, "Failed to add: #{error_message(reason)}")}
    end
  end

  # One `NAME=value` per line; blank lines are skipped.
  defp parse_env(text) do
    text
    |> String.split(~r/\R/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, env} ->
      case String.split(line, "=", parts: 2) do
        [name, value] when name != "" ->
          {:cont, {:ok, Map.put(env, String.trim(name), String.trim(value))}}

        _ ->
          {:halt, {:error, "Each env line is NAME=value — #{inspect(line)} is not."}}
      end
    end)
  end

  # Open one server's detail row. Shared by the click and by the
  # `?name=` focus intent so both land in exactly the same state.
  defp expand_server(socket, name) do
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

    socket
    |> assign(:servers, servers)
    |> assign(:expanded_name, name)
    |> assign(:detail, detail)
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
    "id" => :id,
    "name" => :name,
    "transport" => :transport,
    "url" => :url,
    "epoch" => :epoch,
    "enabled" => :enabled,
    "status" => :status,
    "tool_count" => :tool_count,
    "tools" => :tools,
    "backends" => :backends,
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
      |> assign(:placeholder_env, @placeholder_env)

    ~H"""
    <div class="space-y-6">
      <.page_header title="External MCP Servers">
        <:actions>
          <.button variant="ghost" phx-click="toggle_add" phx-value-form="stdio">
            {if @show_add == "stdio", do: "Cancel", else: "Add stdio server"}
          </.button>
          <.button phx-click="toggle_add" phx-value-form="config">
            {if @show_add == "config", do: "Cancel", else: "Add server"}
          </.button>
        </:actions>
      </.page_header>

      <.card :if={@show_add == "stdio"}>
        <form phx-submit="add_stdio" class="space-y-4">
          <p class="text-xs text-gray-500">
            A stdio MCP server (for example an <code class="text-gray-400">npx</code>
            package) that the MCP bridge runs under a user of its own. Its tools
            appear as <span class="font-mono">&lt;name&gt;:&lt;backend&gt;__&lt;tool&gt;</span>.
          </p>
          <div class="grid gap-3 md:grid-cols-2">
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Name</label>
              <.input name="name" required placeholder="github" class="font-mono" />
            </div>
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Backend name</label>
              <.input name="backend" required placeholder="github" class="font-mono" />
            </div>
          </div>
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">Command</label>
            <.input
              name="command"
              required
              placeholder="npx -y @modelcontextprotocol/server-github"
              class="font-mono"
            />
          </div>
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">
              Env (NAME=value per line)
            </label>
            <.textarea name="env" rows="3" placeholder={@placeholder_env} class="font-mono" />
            <p class="text-xs text-gray-600 mt-1">
              A value is <code class="text-gray-500">vault:ENTRY</code>
              (a single-field entry on the Vault page); only NODE_ENV, LOG_LEVEL, TZ, LANG,
              LC_ALL, NO_COLOR and DEBUG may hold a literal. A command never names a vault entry.
            </p>
          </div>
          <div :if={@form_error} class="text-sm text-red-400">{@form_error}</div>
          <.button type="submit">Add stdio server</.button>
        </form>
      </.card>

      <.card :if={@show_add == "config"}>
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
              Use <code class="text-gray-500">vault:ENTRY</code>
              or <code class="text-gray-500">Bearer vault:ENTRY</code>
              in header values to reference a stored vault entry
              (create one on the Vault page). A stdio server's config is <code class="text-gray-500">{"{\"transport\": \"stdio\", \"backends\": [...]}"}</code>.
            </p>
          </div>
          <div :if={@form_error} class="text-sm text-red-400">{@form_error}</div>
          <.button type="submit">Add server</.button>
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
                  Endpoint
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
                      {endpoint(server)}
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
                      <div :if={@detail && (@detail[:backends] || []) != []} class="space-y-2">
                        <h4 class="text-sm font-medium text-gray-400 mb-2">Backends</h4>
                        <div
                          :for={backend <- @detail[:backends] || []}
                          class="flex items-baseline gap-2 text-sm px-2 py-1 rounded bg-gray-800/50"
                        >
                          <span class="font-mono text-blue-400">{backend["name"]}</span>
                          <.badge color={status_color(backend["status"])}>
                            {backend["status"] || "unknown"}
                          </.badge>
                          <span class="text-gray-500 text-xs">
                            {backend["tools"] || 0} tools · {backend["restarts"] || 0} restarts
                          </span>
                          <span :if={backend["error"]} class="text-xs text-red-400 truncate">
                            {backend["error"]}
                          </span>
                        </div>
                      </div>
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
                          :if={server[:transport] == "stdio"}
                          variant="ghost"
                          phx-click="restart"
                          phx-value-name={server[:name]}
                        >
                          Restart
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

  defp endpoint(%{transport: "stdio"}), do: "stdio (MCP bridge)"
  defp endpoint(server), do: server[:url]

  defp status_color("ready"), do: "green"
  defp status_color("connected"), do: "green"
  defp status_color("running"), do: "green"
  defp status_color("error"), do: "red"
  defp status_color("crashed"), do: "red"
  defp status_color("failed"), do: "red"
  defp status_color("disconnected"), do: "yellow"
  defp status_color("connecting"), do: "yellow"
  defp status_color("starting"), do: "yellow"
  defp status_color("spawning"), do: "yellow"
  defp status_color("initializing"), do: "yellow"
  defp status_color(_), do: "gray"
end
