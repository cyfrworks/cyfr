defmodule PrismWeb.LogsLive do
  use PrismWeb, :live_view
  alias Phoenix.LiveView.JS
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Emissary.PubSub, "prism:requests")
    end

    {:ok,
     socket
     |> assign(:page_title, "Logs")
     |> assign(:logs, [])
     |> assign(:tool_filter, nil)
     |> assign(:status_filter, nil)
     |> assign(:time_filter, nil)
     |> assign(:live_mode, true)
     |> assign(:loading, true)
     |> assign(:expanded_id, nil)
     |> assign(:expanded_log, nil)
     |> assign(:expanded_executions, [])
     |> assign(:expanded_policy_logs, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tool_filter = params["tool"]
    status_filter = params["status"]
    time_filter = params["time"]

    {:noreply,
     socket
     |> assign(:tool_filter, tool_filter)
     |> assign(:status_filter, status_filter)
     |> assign(:time_filter, time_filter)
     |> fetch_logs()
     |> assign(:loading, false)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query_params =
      %{}
      |> maybe_put("tool", params["tool"])
      |> maybe_put("status", params["status"])
      |> maybe_put("time", socket.assigns.time_filter)

    {:noreply, push_patch(socket, to: ~p"/logs?#{query_params}")}
  end

  def handle_event("time_filter", %{"time" => time}, socket) do
    query_params =
      %{}
      |> maybe_put("tool", socket.assigns.tool_filter)
      |> maybe_put("status", socket.assigns.status_filter)
      |> maybe_put("time", time)

    {:noreply, push_patch(socket, to: ~p"/logs?#{query_params}")}
  end

  def handle_event("toggle_live", _params, socket) do
    {:noreply, assign(socket, :live_mode, !socket.assigns.live_mode)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_logs(socket)}
  end

  def handle_event("toggle_expand", %{"id" => id}, socket) do
    if socket.assigns.expanded_id == id do
      # Collapse
      {:noreply,
       socket
       |> assign(:expanded_id, nil)
       |> assign(:expanded_log, nil)
       |> assign(:expanded_executions, [])
       |> assign(:expanded_policy_logs, [])}
    else
      # Expand: fetch full log + correlation
      log =
        case call_tool(socket, "mcp_log", %{"action" => "get", "id" => id}) do
          {:ok, result} -> result
          _ -> nil
        end

      {executions, policy_logs} =
        case call_tool(socket, "mcp_log", %{"action" => "correlate", "request_id" => id}) do
          {:ok, result} ->
            execs = result[:executions] || result["executions"] || []
            policies = result[:policy_logs] || result["policy_logs"] || []
            {execs, policies}
          _ ->
            {[], []}
        end

      {:noreply,
       socket
       |> assign(:expanded_id, id)
       |> assign(:expanded_log, log)
       |> assign(:expanded_executions, executions)
       |> assign(:expanded_policy_logs, policy_logs)}
    end
  end

  @impl true
  def handle_info({:request, metadata, measurements}, socket) do
    if socket.assigns.live_mode do
      entry = %{
        id: metadata[:request_id] || "unknown",
        tool: metadata[:tool],
        action: metadata[:action],
        status: to_string(metadata[:status] || "pending"),
        duration_ms: measurements[:duration_ms],
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        session_id: metadata[:session_id]
      }

      if matches_filters?(entry, socket.assigns) do
        logs = [entry | socket.assigns.logs] |> Enum.take(100)
        {:noreply, assign(socket, :logs, logs)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp fetch_logs(socket) do
    assigns = socket.assigns
    args = %{"action" => "list", "limit" => 100}
    args = if assigns.tool_filter && assigns.tool_filter != "", do: Map.put(args, "tool", assigns.tool_filter), else: args
    args = if assigns.status_filter && assigns.status_filter != "", do: Map.put(args, "status", assigns.status_filter), else: args
    args = if assigns.time_filter && assigns.time_filter != "", do: Map.put(args, "since", time_filter_to_since(assigns.time_filter)), else: args

    logs =
      case call_tool(socket, "mcp_log", args) do
        {:ok, %{logs: list}} -> list
        {:ok, %{"logs" => list}} -> list
        _ -> []
      end

    socket
    |> assign(:logs, logs)
    |> assign(:expanded_id, nil)
    |> assign(:expanded_log, nil)
    |> assign(:expanded_executions, [])
    |> assign(:expanded_policy_logs, [])
  end

  defp time_filter_to_since("1h"), do: DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()
  defp time_filter_to_since("24h"), do: DateTime.utc_now() |> DateTime.add(-86_400, :second) |> DateTime.to_iso8601()
  defp time_filter_to_since("7d"), do: DateTime.utc_now() |> DateTime.add(-7 * 86_400, :second) |> DateTime.to_iso8601()
  defp time_filter_to_since(_), do: nil

  defp matches_filters?(entry, assigns) do
    tool_ok = is_nil(assigns.tool_filter) || assigns.tool_filter == "" || entry.tool == assigns.tool_filter
    status_ok = is_nil(assigns.status_filter) || assigns.status_filter == "" || entry.status == assigns.status_filter
    tool_ok && status_ok
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp log_id(log), do: log[:id] || log["id"] || "unknown"

  defp normalize_decision("allow"), do: "success"
  defp normalize_decision("deny"), do: "error"
  defp normalize_decision(other), do: other

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h2 class="text-lg font-semibold text-white">MCP Request Logs</h2>
        <div class="flex items-center gap-2">
          <button
            :if={!@live_mode}
            phx-click="refresh"
            class="px-3 py-1.5 text-xs font-medium rounded-md bg-blue-900 text-blue-300 border border-blue-700 hover:bg-blue-800"
          >
            Refresh
          </button>
          <button
            phx-click="toggle_live"
            class={"px-3 py-1.5 text-xs font-medium rounded-md #{if @live_mode, do: "bg-green-900 text-green-300 border border-green-700", else: "bg-gray-800 text-gray-400 border border-gray-700"}"}
          >
            {if @live_mode, do: "Live", else: "Paused"}
          </button>
        </div>
      </div>

      <!-- Filters -->
      <div class="flex items-center gap-3 flex-wrap">
        <form phx-change="filter" class="flex gap-3">
          <select name="tool" class="bg-gray-800 text-gray-300 text-sm rounded-md border-gray-700 px-3 py-1.5">
            <option value="" selected={is_nil(@tool_filter) || @tool_filter == ""}>All Tools</option>
            <option value="execution" selected={@tool_filter == "execution"}>execution</option>
            <option value="storage" selected={@tool_filter == "storage"}>storage</option>
            <option value="component" selected={@tool_filter == "component"}>component</option>
            <option value="session" selected={@tool_filter == "session"}>session</option>
            <option value="secret" selected={@tool_filter == "secret"}>secret</option>
            <option value="policy" selected={@tool_filter == "policy"}>policy</option>
            <option value="key" selected={@tool_filter == "key"}>key</option>
            <option value="build" selected={@tool_filter == "build"}>build</option>
            <option value="system" selected={@tool_filter == "system"}>system</option>
          </select>
          <select name="status" class="bg-gray-800 text-gray-300 text-sm rounded-md border-gray-700 px-3 py-1.5">
            <option value="" selected={is_nil(@status_filter) || @status_filter == ""}>All Statuses</option>
            <option value="pending" selected={@status_filter == "pending"}>pending</option>
            <option value="success" selected={@status_filter == "success"}>success</option>
            <option value="error" selected={@status_filter == "error"}>error</option>
          </select>
        </form>
        <div class="flex gap-1">
          <button
            :for={preset <- [{"1h", "1h"}, {"24h", "24h"}, {"7d", "7d"}, {"All", ""}]}
            phx-click="time_filter"
            phx-value-time={elem(preset, 1)}
            class={"px-2.5 py-1 text-xs font-medium rounded-md #{if (@time_filter || "") == elem(preset, 1), do: "bg-indigo-900 text-indigo-300 border border-indigo-700", else: "bg-gray-800 text-gray-400 border border-gray-700 hover:bg-gray-700"}"}
          >
            {elem(preset, 0)}
          </button>
        </div>
      </div>

      <.card>
        <div :if={@loading} class="py-8 text-center text-gray-500">Loading...</div>
        <div :if={!@loading && @logs == []} class="py-8">
          <.empty_state message="No logs found" />
        </div>
        <div :if={!@loading && @logs != []} class="overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-800 table-fixed">
            <thead>
              <tr>
                <th class="w-[30%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Request ID</th>
                <th class="w-[14%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Tool</th>
                <th class="w-[14%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Action</th>
                <th class="w-[12%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Status</th>
                <th class="w-[12%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Duration</th>
                <th class="w-[18%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Time</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-800">
              <%= for log <- @logs do %>
                <tr
                  phx-click="toggle_expand"
                  phx-value-id={log_id(log)}
                  class={"cursor-pointer transition-colors #{if @expanded_id == log_id(log), do: "bg-gray-800/80", else: "hover:bg-gray-800/50"}"}
                >
                  <td class="px-4 py-3 text-sm whitespace-nowrap">
                    <span class="text-blue-400 font-mono text-xs">{log_id(log)}</span>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-300 whitespace-nowrap">{log_field(log, :tool)}</td>
                  <td class="px-4 py-3 text-sm text-gray-300 whitespace-nowrap">{log_field(log, :action)}</td>
                  <td class="px-4 py-3 text-sm whitespace-nowrap">
                    <span class={status_badge_class(log_field(log, :status))}>{log_field(log, :status)}</span>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-300 whitespace-nowrap">{format_duration(log_field(log, :duration_ms))}</td>
                  <td class="px-4 py-3 text-sm whitespace-nowrap">
                    <span class="text-xs text-gray-400" title={log_field(log, :timestamp)}>
                      {relative_time(log_field(log, :timestamp))}
                    </span>
                  </td>
                </tr>
                <!-- Expanded detail row -->
                <tr :if={@expanded_id == log_id(log)} class="bg-gray-900/60">
                  <td colspan="6" class="px-4 py-4">
                    <div :if={@expanded_log} class="space-y-4">
                      <!-- Metadata grid -->
                      <dl class="grid grid-cols-2 md:grid-cols-3 gap-3">
                        <div>
                          <dt class="text-xs text-gray-500 uppercase">Session ID</dt>
                          <dd class="text-sm text-white mt-0.5 font-mono text-xs flex items-center gap-1">
                            {log_field(@expanded_log, :session_id)}
                            <button
                              phx-click={JS.dispatch("phx:clipboard", detail: %{text: log_field(@expanded_log, :session_id)})}
                              class="text-gray-500 hover:text-gray-300"
                              title="Copy to clipboard"
                            >
                              <.icon name="clipboard" class="h-3.5 w-3.5" />
                            </button>
                          </dd>
                        </div>
                        <div>
                          <dt class="text-xs text-gray-500 uppercase">User ID</dt>
                          <dd class="text-sm text-white mt-0.5">{log_field(@expanded_log, :user_id)}</dd>
                        </div>
                        <div>
                          <dt class="text-xs text-gray-500 uppercase">Timestamp</dt>
                          <dd class="text-sm text-white mt-0.5">{log_field(@expanded_log, :timestamp)}</dd>
                        </div>
                      </dl>

                      <!-- Input -->
                      <div :if={has_field?(@expanded_log, :input)}>
                        <div class="flex items-center justify-between mb-1">
                          <h4 class="text-xs font-medium text-gray-400">Input</h4>
                          <button
                            phx-click={JS.dispatch("phx:clipboard", detail: %{text: format_json(log_field(@expanded_log, :input))})}
                            class="text-gray-500 hover:text-gray-300"
                            title="Copy to clipboard"
                          >
                            <.icon name="clipboard" class="h-3.5 w-3.5" />
                          </button>
                        </div>
                        <pre class="text-xs text-gray-300 bg-gray-950 rounded p-3 overflow-auto max-h-48 whitespace-pre-wrap break-all"><code>{format_json(log_field(@expanded_log, :input))}</code></pre>
                      </div>

                      <!-- Output -->
                      <div :if={has_field?(@expanded_log, :output)}>
                        <div class="flex items-center justify-between mb-1">
                          <h4 class="text-xs font-medium text-gray-400">Output</h4>
                          <button
                            phx-click={JS.dispatch("phx:clipboard", detail: %{text: format_json(log_field(@expanded_log, :output))})}
                            class="text-gray-500 hover:text-gray-300"
                            title="Copy to clipboard"
                          >
                            <.icon name="clipboard" class="h-3.5 w-3.5" />
                          </button>
                        </div>
                        <pre class="text-xs text-gray-300 bg-gray-950 rounded p-3 overflow-auto max-h-48 whitespace-pre-wrap break-all"><code>{format_json(log_field(@expanded_log, :output))}</code></pre>
                      </div>

                      <!-- Error -->
                      <div :if={has_field?(@expanded_log, :error)}>
                        <h4 class="text-xs font-medium text-red-400 mb-1">Error</h4>
                        <div class="bg-red-950 rounded p-3 border border-red-900">
                          <p class="text-sm text-red-300">{log_field(@expanded_log, :error)}</p>
                          <p :if={has_field?(@expanded_log, :error_code)} class="text-xs text-red-500 mt-1">
                            Code: {log_field(@expanded_log, :error_code)}
                          </p>
                        </div>
                      </div>

                      <!-- Related Executions -->
                      <div :if={@expanded_executions != []}>
                        <h4 class="text-xs font-medium text-gray-400 mb-1">Related Executions</h4>
                        <div class="overflow-x-auto">
                          <table class="min-w-full divide-y divide-gray-800 text-xs">
                            <thead>
                              <tr>
                                <th class="px-3 py-1.5 text-left text-xs font-medium uppercase text-gray-500">Execution ID</th>
                                <th class="px-3 py-1.5 text-left text-xs font-medium uppercase text-gray-500">Reference</th>
                                <th class="px-3 py-1.5 text-left text-xs font-medium uppercase text-gray-500">Status</th>
                                <th class="px-3 py-1.5 text-left text-xs font-medium uppercase text-gray-500">Duration</th>
                              </tr>
                            </thead>
                            <tbody class="divide-y divide-gray-800">
                              <tr :for={exec <- @expanded_executions}>
                                <td class="px-3 py-1.5 font-mono text-gray-300">{log_field(exec, :id) |> to_string()}</td>
                                <td class="px-3 py-1.5 text-gray-300">{format_ref(exec[:reference] || exec["reference"])}</td>
                                <td class="px-3 py-1.5">
                                  <span class={status_badge_class(log_field(exec, :status))}>{log_field(exec, :status)}</span>
                                </td>
                                <td class="px-3 py-1.5 text-gray-300">{format_duration(log_field(exec, :duration_ms))}</td>
                              </tr>
                            </tbody>
                          </table>
                        </div>
                      </div>

                      <!-- Policy Decisions -->
                      <div :if={@expanded_policy_logs != []}>
                        <h4 class="text-xs font-medium text-gray-400 mb-1">Policy Decisions</h4>
                        <div class="overflow-x-auto">
                          <table class="min-w-full divide-y divide-gray-800 text-xs">
                            <thead>
                              <tr>
                                <th class="px-3 py-1.5 text-left text-xs font-medium uppercase text-gray-500">Component</th>
                                <th class="px-3 py-1.5 text-left text-xs font-medium uppercase text-gray-500">Decision</th>
                                <th class="px-3 py-1.5 text-left text-xs font-medium uppercase text-gray-500">Reason</th>
                              </tr>
                            </thead>
                            <tbody class="divide-y divide-gray-800">
                              <tr :for={pol <- @expanded_policy_logs}>
                                <td class="px-3 py-1.5 text-gray-300">{log_field(pol, :component_ref)}</td>
                                <td class="px-3 py-1.5">
                                  <span class={status_badge_class(normalize_decision(log_field(pol, :decision)))}>{log_field(pol, :decision)}</span>
                                </td>
                                <td class="px-3 py-1.5 text-gray-300">{log_field(pol, :decision_reason)}</td>
                              </tr>
                            </tbody>
                          </table>
                        </div>
                      </div>
                    </div>
                    <div :if={!@expanded_log} class="text-center text-gray-500 py-4 text-sm">Loading...</div>
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
end
