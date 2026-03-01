defmodule PrismWeb.ExecutionsLive do
  use PrismWeb, :live_view
  alias Phoenix.LiveView.JS

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Emissary.PubSub, "prism:executions")
    end

    {:ok,
     socket
     |> assign(:page_title, "Executions")
     |> assign(:executions, [])
     |> assign(:status_filter, nil)
     |> assign(:loading, true)
     |> assign(:live_mode, true)
     |> assign(:expanded_id, nil)
     |> assign(:expanded_detail, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if connected?(socket) do
      {:noreply,
       socket
       |> assign(:status_filter, params["status"])
       |> fetch_executions()
       |> assign(:loading, false)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    params = if status == "", do: %{}, else: %{"status" => status}
    {:noreply, push_patch(socket, to: ~p"/executions?#{params}")}
  end

  def handle_event("toggle_live", _params, socket) do
    {:noreply, assign(socket, :live_mode, !socket.assigns.live_mode)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_executions(socket)}
  end

  def handle_event("toggle_expand", %{"id" => id}, socket) do
    if socket.assigns.expanded_id == id do
      {:noreply,
       socket
       |> assign(:expanded_id, nil)
       |> assign(:expanded_detail, nil)}
    else
      detail =
        case call_tool(socket, "execution", %{"action" => "logs", "execution_id" => id}) do
          {:ok, result} -> result
          _ -> nil
        end

      {:noreply,
       socket
       |> assign(:expanded_id, id)
       |> assign(:expanded_detail, detail)}
    end
  end

  @impl true
  def handle_info({:execution_started, metadata, _measurements}, socket) do
    if socket.assigns.live_mode do
      entry = %{
        execution_id: metadata[:execution_id] || "unknown",
        request_id: metadata[:request_id],
        reference: metadata[:component] || metadata[:reference] || "unknown",
        component_type: metadata[:component_type] && to_string(metadata[:component_type]),
        status: "running",
        started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        duration_ms: nil,
        error: nil
      }

      if matches_status?(entry, socket.assigns.status_filter) do
        executions = [entry | socket.assigns.executions] |> Enum.take(100)
        {:noreply, assign(socket, :executions, executions)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:execution_completed, metadata, _measurements}, socket) do
    target_id = metadata[:execution_id]

    executions =
      Enum.map(socket.assigns.executions, fn exec ->
        if f(exec, :execution_id) == target_id do
          exec
          |> Map.put(:status, "completed")
          |> Map.put(:duration_ms, metadata[:duration_ms])
          |> then(fn e -> if metadata[:request_id], do: Map.put(e, :request_id, metadata[:request_id]), else: e end)
          |> then(fn e -> if metadata[:component_type], do: Map.put(e, :component_type, to_string(metadata[:component_type])), else: e end)
        else
          exec
        end
      end)

    {:noreply, assign(socket, :executions, executions)}
  end

  def handle_info({:execution_failed, metadata, _measurements}, socket) do
    target_id = metadata[:execution_id]

    executions =
      Enum.map(socket.assigns.executions, fn exec ->
        if f(exec, :execution_id) == target_id do
          exec
          |> Map.put(:status, "failed")
          |> Map.put(:duration_ms, metadata[:duration_ms])
          |> Map.put(:error, metadata[:error])
          |> then(fn e -> if metadata[:request_id], do: Map.put(e, :request_id, metadata[:request_id]), else: e end)
          |> then(fn e -> if metadata[:component_type], do: Map.put(e, :component_type, to_string(metadata[:component_type])), else: e end)
        else
          exec
        end
      end)

    {:noreply, assign(socket, :executions, executions)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp fetch_executions(socket) do
    args = %{"action" => "list", "limit" => 100}
    args = if socket.assigns.status_filter && socket.assigns.status_filter != "",
      do: Map.put(args, "status", socket.assigns.status_filter),
      else: args

    executions =
      case call_tool(socket, "execution", args) do
        {:ok, %{executions: list}} -> list
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    socket
    |> assign(:executions, executions)
    |> assign(:expanded_id, nil)
    |> assign(:expanded_detail, nil)
  end

  defp matches_status?(_entry, nil), do: true
  defp matches_status?(_entry, ""), do: true
  defp matches_status?(entry, filter), do: f(entry, :status) == filter

  defp f(m, k), do: m[k] || m[to_string(k)]

  defp type_color("catalyst"), do: "bg-gray-800/80 text-purple-400/80"
  defp type_color("reagent"), do: "bg-gray-800/80 text-blue-400/80"
  defp type_color("formula"), do: "bg-gray-800/80 text-emerald-400/80"
  defp type_color(_), do: "bg-gray-800/80 text-gray-500"

  defp truncate_digest(nil), do: "-"
  defp truncate_digest(d) when byte_size(d) > 16, do: String.slice(d, 0, 16) <> "..."
  defp truncate_digest(d), do: d

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h2 class="text-lg font-semibold text-white">Executions</h2>
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

      <!-- Status filter pills -->
      <div class="flex items-center gap-2">
        <button
          :for={{label, value, active_class} <- [
            {"All", "", "bg-gray-700 text-white"},
            {"Running", "running", "bg-blue-900 text-blue-300"},
            {"Completed", "completed", "bg-green-900 text-green-300"},
            {"Failed", "failed", "bg-red-900 text-red-300"},
            {"Cancelled", "cancelled", "bg-yellow-900 text-yellow-300"}
          ]}
          phx-click="filter_status"
          phx-value-status={value}
          class={"px-3 py-1.5 rounded-full text-sm font-medium transition-colors #{if (@status_filter || "") == value, do: active_class, else: "bg-gray-800 text-gray-400 hover:text-gray-300"}"}
        >
          {label}
        </button>
      </div>

      <.card>
        <div :if={@loading} class="py-8 text-center text-gray-500">Loading...</div>
        <div :if={!@loading && @executions == []} class="py-8">
          <.empty_state message="No executions found" />
        </div>
        <div :if={!@loading && @executions != []} class="overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-800 table-fixed">
            <thead>
              <tr>
                <th class="w-[26%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Request ID</th>
                <th class="w-[24%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Reference</th>
                <th class="w-[10%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Type</th>
                <th class="w-[12%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Status</th>
                <th class="w-[12%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Duration</th>
                <th class="w-[16%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Started</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-800">
              <%= for exec <- @executions do %>
                <% eid = f(exec, :execution_id) || f(exec, :id) || "-" %>
                <tr
                  phx-click="toggle_expand"
                  phx-value-id={eid}
                  class={"cursor-pointer transition-colors #{if @expanded_id == eid, do: "bg-gray-800/80", else: "hover:bg-gray-800/50"}"}
                >
                  <td class="px-4 py-3 text-sm whitespace-nowrap">
                    <span class="text-blue-400 font-mono text-xs">{f(exec, :request_id) || "-"}</span>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-300 truncate max-w-0">
                    {format_ref(f(exec, :reference))}
                  </td>
                  <td class="px-4 py-3 text-sm whitespace-nowrap">
                    <span :if={f(exec, :component_type)} class={"inline-flex items-center px-2 py-0.5 rounded text-xs font-medium #{type_color(f(exec, :component_type))}"}>
                      {f(exec, :component_type)}
                    </span>
                  </td>
                  <td class="px-4 py-3 text-sm whitespace-nowrap">
                    <.status_indicator status={to_string(f(exec, :status) || "unknown")} />
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-300 whitespace-nowrap">
                    {format_duration(f(exec, :duration_ms))}
                  </td>
                  <td class="px-4 py-3 text-sm whitespace-nowrap">
                    <span class="text-xs text-gray-400" title={f(exec, :started_at)}>
                      {relative_time(f(exec, :started_at))}
                    </span>
                  </td>
                </tr>
                <!-- Expanded detail -->
                <tr :if={@expanded_id == eid} class="bg-gray-900/60">
                  <td colspan="6" class="px-4 py-4">
                    <div :if={@expanded_detail} class="space-y-4">
                      <!-- Metadata -->
                      <dl class="grid grid-cols-2 md:grid-cols-4 gap-3">
                        <div>
                          <dt class="text-xs text-gray-500 uppercase">Execution ID</dt>
                          <dd class="text-sm text-white mt-0.5 font-mono text-xs flex items-center gap-1">
                            {f(@expanded_detail, :execution_id) || eid}
                            <button
                              phx-click={JS.dispatch("phx:clipboard", detail: %{text: f(@expanded_detail, :execution_id) || eid})}
                              class="text-gray-500 hover:text-gray-300"
                              title="Copy to clipboard"
                            >
                              <.icon name="clipboard" class="h-3.5 w-3.5" />
                            </button>
                          </dd>
                        </div>
                        <div>
                          <dt class="text-xs text-gray-500 uppercase">Timestamp</dt>
                          <dd class="text-sm text-white mt-0.5">{f(@expanded_detail, :started_at) || "-"}</dd>
                        </div>
                        <div>
                          <dt class="text-xs text-gray-500 uppercase">User</dt>
                          <dd class="text-sm text-white mt-0.5">{f(@expanded_detail, :user_id) || "-"}</dd>
                        </div>
                        <div>
                          <dt class="text-xs text-gray-500 uppercase">Digest</dt>
                          <dd class="text-sm text-white mt-0.5 font-mono text-xs" title={f(@expanded_detail, :component_digest)}>
                            {truncate_digest(f(@expanded_detail, :component_digest))}
                          </dd>
                        </div>
                        <div>
                          <dt class="text-xs text-gray-500 uppercase">Completed</dt>
                          <dd class="text-sm text-white mt-0.5">{f(@expanded_detail, :completed_at) || "-"}</dd>
                        </div>
                      </dl>

                      <!-- Input -->
                      <div :if={f(@expanded_detail, :input) && f(@expanded_detail, :input) != %{}}>
                        <div class="flex items-center justify-between mb-1">
                          <h4 class="text-xs font-medium text-gray-400">Input</h4>
                          <button
                            phx-click={JS.dispatch("phx:clipboard", detail: %{text: format_json(f(@expanded_detail, :input))})}
                            class="text-gray-500 hover:text-gray-300"
                            title="Copy to clipboard"
                          >
                            <.icon name="clipboard" class="h-3.5 w-3.5" />
                          </button>
                        </div>
                        <pre class="text-xs text-gray-300 bg-gray-950 rounded p-3 overflow-auto max-h-48 whitespace-pre-wrap break-all"><code>{format_json(f(@expanded_detail, :input))}</code></pre>
                      </div>

                      <!-- Output -->
                      <div :if={f(@expanded_detail, :output) && f(@expanded_detail, :output) != %{}}>
                        <div class="flex items-center justify-between mb-1">
                          <h4 class="text-xs font-medium text-gray-400">Output</h4>
                          <button
                            phx-click={JS.dispatch("phx:clipboard", detail: %{text: format_json(f(@expanded_detail, :output))})}
                            class="text-gray-500 hover:text-gray-300"
                            title="Copy to clipboard"
                          >
                            <.icon name="clipboard" class="h-3.5 w-3.5" />
                          </button>
                        </div>
                        <pre class="text-xs text-gray-300 bg-gray-950 rounded p-3 overflow-auto max-h-48 whitespace-pre-wrap break-all"><code>{format_json(f(@expanded_detail, :output))}</code></pre>
                      </div>

                      <!-- Error -->
                      <div :if={f(@expanded_detail, :error)}>
                        <h4 class="text-xs font-medium text-red-400 mb-1">Error</h4>
                        <div class="bg-red-950 rounded p-3 border border-red-900">
                          <p class="text-sm text-red-300">{f(@expanded_detail, :error)}</p>
                        </div>
                      </div>
                    </div>
                    <div :if={!@expanded_detail} class="text-center text-gray-500 py-4 text-sm">Loading...</div>
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
