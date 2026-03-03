defmodule PrismWeb.AgentLive do
  use PrismWeb, :live_view

  @default_catalyst_ref "catalyst:local.claude:0.2.0"
  @default_model "claude-sonnet-4-5-20250514"
  @default_max_turns 30

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Emissary.PubSub, "prism:executions")
    end

    {:ok,
     socket
     |> assign(:page_title, "Agent")
     |> assign(:messages, [])
     |> assign(:conversation_history, [])
     |> assign(:input, "")
     |> assign(:running, false)
     |> assign(:progress, nil)
     |> assign(:streaming_text, "")
     |> assign(:current_turn, 0)
     |> assign(:current_execution_id, nil)
     |> assign(:settings_open, false)
     |> assign(:catalyst_ref, @default_catalyst_ref)
     |> assign(:model, @default_model)
     |> assign(:project_path, "")
     |> assign(:expanded_tools, MapSet.new())}
  end

  @impl true
  def handle_event("submit", %{"message" => message}, socket) when message != "" do
    # Add user message to display
    user_msg = %{role: "user", content: message, timestamp: DateTime.utc_now()}
    messages = socket.assigns.messages ++ [user_msg]

    # Build the agent formula input
    input = %{
      "catalyst_ref" => socket.assigns.catalyst_ref,
      "model" => socket.assigns.model,
      "task" => message,
      "project_path" => socket.assigns.project_path,
      "max_turns" => @default_max_turns
    }

    # Include conversation history for continuation
    input =
      if socket.assigns.conversation_history != [] do
        Map.put(input, "messages", socket.assigns.conversation_history)
      else
        input
      end

    input_json = Jason.encode!(input)

    # Use run_stream to get execution_id upfront and subscribe to events
    lv = self()
    ctx = socket.assigns.context

    Task.start(fn ->
      result = Emissary.MCP.ToolRegistry.call(
        "execution",
        ctx,
        %{"action" => "run_stream", "reference" => "formula:local.agent:0.4.0", "input" => input_json}
      )

      case result do
        {:ok, %{execution_id: exec_id}} ->
          send(lv, {:stream_started, exec_id})

        {:ok, %{"execution_id" => exec_id}} ->
          send(lv, {:stream_started, exec_id})

        {:error, reason} ->
          send(lv, {:agent_result, {:error, reason}})
      end
    end)

    {:noreply,
     socket
     |> assign(:messages, messages)
     |> assign(:input, "")
     |> assign(:running, true)
     |> assign(:streaming_text, "")
     |> assign(:current_turn, 0)
     |> assign(:progress, "Starting...")}
  end

  def handle_event("submit", _params, socket), do: {:noreply, socket}

  def handle_event("update_input", %{"message" => value}, socket) do
    {:noreply, assign(socket, :input, value)}
  end

  def handle_event("toggle_settings", _params, socket) do
    {:noreply, assign(socket, :settings_open, !socket.assigns.settings_open)}
  end

  def handle_event("update_settings", params, socket) do
    {:noreply,
     socket
     |> assign(:catalyst_ref, params["catalyst_ref"] || socket.assigns.catalyst_ref)
     |> assign(:model, params["model"] || socket.assigns.model)
     |> assign(:project_path, params["project_path"] || socket.assigns.project_path)}
  end

  def handle_event("clear_conversation", _params, socket) do
    {:noreply,
     socket
     |> assign(:messages, [])
     |> assign(:conversation_history, [])
     |> assign(:expanded_tools, MapSet.new())}
  end

  def handle_event("toggle_tool", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded_tools

    expanded =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)

    {:noreply, assign(socket, :expanded_tools, expanded)}
  end

  def handle_event("keydown", %{"key" => "Enter", "shiftKey" => false}, socket) do
    if socket.assigns.input != "" && !socket.assigns.running do
      handle_event("submit", %{"message" => socket.assigns.input}, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("keydown", _params, socket), do: {:noreply, socket}

  @impl true
  # Stream started — subscribe to execution events
  def handle_info({:stream_started, execution_id}, socket) do
    if connected?(socket) do
      Opus.ExecutionEventBuffer.subscribe(execution_id)
    end

    {:noreply,
     socket
     |> assign(:current_execution_id, execution_id)
     |> assign(:progress, "Thinking...")}
  end

  # Execution events from the formula's emit() calls
  def handle_info({:execution_event, %{type: "emit", data: data}}, socket) do
    kind = data["kind"] || data[:kind]

    socket =
      case kind do
        "turn_start" ->
          turn = data["turn"] || data[:turn] || 0
          socket
          |> assign(:current_turn, turn)
          |> assign(:progress, "Turn #{turn}...")

        "text_delta" ->
          content = data["content"] || data[:content] || ""
          socket
          |> assign(:streaming_text, socket.assigns.streaming_text <> content)
          |> assign(:progress, "Writing...")
          |> push_event("scroll_bottom", %{})

        "tool_use" ->
          tool = data["tool"] || data[:tool] || "tool"
          assign(socket, :progress, "Using #{tool}...")

        "tool_result" ->
          tool = data["tool"] || data[:tool] || "tool"
          assign(socket, :progress, "#{tool} completed")

        _ ->
          socket
      end

    {:noreply, socket}
  end

  # Terminal event: execution completed
  def handle_info({:execution_event, %{type: "complete"}}, socket) do
    exec_id = socket.assigns.current_execution_id
    if exec_id, do: Opus.ExecutionEventBuffer.unsubscribe(exec_id)

    # The streaming text is the progressive content; use it if we have it
    streaming = socket.assigns.streaming_text

    if streaming != "" do
      assistant_msg = %{
        role: "assistant",
        content: streaming,
        turns: socket.assigns.current_turn,
        timestamp: DateTime.utc_now()
      }

      {:noreply,
       socket
       |> assign(:messages, socket.assigns.messages ++ [assistant_msg])
       |> assign(:running, false)
       |> assign(:progress, nil)
       |> assign(:streaming_text, "")
       |> assign(:current_execution_id, nil)
       |> push_event("scroll_bottom", %{})}
    else
      # No streaming text accumulated — wait for agent_result
      {:noreply,
       socket
       |> assign(:current_execution_id, nil)}
    end
  end

  # Terminal event: execution error
  def handle_info({:execution_event, %{type: "error", data: data}}, socket) do
    exec_id = socket.assigns.current_execution_id
    if exec_id, do: Opus.ExecutionEventBuffer.unsubscribe(exec_id)

    error_msg = %{
      role: "error",
      content: "Agent error: #{data["error"] || data[:error] || "Unknown error"}",
      timestamp: DateTime.utc_now()
    }

    {:noreply,
     socket
     |> assign(:messages, socket.assigns.messages ++ [error_msg])
     |> assign(:running, false)
     |> assign(:progress, nil)
     |> assign(:streaming_text, "")
     |> assign(:current_execution_id, nil)}
  end

  # Legacy: agent_result from run (fallback if complete event didn't carry content)
  def handle_info({:agent_result, {:ok, result}}, socket) do
    {content, conversation_history, turns} = parse_agent_result(result)

    # Only add message if we didn't already add one from streaming
    if socket.assigns.running do
      assistant_msg = %{
        role: "assistant",
        content: content,
        turns: turns,
        timestamp: DateTime.utc_now()
      }

      {:noreply,
       socket
       |> assign(:messages, socket.assigns.messages ++ [assistant_msg])
       |> assign(:conversation_history, conversation_history)
       |> assign(:running, false)
       |> assign(:progress, nil)
       |> assign(:streaming_text, "")
       |> push_event("scroll_bottom", %{})}
    else
      # Already finalized from streaming events — just update conversation history
      {:noreply, assign(socket, :conversation_history, conversation_history)}
    end
  end

  def handle_info({:agent_result, {:error, reason}}, socket) do
    error_msg = %{
      role: "error",
      content: "Agent error: #{inspect(reason)}",
      timestamp: DateTime.utc_now()
    }

    {:noreply,
     socket
     |> assign(:messages, socket.assigns.messages ++ [error_msg])
     |> assign(:running, false)
     |> assign(:progress, nil)
     |> assign(:streaming_text, "")}
  end

  # Execution telemetry — update progress indicator (from prism:executions topic)
  def handle_info({:execution_started, metadata, _measurements}, socket) do
    if socket.assigns.running do
      ref = metadata[:component] || metadata[:reference] || ""
      progress = cond do
        String.contains?(to_string(ref), "claude") -> "Calling Claude..."
        String.contains?(to_string(ref), "openai") -> "Calling OpenAI..."
        String.contains?(to_string(ref), "gemini") -> "Calling Gemini..."
        String.contains?(to_string(ref), "workspace") -> "Working with files..."
        ref != "" -> "Running #{ref}..."
        true -> "Working..."
      end

      {:noreply, assign(socket, :progress, progress)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:execution_completed, metadata, _measurements}, socket) do
    if socket.assigns.running do
      duration = metadata[:duration_ms]
      progress =
        if duration, do: "Step completed in #{duration}ms", else: socket.assigns.progress

      {:noreply, assign(socket, :progress, progress)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Result parsing
  # ---------------------------------------------------------------------------

  defp parse_agent_result(result) do
    # result could be a map or string
    data =
      cond do
        is_map(result) -> result
        is_binary(result) ->
          case Jason.decode(result) do
            {:ok, decoded} -> decoded
            _ -> %{"content" => result}
          end
        true -> %{"content" => inspect(result)}
      end

    content = data["content"] || data[:content] || ""
    messages = data["messages"] || data[:messages] || []
    turns = data["turns"] || data[:turns] || 0

    {content, messages, turns}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="agent-container" class="flex flex-col h-[calc(100vh-8rem)]" phx-hook="AgentChat">
      <!-- Header -->
      <div class="flex items-center justify-between mb-4">
        <div class="flex items-center gap-3">
          <h2 class="text-lg font-semibold text-white">Agent</h2>
          <span class="text-xs text-gray-500 font-mono">{@model}</span>
        </div>
        <div class="flex items-center gap-2">
          <button
            :if={@messages != []}
            phx-click="clear_conversation"
            class="px-3 py-1.5 text-xs font-medium rounded-md bg-gray-800 text-gray-400 border border-gray-700 hover:bg-gray-700 hover:text-gray-300"
          >
            Clear
          </button>
          <button
            phx-click="toggle_settings"
            class={"px-3 py-1.5 text-xs font-medium rounded-md border #{if @settings_open, do: "bg-blue-900 text-blue-300 border-blue-700", else: "bg-gray-800 text-gray-400 border-gray-700 hover:bg-gray-700"}"}
          >
            Settings
          </button>
        </div>
      </div>

      <!-- Settings panel -->
      <div :if={@settings_open} class="mb-4">
        <.card>
          <form phx-change="update_settings" class="grid grid-cols-1 md:grid-cols-3 gap-4">
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Catalyst</label>
              <input
                type="text"
                name="catalyst_ref"
                value={@catalyst_ref}
                class="w-full rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
              />
            </div>
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Model</label>
              <input
                type="text"
                name="model"
                value={@model}
                class="w-full rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
              />
            </div>
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Project Path</label>
              <input
                type="text"
                name="project_path"
                value={@project_path}
                placeholder="e.g. components/"
                class="w-full rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
              />
            </div>
          </form>
        </.card>
      </div>

      <!-- Messages area -->
      <div id="messages" class="flex-1 overflow-y-auto space-y-4 mb-4 pr-2" phx-update="replace">
        <div :if={@messages == []} class="flex items-center justify-center h-full">
          <div class="text-center">
            <p class="text-gray-500 text-sm">Start a conversation with the agent.</p>
            <p class="text-gray-600 text-xs mt-2">
              The agent can read, write, and search files, invoke components, and access CYFR platform tools.
            </p>
          </div>
        </div>

        <%= for {msg, idx} <- Enum.with_index(@messages) do %>
          <div id={"msg-#{idx}"} class={message_container_class(msg.role)}>
            <!-- Role label -->
            <div class="flex items-center gap-2 mb-1">
              <span class={role_label_class(msg.role)}>
                {role_label(msg.role)}
              </span>
              <span :if={msg[:turns]} class="text-xs text-gray-600">
                {msg.turns} turn(s)
              </span>
            </div>

            <!-- Content -->
            <div class={content_class(msg.role)}>
              <pre class="whitespace-pre-wrap break-words text-sm font-sans">{msg.content}</pre>
            </div>
          </div>
        <% end %>

        <!-- Progress indicator with streaming text -->
        <div :if={@running} class="flex items-start gap-3">
          <div class="flex-1">
            <div class="flex items-center gap-2 mb-1">
              <span class="text-xs font-medium text-blue-400">Agent</span>
              <div class="flex items-center gap-1">
                <div class="w-1.5 h-1.5 rounded-full bg-blue-400 animate-pulse" />
                <span class="text-xs text-gray-500">{@progress}</span>
              </div>
            </div>
            <div :if={@streaming_text != ""} class="bg-gray-900 rounded-lg px-4 py-3 text-gray-300 border border-gray-800 mt-1">
              <pre class="whitespace-pre-wrap break-words text-sm font-sans">{@streaming_text}</pre>
            </div>
          </div>
        </div>
      </div>

      <!-- Input area -->
      <div class="border-t border-gray-800 pt-4">
        <form phx-submit="submit" class="flex gap-3">
          <div class="flex-1 relative">
            <textarea
              name="message"
              value={@input}
              phx-change="update_input"
              phx-keydown="keydown"
              placeholder={if @running, do: "Agent is working...", else: "Ask the agent to do something..."}
              disabled={@running}
              rows="2"
              class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-3 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500 resize-none disabled:opacity-50"
            />
          </div>
          <button
            type="submit"
            disabled={@running || @input == ""}
            class="inline-flex items-center justify-center gap-2 rounded-lg px-4 py-2 text-sm font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-offset-gray-900 bg-blue-600 text-white hover:bg-blue-500 focus:ring-blue-500 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            Send
          </button>
        </form>
        <p class="text-xs text-gray-600 mt-2">
          Press Enter to send, Shift+Enter for new line
        </p>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Render helpers
  # ---------------------------------------------------------------------------

  defp message_container_class("user"), do: "flex items-start gap-3"
  defp message_container_class("assistant"), do: "flex items-start gap-3"
  defp message_container_class("error"), do: "flex items-start gap-3"
  defp message_container_class(_), do: "flex items-start gap-3"

  defp role_label("user"), do: "You"
  defp role_label("assistant"), do: "Agent"
  defp role_label("error"), do: "Error"
  defp role_label(role), do: role

  defp role_label_class("user"), do: "text-xs font-medium text-gray-400"
  defp role_label_class("assistant"), do: "text-xs font-medium text-blue-400"
  defp role_label_class("error"), do: "text-xs font-medium text-red-400"
  defp role_label_class(_), do: "text-xs font-medium text-gray-500"

  defp content_class("user"),
    do: "bg-gray-800 rounded-lg px-4 py-3 text-gray-300"

  defp content_class("assistant"),
    do: "bg-gray-900 rounded-lg px-4 py-3 text-gray-300 border border-gray-800"

  defp content_class("error"),
    do: "bg-red-950 rounded-lg px-4 py-3 text-red-300 border border-red-900"

  defp content_class(_),
    do: "bg-gray-900 rounded-lg px-4 py-3 text-gray-300"
end
