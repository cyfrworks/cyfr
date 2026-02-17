defmodule PrismWeb.AuditLive do
  use PrismWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Audit Trail")
     |> assign(:events, [])
     |> assign(:event_type, nil)
     |> assign(:date_from, nil)
     |> assign(:date_to, nil)
     |> assign(:loading, true)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    args = build_filter_args(params)

    events =
      case call_tool(socket, "audit/list", args) do
        {:ok, %{events: list}} -> list
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    {:noreply,
     socket
     |> assign(:events, events)
     |> assign(:event_type, params["type"])
     |> assign(:date_from, params["from"])
     |> assign(:date_to, params["to"])
     |> assign(:loading, false)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query_params =
      %{}
      |> maybe_put_param("type", params["type"])
      |> maybe_put_param("from", params["from"])
      |> maybe_put_param("to", params["to"])

    {:noreply, push_patch(socket, to: ~p"/audit?#{query_params}")}
  end

  def handle_event("export", %{"format" => format}, socket) do
    args =
      build_filter_args(%{
        "type" => socket.assigns.event_type,
        "from" => socket.assigns.date_from,
        "to" => socket.assigns.date_to
      })
      |> Map.put("format", format)

    case call_tool(socket, "audit/export", args) do
      {:ok, _result} ->
        {:noreply, put_flash(socket, :info, "Export started. Check downloads.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Export failed: #{inspect(reason)}")}
    end
  end

  defp build_filter_args(params) do
    %{}
    |> maybe_put_arg("event_type", params["type"])
    |> maybe_put_arg("date_from", params["from"])
    |> maybe_put_arg("date_to", params["to"])
  end

  defp maybe_put_arg(args, _key, nil), do: args
  defp maybe_put_arg(args, _key, ""), do: args
  defp maybe_put_arg(args, key, value), do: Map.put(args, key, value)

  defp maybe_put_param(params, _key, nil), do: params
  defp maybe_put_param(params, _key, ""), do: params
  defp maybe_put_param(params, key, value), do: Map.put(params, key, value)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h2 class="text-lg font-semibold text-white">Audit Trail</h2>
        <div class="flex gap-2">
          <.button variant="secondary" phx-click="export" phx-value-format="json">
            Export JSON
          </.button>
          <.button variant="secondary" phx-click="export" phx-value-format="csv">
            Export CSV
          </.button>
        </div>
      </div>

      <!-- Filters -->
      <.card>
        <form phx-change="filter" phx-submit="filter" class="flex gap-4 items-end">
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">Event Type</label>
            <select
              name="type"
              class="rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
            >
              <option value="">All Types</option>
              <option value="auth" selected={@event_type == "auth"}>Authentication</option>
              <option value="execution" selected={@event_type == "execution"}>Execution</option>
              <option value="policy" selected={@event_type == "policy"}>Policy</option>
              <option value="secret" selected={@event_type == "secret"}>Secret</option>
              <option value="key" selected={@event_type == "key"}>API Key</option>
              <option value="config" selected={@event_type == "config"}>Configuration</option>
            </select>
          </div>
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">From</label>
            <input
              type="date"
              name="from"
              value={@date_from}
              class="rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
            />
          </div>
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">To</label>
            <input
              type="date"
              name="to"
              value={@date_to}
              class="rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
            />
          </div>
        </form>
      </.card>

      <!-- Events -->
      <.card>
        <div :if={@loading} class="py-8 text-center text-gray-500">Loading...</div>
        <div :if={!@loading && @events == []} class="py-8">
          <.empty_state message="No audit events found" />
        </div>
        <.table :if={!@loading && @events != []} id="audit-events" rows={@events}>
          <:col :let={event} label="ID">
            <a
              href={~p"/audit/#{event[:id] || event["id"] || "unknown"}"}
              class="text-blue-400 hover:text-blue-300"
            >
              {event[:id] || event["id"] || "-"}
            </a>
          </:col>
          <:col :let={event} label="Type">
            <.badge color={audit_type_color(event[:event_type] || event["event_type"])}>
              {event[:event_type] || event["event_type"] || "-"}
            </.badge>
          </:col>
          <:col :let={event} label="Action">{event[:action] || event["action"] || "-"}</:col>
          <:col :let={event} label="User">{event[:user_id] || event["user_id"] || "-"}</:col>
          <:col :let={event} label="Timestamp">
            {event[:timestamp] || event["timestamp"] || event[:inserted_at] || "-"}
          </:col>
        </.table>
      </.card>
    </div>
    """
  end

  defp audit_type_color("auth"), do: "blue"
  defp audit_type_color("execution"), do: "green"
  defp audit_type_color("policy"), do: "yellow"
  defp audit_type_color("secret"), do: "red"
  defp audit_type_color("key"), do: "red"
  defp audit_type_color(_), do: "gray"
end
