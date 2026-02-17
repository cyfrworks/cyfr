defmodule PrismWeb.ExecutionDetailLive do
  use PrismWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Emissary.PubSub, "prism:execution:#{id}")
      Phoenix.PubSub.subscribe(Emissary.PubSub, "prism:executions")
    end

    {:ok,
     socket
     |> assign(:page_title, "Execution #{id}")
     |> assign(:execution_id, id)
     |> assign(:execution, nil)
     |> assign(:logs, [])
     |> assign(:loading, true)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    execution =
      case call_tool(socket, "execution/logs", %{"execution_id" => id}) do
        {:ok, result} -> result
        _ -> nil
      end

    logs =
      case execution do
        %{logs: logs} when is_list(logs) -> logs
        _ -> []
      end

    {:noreply,
     socket
     |> assign(:execution, execution)
     |> assign(:logs, logs)
     |> assign(:loading, false)}
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    case call_tool(socket, "execution/cancel", %{"execution_id" => socket.assigns.execution_id}) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Execution cancelled.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:log_line, line}, socket) do
    {:noreply, assign(socket, :logs, socket.assigns.logs ++ [line])}
  end

  def handle_info({:execution_completed, metadata, _}, socket) do
    if metadata[:execution_id] == socket.assigns.execution_id do
      execution = Map.put(socket.assigns.execution || %{}, :status, "completed")
      {:noreply, assign(socket, :execution, execution)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:execution_failed, metadata, _}, socket) do
    if metadata[:execution_id] == socket.assigns.execution_id do
      execution = Map.put(socket.assigns.execution || %{}, :status, "failed")
      {:noreply, assign(socket, :execution, execution)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <a href={~p"/executions"} class="text-sm text-gray-500 hover:text-gray-300">
            &larr; Back to Executions
          </a>
          <h2 class="text-lg font-semibold text-white mt-1">Execution {@execution_id}</h2>
        </div>
        <div :if={@execution && (@execution[:status] || @execution["status"]) == "running"}>
          <.button variant="danger" phx-click="cancel">Cancel</.button>
        </div>
      </div>

      <div :if={@loading} class="text-center text-gray-500 py-12">Loading...</div>

      <div :if={!@loading && @execution} class="space-y-6">
        <!-- Execution metadata -->
        <.card>
          <dl class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div>
              <dt class="text-xs text-gray-500 uppercase">Reference</dt>
              <dd class="text-sm text-white mt-1">
                {@execution[:reference] || @execution["reference"] || "-"}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Status</dt>
              <dd class="mt-1">
                <.status_indicator status={
                  to_string(@execution[:status] || @execution["status"] || "unknown")
                } />
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Started</dt>
              <dd class="text-sm text-white mt-1">
                {@execution[:started_at] || @execution["started_at"] || "-"}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Duration</dt>
              <dd class="text-sm text-white mt-1">
                {@execution[:duration_ms] || @execution["duration_ms"] || "-"}
              </dd>
            </div>
          </dl>
        </.card>

        <!-- Input/Output -->
        <div :if={@execution[:input] || @execution["input"]} class="space-y-4">
          <.card>
            <h3 class="text-sm font-medium text-gray-400 mb-2">Input</h3>
            <pre class="text-xs text-gray-300 bg-gray-950 rounded p-3 overflow-x-auto"><code>{inspect(@execution[:input] || @execution["input"], pretty: true)}</code></pre>
          </.card>
        </div>

        <div :if={@execution[:output] || @execution["output"]} class="space-y-4">
          <.card>
            <h3 class="text-sm font-medium text-gray-400 mb-2">Output</h3>
            <pre class="text-xs text-gray-300 bg-gray-950 rounded p-3 overflow-x-auto"><code>{inspect(@execution[:output] || @execution["output"], pretty: true)}</code></pre>
          </.card>
        </div>

        <!-- Logs -->
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-2">Logs</h3>
          <div :if={@logs == []} class="py-4">
            <.empty_state message="No logs available" />
          </div>
          <pre
            :if={@logs != []}
            id="execution-logs"
            class="text-xs text-gray-300 bg-gray-950 rounded p-3 max-h-96 overflow-y-auto font-mono"
          ><code>{Enum.join(@logs, "\n")}</code></pre>
        </.card>
      </div>

      <div :if={!@loading && !@execution}>
        <.empty_state message="Execution not found" />
      </div>
    </div>
    """
  end
end
