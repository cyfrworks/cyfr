defmodule PrismWeb.LogDetailLive do
  use PrismWeb, :live_view
  alias Phoenix.LiveView.JS

  require Logger

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Log #{id}")
     |> assign(:log_id, id)
     |> assign(:log, nil)
     |> assign(:executions, [])
     |> assign(:policy_logs, [])
     |> assign(:loading, true)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    log =
      case call_tool(socket, "mcp_log", %{"action" => "get", "id" => id}) do
        {:ok, result} ->
          result

        other ->
          Logger.warning("[LogDetailLive] mcp_log get failed: #{inspect(other)}")
          nil
      end

    {executions, policy_logs} =
      case call_tool(socket, "mcp_log", %{"action" => "correlate", "request_id" => id}) do
        {:ok, result} ->
          execs = result[:executions] || result["executions"] || []
          policies = result[:policy_logs] || result["policy_logs"] || []
          {execs, policies}

        other ->
          Logger.warning("[LogDetailLive] mcp_log correlate failed: #{inspect(other)}")
          {[], []}
      end

    {:noreply,
     socket
     |> assign(:log, log)
     |> assign(:executions, executions)
     |> assign(:policy_logs, policy_logs)
     |> assign(:loading, false)}
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[LogDetailLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <a href={~p"/logs"} class="text-sm text-gray-500 hover:text-gray-300">
          &larr; Back to Logs
        </a>
        <h2 class="text-lg font-semibold text-white mt-1">Request {@log_id}</h2>
      </div>

      <div :if={@loading} class="text-center text-gray-500 py-12">Loading...</div>

      <div :if={!@loading && @log} class="space-y-6">
        <!-- Metadata -->
        <.card>
          <dl class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div>
              <dt class="text-xs text-gray-500 uppercase">Request ID</dt>
              <dd class="text-sm text-white mt-1 font-mono flex items-center gap-1">
                {log_field(@log, :id)}
                <button
                  phx-click={JS.dispatch("phx:clipboard", detail: %{text: log_field(@log, :id)})}
                  class="text-gray-500 hover:text-gray-300 ml-1"
                  title="Copy to clipboard"
                >
                  <.icon name="clipboard" class="h-3.5 w-3.5" />
                </button>
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Tool</dt>
              <dd class="text-sm text-white mt-1">{log_field(@log, :tool)}</dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Action</dt>
              <dd class="text-sm text-white mt-1">{log_field(@log, :action)}</dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Status</dt>
              <dd class="mt-1">
                <span class={status_badge_class(log_field(@log, :status))}>
                  {log_field(@log, :status)}
                </span>
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Duration</dt>
              <dd class="text-sm text-white mt-1">
                {format_duration(log_field(@log, :duration_ms))}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Timestamp</dt>
              <dd class="text-sm text-white mt-1">{log_field(@log, :timestamp)}</dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Session ID</dt>
              <dd class="text-sm text-white mt-1 font-mono text-xs flex items-center gap-1">
                {log_field(@log, :session_id)}
                <button
                  phx-click={
                    JS.dispatch("phx:clipboard", detail: %{text: log_field(@log, :session_id)})
                  }
                  class="text-gray-500 hover:text-gray-300 ml-1"
                  title="Copy to clipboard"
                >
                  <.icon name="clipboard" class="h-3.5 w-3.5" />
                </button>
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">User ID</dt>
              <dd class="text-sm text-white mt-1">{log_field(@log, :user_id)}</dd>
            </div>
          </dl>
        </.card>
        
    <!-- Input -->
        <div :if={has_field?(@log, :input)}>
          <.card>
            <h3 class="text-sm font-medium text-gray-400 mb-2">Input</h3>
            <pre class="text-xs text-gray-300 bg-gray-950 rounded p-3 overflow-x-auto"><code>{format_json(log_field(@log, :input))}</code></pre>
          </.card>
        </div>
        
    <!-- Output -->
        <div :if={has_field?(@log, :output)}>
          <.card>
            <h3 class="text-sm font-medium text-gray-400 mb-2">Output</h3>
            <pre class="text-xs text-gray-300 bg-gray-950 rounded p-3 overflow-x-auto"><code>{format_json(log_field(@log, :output))}</code></pre>
          </.card>
        </div>
        
    <!-- Error -->
        <div :if={has_field?(@log, :error)}>
          <.card>
            <h3 class="text-sm font-medium text-red-400 mb-2">Error</h3>
            <div class="bg-red-950 rounded p-3 border border-red-900">
              <p class="text-sm text-red-300">{log_field(@log, :error)}</p>
              <p :if={has_field?(@log, :error_code)} class="text-xs text-red-500 mt-1">
                Code: {log_field(@log, :error_code)}
              </p>
            </div>
          </.card>
        </div>
        
    <!-- Related Executions -->
        <div :if={@executions != []}>
          <.card>
            <h3 class="text-sm font-medium text-gray-400 mb-3">Related Executions</h3>
            <.table id="related-executions" rows={@executions}>
              <:col :let={exec} label="Execution ID">
                <span class="font-mono text-xs">{log_field(exec, :id) |> to_string()}</span>
              </:col>
              <:col :let={exec} label="Reference">
                {format_ref(exec[:reference] || exec["reference"])}
              </:col>
              <:col :let={exec} label="Status">
                <span class={status_badge_class(log_field(exec, :status))}>
                  {log_field(exec, :status)}
                </span>
              </:col>
              <:col :let={exec} label="Duration">
                {format_duration(log_field(exec, :duration_ms))}
              </:col>
            </.table>
          </.card>
        </div>
        
    <!-- Policy Decisions -->
        <div :if={@policy_logs != []}>
          <.card>
            <h3 class="text-sm font-medium text-gray-400 mb-3">Policy Decisions</h3>
            <.table id="policy-decisions" rows={@policy_logs}>
              <:col :let={pol} label="Component">{log_field(pol, :component_ref)}</:col>
              <:col :let={pol} label="Decision">
                <span class={status_badge_class(normalize_decision(log_field(pol, :decision)))}>
                  {log_field(pol, :decision)}
                </span>
              </:col>
              <:col :let={pol} label="Reason">{log_field(pol, :decision_reason)}</:col>
            </.table>
          </.card>
        </div>
      </div>

      <div :if={!@loading && !@log}>
        <.empty_state message="Log not found" />
      </div>
    </div>
    """
  end

  defp normalize_decision("allow"), do: "success"
  defp normalize_decision("deny"), do: "error"
  defp normalize_decision(other), do: other
end
