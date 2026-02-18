defmodule PrismWeb.DashboardLive do
  use PrismWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Emissary.PubSub, "prism:executions")
      Phoenix.PubSub.subscribe(Emissary.PubSub, "prism:system")
    end

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> assign(:system_status, nil)
      |> assign(:recent_executions, [])
      |> assign(:loading, true)

    {:ok, socket, temporary_assigns: []}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    socket =
      socket
      |> load_system_status()
      |> load_recent_executions()
      |> assign(:loading, false)

    {:noreply, socket}
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

    executions =
      Enum.map(socket.assigns.recent_executions, fn exec ->
        if exec_id(exec) == target_id,
          do: Map.put(exec, :status, "failed"),
          else: exec
      end)

    {:noreply, assign(socket, :recent_executions, executions)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_system_status(socket) do
    case call_tool(socket, "system/status", %{}) do
      {:ok, status} ->
        assign(socket, :system_status, status)

      {:error, _} ->
        assign(socket, :system_status, %{status: "unknown", services: []})
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

  defp exec_id(exec), do: exec[:execution_id] || exec[:id] || exec["execution_id"] || exec["id"]

  defp service_count(nil), do: 0
  defp service_count(services) when is_map(services), do: map_size(services)
  defp service_count(services) when is_list(services), do: length(services)
  defp service_count(_), do: 0

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <!-- System Status -->
      <section>
        <h2 class="text-lg font-semibold text-white mb-4">System Status</h2>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <.card>
            <div class="flex items-center justify-between">
              <span class="text-sm text-gray-400">Overall Health</span>
              <.status_indicator status={get_in(@system_status, [:status]) || "unknown"} />
            </div>
          </.card>
          <.card>
            <div class="flex items-center justify-between">
              <span class="text-sm text-gray-400">Services</span>
              <span class="text-2xl font-bold text-white">
                {service_count(get_in(@system_status, [:services]))}
              </span>
            </div>
          </.card>
          <.card>
            <div class="flex items-center justify-between">
              <span class="text-sm text-gray-400">Recent Executions</span>
              <span class="text-2xl font-bold text-white">{length(@recent_executions)}</span>
            </div>
          </.card>
        </div>
      </section>

      <!-- Quick Actions -->
      <section>
        <h2 class="text-lg font-semibold text-white mb-4">Quick Actions</h2>
        <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
          <a href={~p"/components"} class="block">
            <.card class="hover:border-gray-700 transition-colors">
              <div class="flex items-center gap-3">
                <.icon name="cube" class="h-8 w-8 text-blue-400" />
                <div>
                  <p class="font-medium text-white">Browse Components</p>
                  <p class="text-xs text-gray-400">Search and inspect available components</p>
                </div>
              </div>
            </.card>
          </a>
          <a href={~p"/executions"} class="block">
            <.card class="hover:border-gray-700 transition-colors">
              <div class="flex items-center gap-3">
                <.icon name="play" class="h-8 w-8 text-green-400" />
                <div>
                  <p class="font-medium text-white">Executions</p>
                  <p class="text-xs text-gray-400">View and manage running components</p>
                </div>
              </div>
            </.card>
          </a>
          <a href={~p"/policies"} class="block">
            <.card class="hover:border-gray-700 transition-colors">
              <div class="flex items-center gap-3">
                <.icon name="shield" class="h-8 w-8 text-yellow-400" />
                <div>
                  <p class="font-medium text-white">Policies</p>
                  <p class="text-xs text-gray-400">Manage execution policies</p>
                </div>
              </div>
            </.card>
          </a>
          <a href={~p"/audit"} class="block">
            <.card class="hover:border-gray-700 transition-colors">
              <div class="flex items-center gap-3">
                <.icon name="document" class="h-8 w-8 text-purple-400" />
                <div>
                  <p class="font-medium text-white">Audit Trail</p>
                  <p class="text-xs text-gray-400">View event history and audit logs</p>
                </div>
              </div>
            </.card>
          </a>
        </div>
      </section>

      <!-- Recent Executions Table -->
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
    """
  end
end
