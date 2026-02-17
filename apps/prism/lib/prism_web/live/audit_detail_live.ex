defmodule PrismWeb.AuditDetailLive do
  use PrismWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Audit Event #{id}")
     |> assign(:event_id, id)
     |> assign(:event, nil)
     |> assign(:loading, true)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    event =
      case call_tool(socket, "audit/show", %{"execution_id" => id}) do
        {:ok, event} -> event
        _ -> nil
      end

    {:noreply,
     socket
     |> assign(:event, event)
     |> assign(:loading, false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <a href={~p"/audit"} class="text-sm text-gray-500 hover:text-gray-300">
          &larr; Back to Audit Trail
        </a>
        <h2 class="text-lg font-semibold text-white mt-1">Audit Event {@event_id}</h2>
      </div>

      <div :if={@loading} class="text-center text-gray-500 py-12">Loading...</div>

      <div :if={!@loading && @event} class="space-y-6">
        <.card>
          <dl class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div>
              <dt class="text-xs text-gray-500 uppercase">Event Type</dt>
              <dd class="text-sm text-white mt-1">
                {@event[:event_type] || @event["event_type"] || "-"}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Action</dt>
              <dd class="text-sm text-white mt-1">
                {@event[:action] || @event["action"] || "-"}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">User</dt>
              <dd class="text-sm text-white mt-1">
                {@event[:user_id] || @event["user_id"] || "-"}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Timestamp</dt>
              <dd class="text-sm text-white mt-1">
                {@event[:timestamp] || @event["timestamp"] || "-"}
              </dd>
            </div>
          </dl>
        </.card>

        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-2">Full Event Data</h3>
          <pre class="text-xs text-gray-300 bg-gray-950 rounded p-3 overflow-x-auto"><code>{Jason.encode!(@event, pretty: true)}</code></pre>
        </.card>
      </div>

      <div :if={!@loading && !@event}>
        <.empty_state message="Audit event not found" />
      </div>
    </div>
    """
  end
end
