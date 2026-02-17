defmodule PrismWeb.ExecutionsLive do
  use PrismWeb, :live_view
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Emissary.PubSub, "prism:executions")
    end

    {:ok,
     socket
     |> assign(:page_title, "Executions")
     |> assign(:executions, [])
     |> assign(:loading, true)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    executions =
      case call_tool(socket, "execution/list", %{}) do
        {:ok, %{executions: list}} -> list
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    {:noreply,
     socket
     |> assign(:executions, executions)
     |> assign(:loading, false)}
  end

  @impl true
  def handle_info({:execution_started, metadata, _}, socket) do
    Logger.debug("[ExecutionsLive] execution_started: #{inspect(metadata[:execution_id])}")

    execution = %{
      execution_id: metadata[:execution_id] || "unknown",
      reference: metadata[:reference] || metadata[:component] || "unknown",
      status: "running",
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:noreply, assign(socket, :executions, [execution | socket.assigns.executions])}
  end

  def handle_info({:execution_completed, metadata, measurements}, socket) do
    target_id = metadata[:execution_id]
    matched = Enum.any?(socket.assigns.executions, fn exec -> exec_id(exec) == target_id end)
    Logger.debug("[ExecutionsLive] execution_completed: target=#{inspect(target_id)} matched=#{inspect(matched)}")
    duration_ms = div(measurements[:duration] || 0, 1_000_000)

    executions =
      if matched do
        Enum.map(socket.assigns.executions, fn exec ->
          if exec_id(exec) == target_id,
            do: Map.merge(exec, %{status: "completed", duration_ms: duration_ms}),
            else: exec
        end)
      else
        [build_execution(metadata, "completed", duration_ms) | socket.assigns.executions]
      end

    {:noreply, assign(socket, :executions, executions)}
  end

  def handle_info({:execution_failed, metadata, measurements}, socket) do
    target_id = metadata[:execution_id]
    matched = Enum.any?(socket.assigns.executions, fn exec -> exec_id(exec) == target_id end)
    Logger.debug("[ExecutionsLive] execution_failed: target=#{inspect(target_id)} matched=#{inspect(matched)}")
    duration_ms = div(measurements[:duration] || 0, 1_000_000)

    executions =
      if matched do
        Enum.map(socket.assigns.executions, fn exec ->
          if exec_id(exec) == target_id,
            do: Map.merge(exec, %{status: "failed", duration_ms: duration_ms}),
            else: exec
        end)
      else
        [build_execution(metadata, "failed", duration_ms) | socket.assigns.executions]
      end

    {:noreply, assign(socket, :executions, executions)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[ExecutionsLive] unhandled message: #{inspect(elem(msg, 0), limit: 1)}")
    {:noreply, socket}
  end

  defp exec_id(exec), do: exec[:execution_id] || exec[:id] || exec["execution_id"] || exec["id"]

  defp build_execution(metadata, status, duration_ms \\ nil) do
    %{
      execution_id: metadata[:execution_id] || "unknown",
      reference: metadata[:reference] || metadata[:component] || "unknown",
      status: status,
      started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      duration_ms: duration_ms,
      error: metadata[:error]
    }
  end

  defp format_ref(nil), do: "-"
  defp format_ref(ref) when is_binary(ref), do: ref
  defp format_ref(ref) when is_map(ref), do: ref[:registry] || ref["registry"] || inspect(ref)
  defp format_ref(ref), do: inspect(ref)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h2 class="text-lg font-semibold text-white">Executions</h2>
      </div>

      <.card>
        <div :if={@loading} class="py-8 text-center text-gray-500">Loading...</div>
        <div :if={!@loading && @executions == []} class="py-8">
          <.empty_state message="No executions found" />
        </div>
        <.table :if={!@loading && @executions != []} id="executions" rows={@executions}>
          <:col :let={exec} label="ID">
            <a
              href={~p"/executions/#{exec[:execution_id] || exec[:id] || exec["execution_id"] || exec["id"] || "unknown"}"}
              class="text-blue-400 hover:text-blue-300"
            >
              {exec[:execution_id] || exec[:id] || exec["execution_id"] || exec["id"] || "-"}
            </a>
          </:col>
          <:col :let={exec} label="Reference">{format_ref(exec[:reference] || exec["reference"])}</:col>
          <:col :let={exec} label="Status">
            <.status_indicator status={to_string(exec[:status] || exec["status"] || "unknown")} />
          </:col>
          <:col :let={exec} label="Started">
            {exec[:started_at] || exec["started_at"] || exec[:inserted_at] || "-"}
          </:col>
          <:col :let={exec} label="Duration">
            {exec[:duration_ms] || exec["duration_ms"] || "-"}
          </:col>
        </.table>
      </.card>
    </div>
    """
  end
end
