defmodule PrismWeb.DashboardLive do
  use PrismWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Emissary.PubSub, "prism:executions")
      Phoenix.PubSub.subscribe(Emissary.PubSub, "prism:system")
      Phoenix.PubSub.subscribe(Emissary.PubSub, "prism:requests")
    end

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> assign(:system_status, nil)
      |> assign(:recent_executions, [])
      |> assign(:log_stats, %{total: 0, errors: 0, avg_duration_ms: 0, error_rate: 0.0})
      |> assign(:loading, true)

    {:ok, socket, temporary_assigns: []}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if connected?(socket) do
      socket =
        socket
        |> load_system_status()
        |> load_recent_executions()
        |> load_log_stats()
        |> assign(:loading, false)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:execution_started, metadata, _measurements}, socket) do
    execution = %{
      execution_id: metadata[:execution_id] || "unknown",
      reference: metadata[:component] || metadata[:reference] || "unknown",
      status: "running",
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    executions = [execution | Enum.take(socket.assigns.recent_executions, 9)]
    {:noreply, assign(socket, :recent_executions, executions)}
  end

  def handle_info({:execution_completed, metadata, _measurements}, socket) do
    target_id = metadata[:execution_id]

    executions =
      Enum.map(socket.assigns.recent_executions, fn exec ->
        if exec_id(exec) == target_id,
          do: Map.put(exec, :status, "completed"),
          else: exec
      end)

    {:noreply, assign(socket, :recent_executions, executions)}
  end

  def handle_info({:execution_failed, metadata, _measurements}, socket) do
    target_id = metadata[:execution_id]
    status = if metadata[:status] == :cancelled, do: "cancelled", else: "failed"

    executions =
      Enum.map(socket.assigns.recent_executions, fn exec ->
        if exec_id(exec) == target_id,
          do: Map.put(exec, :status, status),
          else: exec
      end)

    {:noreply, assign(socket, :recent_executions, executions)}
  end

  def handle_info({:request, _metadata, _measurements}, socket) do
    {:noreply, load_log_stats(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_system_status(socket) do
    case call_tool(socket, "system/status", %{}) do
      {:ok, status} ->
        assign(socket, :system_status, status)

      {:error, _} ->
        assign(socket, :system_status, %{status: "unknown", services: %{}})
    end
  end

  defp load_recent_executions(socket) do
    case call_tool(socket, "execution/list", %{"limit" => 10}) do
      {:ok, %{executions: executions}} ->
        assign(socket, :recent_executions, executions)

      {:ok, executions} when is_list(executions) ->
        assign(socket, :recent_executions, executions)

      {:error, _} ->
        assign(socket, :recent_executions, [])
    end
  end

  defp load_log_stats(socket) do
    case call_tool(socket, "mcp_log", %{"action" => "stats"}) do
      {:ok, stats} ->
        assign(socket, :log_stats, %{
          total: stats[:total] || stats["total"] || 0,
          errors: stats[:errors] || stats["errors"] || 0,
          avg_duration_ms: stats[:avg_duration_ms] || stats["avg_duration_ms"] || 0,
          error_rate: stats[:error_rate] || stats["error_rate"] || 0.0
        })

      _ ->
        socket
    end
  end

  defp exec_id(exec), do: exec[:execution_id] || exec[:id] || exec["execution_id"] || exec["id"]

  defp status_field(nil, _key), do: nil
  defp status_field(status, key), do: status[key] || status[to_string(key)]

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
    services = services_map(status_field(assigns.system_status, :services))
    mcp = status_field(assigns.system_status, :mcp) || %{}

    assigns =
      assigns
      |> assign(:services, services)
      |> assign(:mcp, mcp)

    ~H"""
    <div class="space-y-8">
      <div :if={@loading} class="text-center text-gray-500 py-12">Loading...</div>

      <div :if={!@loading} class="space-y-8">
        <!-- System Status -->
        <section>
          <h2 class="text-lg font-semibold text-white mb-4">System Status</h2>
          <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
            <.card>
              <dt class="text-xs text-gray-500 uppercase">Services</dt>
              <dd class="mt-2 flex flex-wrap gap-x-3 gap-y-1">
                <%= for {name, status} <- Enum.sort(@services) do %>
                  <span class="flex items-center gap-1">
                    <span class={["h-2 w-2 rounded-full", service_dot(to_string(status))]} />
                    <span class="text-sm text-gray-300">{name}</span>
                  </span>
                <% end %>
              </dd>
            </.card>
            <.card>
              <dt class="text-xs text-gray-500 uppercase">Version</dt>
              <dd class="text-2xl font-bold text-white mt-2">
                {status_field(@system_status, :version) || "-"}
              </dd>
            </.card>
            <.card>
              <dt class="text-xs text-gray-500 uppercase">Uptime</dt>
              <dd class="text-2xl font-bold text-white mt-2">
                {format_uptime(status_field(@system_status, :uptime_seconds))}
              </dd>
            </.card>
            <.card>
              <dt class="text-xs text-gray-500 uppercase">MCP Protocol</dt>
              <dd class="text-sm text-white mt-2 font-mono">
                {status_field(@mcp, :protocol_version) || "-"}
              </dd>
              <dd class="text-xs text-gray-500 mt-1">
                {status_field(@mcp, :tools_count) || 0} tools, {status_field(@mcp, :resources_count) || 0} resources
              </dd>
            </.card>
          </div>
        </section>

        <!-- Request Metrics (1h) -->
        <section>
          <h2 class="text-lg font-semibold text-white mb-4">Request Metrics (1h)</h2>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
            <.card>
              <dt class="text-xs text-gray-500 uppercase">Total Requests</dt>
              <dd class="text-2xl font-bold text-white mt-2">{@log_stats.total}</dd>
            </.card>
            <.card>
              <dt class="text-xs text-gray-500 uppercase">Error Rate</dt>
              <dd class={"text-2xl font-bold mt-2 #{if @log_stats.error_rate > 0, do: "text-red-400", else: "text-green-400"}"}>
                {@log_stats.error_rate}%
              </dd>
            </.card>
            <.card>
              <dt class="text-xs text-gray-500 uppercase">Avg Duration</dt>
              <dd class="text-2xl font-bold text-white mt-2">{@log_stats.avg_duration_ms}ms</dd>
            </.card>
          </div>
        </section>

        <!-- Recent Executions -->
        <section>
          <h2 class="text-lg font-semibold text-white mb-4">Recent Executions</h2>
          <.card>
            <div :if={@recent_executions == []} class="py-8">
              <.empty_state message="No recent executions" />
            </div>
            <.table :if={@recent_executions != []} id="recent-executions" rows={@recent_executions}>
              <:col :let={exec} label="ID">{exec[:execution_id] || exec[:id] || exec["execution_id"] || exec["id"] || "-"}</:col>
              <:col :let={exec} label="Reference">{format_ref(exec[:reference] || exec["reference"])}</:col>
              <:col :let={exec} label="Status">
                <.status_indicator status={to_string(exec[:status] || exec["status"] || "unknown")} />
              </:col>
              <:col :let={exec} label="Started">
                {exec[:started_at] || exec["started_at"] || exec[:inserted_at] || "-"}
              </:col>
            </.table>
          </.card>
        </section>
      </div>
    </div>
    """
  end
end
