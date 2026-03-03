defmodule PrismWeb.AgentLive do
  use PrismWeb, :live_view

  @providers %{
    "claude" => "catalyst:local.claude:1.0.0",
    "openai" => "catalyst:local.openai:1.0.0",
    "gemini" => "catalyst:local.gemini:1.0.0",
    "grok" => "catalyst:local.grok:1.0.0",
    "openrouter" => "catalyst:local.openrouter:1.0.0"
  }

  @provider_order ["claude", "openai", "gemini", "grok", "openrouter"]
  @default_provider "claude"
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
     |> assign(:provider, @default_provider)
     |> assign(:catalyst_ref, @providers[@default_provider])
     |> assign(:model, "")
     |> assign(:settings_provider, @default_provider)
     |> assign(:settings_model, "")
     |> assign(:provider_order, @provider_order)
     |> assign(:models_by_provider, %{})
     |> assign(:models_loading, false)
     |> assign(:expanded_tools, MapSet.new())
     |> assign(:setup_issues, [])
     |> assign(:setup_component_ref, nil)
     |> assign(:setup_command, nil)}
  end

  @impl true
  def handle_event("submit", %{"message" => message}, socket) when message != "" do
    # Add user message to display
    user_msg = %{role: "user", content: message, timestamp: DateTime.utc_now()}
    messages = socket.assigns.messages ++ [user_msg]

    # Build the CYFR agent system prompt
    ctx = socket.assigns.context
    system_prompt = build_system_prompt(ctx)

    # Build the agent formula input
    input = %{
      "catalyst_ref" => socket.assigns.catalyst_ref,
      "model" => socket.assigns.model,
      "task" => message,
      "system" => system_prompt,
      "max_turns" => @default_max_turns
    }

    # Include conversation history for continuation
    input =
      if socket.assigns.conversation_history != [] do
        Map.put(input, "messages", socket.assigns.conversation_history)
      else
        input
      end

    # Use run_stream to get execution_id upfront and subscribe to events
    lv = self()

    Task.start(fn ->
      result = Emissary.MCP.ToolRegistry.call(
        "execution",
        ctx,
        %{"action" => "run_stream", "reference" => "formula:local.agent:0.6.0", "input" => input}
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
    opening = !socket.assigns.settings_open

    socket =
      if opening do
        # Copy current state to draft
        socket =
          socket
          |> assign(:settings_open, true)
          |> assign(:settings_provider, socket.assigns.provider)
          |> assign(:settings_model, socket.assigns.model)

        # Load models for current provider if not cached
        if !Map.has_key?(socket.assigns.models_by_provider, socket.assigns.provider) do
          load_provider_models(socket, socket.assigns.provider)
        else
          socket
        end
      else
        assign(socket, :settings_open, false)
      end

    {:noreply, socket}
  end

  def handle_event("update_settings", params, socket) do
    provider = params["provider"] || socket.assigns.settings_provider
    provider_changed = provider != socket.assigns.settings_provider

    # If provider changed in draft, load models for new provider
    socket =
      if provider_changed do
        cached = Map.get(socket.assigns.models_by_provider, provider)
        model = if cached, do: List.first(cached) || "", else: ""

        socket =
          socket
          |> assign(:settings_provider, provider)
          |> assign(:settings_model, model)

        if cached, do: socket, else: load_provider_models(socket, provider)
      else
        socket
      end

    # If model explicitly set (from model dropdown) — skip when provider just
    # changed because params["model"] still holds the stale value from the
    # previous provider's <select>.
    socket =
      if not provider_changed do
        case params["model"] do
          nil -> socket
          model -> assign(socket, :settings_model, model)
        end
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("save_settings", _params, socket) do
    provider = socket.assigns.settings_provider
    model = socket.assigns.settings_model
    catalyst_ref = @providers[provider] || socket.assigns.catalyst_ref

    {:noreply,
     socket
     |> assign(:provider, provider)
     |> assign(:model, model)
     |> assign(:catalyst_ref, catalyst_ref)
     |> assign(:settings_open, false)
     |> push_event("save_preferences", %{provider: provider, model: model})}
  end

  def handle_event("cancel_settings", _params, socket) do
    {:noreply, assign(socket, :settings_open, false)}
  end

  def handle_event("restore_preferences", %{"provider" => provider, "model" => model}, socket)
      when is_binary(provider) and provider != "" do
    if Map.has_key?(@providers, provider) do
      {:noreply,
       socket
       |> assign(:provider, provider)
       |> assign(:model, model || "")
       |> assign(:catalyst_ref, @providers[provider])}
    else
      {:noreply, socket}
    end
  end

  def handle_event("restore_preferences", _params, socket), do: {:noreply, socket}

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

  def handle_event("keydown", %{"key" => "Enter", "shiftKey" => true}, socket) do
    if socket.assigns.input != "" && !socket.assigns.running do
      handle_event("submit", %{"message" => socket.assigns.input}, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("keydown", _params, socket), do: {:noreply, socket}

  def handle_event("fix_issue", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    issue = Enum.at(socket.assigns.setup_issues, index)

    if issue do
      fix = issue["fix"]
      ctx = socket.assigns.context
      args = Map.put(fix["args"], "action", fix["action"])

      case Emissary.MCP.ToolRegistry.call(fix["tool"], ctx, args) do
        {:ok, _} ->
          updated = List.update_at(socket.assigns.setup_issues, index, &Map.put(&1, "fixed", true))
          {:noreply, assign(socket, :setup_issues, updated)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Fix failed: #{reason}")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("fix_all", _params, socket) do
    ctx = socket.assigns.context

    results =
      socket.assigns.setup_issues
      |> Enum.with_index()
      |> Enum.map(fn {issue, idx} ->
        fix = issue["fix"]

        if fix && !issue["fixed"] do
          args = Map.put(fix["args"], "action", fix["action"])

          case Emissary.MCP.ToolRegistry.call(fix["tool"], ctx, args) do
            {:ok, _} -> {:ok, idx}
            {:error, _reason} -> {:error, idx}
          end
        else
          {:skip, idx}
        end
      end)

    updated =
      Enum.reduce(results, socket.assigns.setup_issues, fn
        {:ok, idx}, issues -> List.update_at(issues, idx, &Map.put(&1, "fixed", true))
        _, issues -> issues
      end)

    {:noreply, assign(socket, :setup_issues, updated)}
  end

  def handle_event("dismiss_setup", _params, socket) do
    {:noreply,
     socket
     |> assign(:setup_issues, [])
     |> assign(:setup_component_ref, nil)
     |> assign(:setup_command, nil)}
  end

  @impl true
  # Models loaded for a specific provider
  def handle_info({:models_loaded, provider, {:ok, result}}, socket) do
    model_ids = parse_provider_models(provider, result)
    models_by_provider = Map.put(socket.assigns.models_by_provider, provider, model_ids)

    # Determine which provider we're waiting on
    loading_for =
      if socket.assigns.settings_open,
        do: socket.assigns.settings_provider,
        else: socket.assigns.provider

    socket = assign(socket, :models_by_provider, models_by_provider)

    # Stop loading spinner if this is the provider we're waiting for
    socket =
      if provider == loading_for,
        do: assign(socket, :models_loading, false),
        else: socket

    # If settings are open and this is the draft provider, auto-select first model if none set
    socket =
      if socket.assigns.settings_open and provider == socket.assigns.settings_provider do
        current = socket.assigns.settings_model

        if (current == "" || current == nil) && model_ids != [] do
          assign(socket, :settings_model, List.first(model_ids))
        else
          socket
        end
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:models_loaded, provider, {:error, _reason}}, socket) do
    # Cache empty list so we don't retry
    models_by_provider = Map.put(socket.assigns.models_by_provider, provider, [])

    loading_for =
      if socket.assigns.settings_open,
        do: socket.assigns.settings_provider,
        else: socket.assigns.provider

    socket =
      socket
      |> assign(:models_by_provider, models_by_provider)
      |> then(fn s ->
        if provider == loading_for, do: assign(s, :models_loading, false), else: s
      end)

    {:noreply, socket}
  end

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

        "setup_required" ->
          issues = data["issues"] || []
          component_ref = data["component_ref"] || ""
          setup_cmd = data["setup_command"] || "cyfr setup #{component_ref}"

          socket
          |> assign(:setup_issues, issues)
          |> assign(:setup_component_ref, component_ref)
          |> assign(:setup_command, setup_cmd)
          |> assign(:progress, "Setup required")

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

      progress =
        cond do
          String.contains?(to_string(ref), "claude") -> "Calling Claude..."
          String.contains?(to_string(ref), "openai") -> "Calling OpenAI..."
          String.contains?(to_string(ref), "gemini") -> "Calling Gemini..."
          String.contains?(to_string(ref), "grok") -> "Calling Grok..."
          String.contains?(to_string(ref), "openrouter") -> "Calling OpenRouter..."
          String.contains?(to_string(ref), "files") -> "Working with files..."
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
        is_map(result) ->
          result

        is_binary(result) ->
          case Jason.decode(result) do
            {:ok, decoded} -> decoded
            _ -> %{"content" => result}
          end

        true ->
          %{"content" => inspect(result)}
      end

    content = data["content"] || data[:content] || ""
    messages = data["messages"] || data[:messages] || []
    turns = data["turns"] || data[:turns] || 0

    {content, messages, turns}
  end

  defp load_provider_models(socket, provider) do
    catalyst_ref = @providers[provider]
    lv = self()
    ctx = socket.assigns.context

    Task.start(fn ->
      result = Emissary.MCP.ToolRegistry.call(
        "execution",
        ctx,
        %{
          "action" => "run",
          "reference" => catalyst_ref,
          "input" => %{"operation" => "models.list", "params" => %{}},
          "type" => "catalyst"
        }
      )

      send(lv, {:models_loaded, provider, result})
    end)

    assign(socket, :models_loading, true)
  end

  defp parse_provider_models(provider, result) do
    data = extract_catalyst_output(result)

    case provider do
      "gemini" ->
        (data["models"] || [])
        |> Enum.map(fn m ->
          name = m["name"] || ""
          String.replace_prefix(name, "models/", "")
        end)
        |> Enum.reject(&(&1 == ""))

      _ ->
        (data["data"] || [])
        |> Enum.map(fn m -> m["id"] || "" end)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp extract_catalyst_output(result) when is_map(result) do
    # format_run_result returns atom keys: %{result: output, status: "completed", ...}
    # The output is a JSON string from the catalyst: '{"status":200,"data":{...}}'
    raw = result[:result] || result["result"] || result

    parsed =
      cond do
        is_binary(raw) ->
          case Jason.decode(raw) do
            {:ok, d} -> d
            _ -> %{}
          end

        is_map(raw) ->
          raw

        true ->
          %{}
      end

    # Catalyst output has {"status": 200, "data": {...}} — extract "data"
    parsed["data"] || parsed
  end

  defp extract_catalyst_output(result) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, d} -> d["data"] || d
      _ -> %{}
    end
  end

  defp extract_catalyst_output(_), do: %{}

  # ---------------------------------------------------------------------------
  # System prompt composition (for agent formula v0.6.0)
  # ---------------------------------------------------------------------------

  defp build_system_prompt(ctx) do
    sections = [
      "You are an agent running inside CYFR, a governed computation platform. " <>
        "You have access to tools for interacting with files and CYFR components."
    ]

    # MCP tools list
    sections =
      case fetch_mcp_tools(ctx) do
        {:ok, tools_info} ->
          sections ++
            [
              "## CYFR Platform Tools\n\n" <>
                "The following tools are available in this CYFR instance. " <>
                "You can discover and invoke components from the registry.\n\n" <>
                tools_info
            ]

        _ ->
          sections
      end

    # Component guide
    sections =
      case fetch_guide(ctx, "component-guide") do
        {:ok, guide} -> sections ++ ["## Component Guide\n\n" <> guide]
        _ -> sections
      end

    # Integration guide
    sections =
      case fetch_guide(ctx, "integration-guide") do
        {:ok, guide} -> sections ++ ["## Integration Guide\n\n" <> guide]
        _ -> sections
      end

    Enum.join(sections, "\n\n")
  end

  defp fetch_mcp_tools(ctx) do
    case Emissary.MCP.ToolRegistry.call("tools", ctx, %{"action" => "list"}) do
      {:ok, result} ->
        formatted =
          case Jason.encode(result, pretty: true) do
            {:ok, json} -> json
            _ -> inspect(result)
          end

        {:ok, formatted}

      error ->
        error
    end
  end

  defp fetch_guide(ctx, name) do
    case Emissary.MCP.ToolRegistry.call("guide", ctx, %{"action" => "get", "name" => name}) do
      {:ok, result} when is_binary(result) ->
        {:ok, result}

      {:ok, %{content: content}} when is_binary(content) ->
        {:ok, content}

      {:ok, %{"content" => content}} when is_binary(content) ->
        {:ok, content}

      {:ok, result} when is_map(result) ->
        {:ok, inspect(result)}

      error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="agent-container" class="flex flex-col h-[calc(100vh-3.25rem)]" phx-hook="AgentChat">
      <!-- Header -->
      <div class="flex items-center justify-between mb-4">
        <div class="flex items-center gap-3">
          <h2 class="text-lg font-semibold text-white">Agent</h2>
          <%= if @model == "" do %>
            <span class="text-xs text-amber-400 animate-pulse">
              Please choose model →
            </span>
          <% else %>
            <span class="text-xs text-gray-500 font-mono">
              {provider_label(@provider)} / {@model}
            </span>
          <% end %>
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
          <form phx-change="update_settings" class="flex items-end gap-3">
            <div class="flex-1 min-w-0">
              <label class="block text-xs text-gray-500 uppercase mb-1">Provider</label>
              <select
                name="provider"
                class="w-full rounded-lg bg-gray-800 border border-gray-700 px-3 py-1.5 text-sm text-white focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
              >
                <%= for p <- @provider_order do %>
                  <option value={p} selected={p == @settings_provider}>{provider_label(p)}</option>
                <% end %>
              </select>
            </div>
            <div class="flex-1 min-w-0">
              <label class="block text-xs text-gray-500 uppercase mb-1">Model</label>
              <%= if @models_loading do %>
                <div class="w-full rounded-lg bg-gray-800 border border-gray-700 px-3 py-1.5 text-sm text-gray-500 flex items-center gap-2">
                  <div class="w-3 h-3 border-2 border-gray-600 border-t-blue-400 rounded-full animate-spin" />
                  Loading...
                </div>
              <% else %>
                <select
                  name="model"
                  class="w-full rounded-lg bg-gray-800 border border-gray-700 px-3 py-1.5 text-sm text-white focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
                >
                  <option value="" disabled selected={@settings_model == ""}>Select a model...</option>
                  <%= for m <- Map.get(@models_by_provider, @settings_provider, []) do %>
                    <option value={m} selected={m == @settings_model}>{m}</option>
                  <% end %>
                </select>
              <% end %>
            </div>
            <div class="flex gap-2 shrink-0">
              <button
                type="button"
                phx-click="save_settings"
                disabled={@settings_model == ""}
                class="px-3 py-1.5 text-xs font-medium rounded-md bg-blue-600 text-white hover:bg-blue-500 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                Save
              </button>
              <button
                type="button"
                phx-click="cancel_settings"
                class="px-3 py-1.5 text-xs font-medium rounded-md bg-gray-700 text-gray-300 hover:bg-gray-600"
              >
                Cancel
              </button>
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

        <!-- Setup required panel -->
        <div :if={@setup_issues != []} class="rounded-lg border border-amber-800 bg-amber-950/50 p-4">
          <div class="flex items-center justify-between mb-3">
            <div class="flex items-center gap-2">
              <span class="text-amber-400 text-sm font-medium">Setup Required</span>
              <span :if={@setup_component_ref} class="text-xs text-gray-500 font-mono">{@setup_component_ref}</span>
            </div>
            <button phx-click="dismiss_setup" class="text-gray-500 hover:text-gray-400 text-xs">Dismiss</button>
          </div>

          <div class="space-y-2 mb-3">
            <%= for {issue, idx} <- Enum.with_index(@setup_issues) do %>
              <div class={"flex items-center justify-between rounded px-3 py-2 text-sm #{if issue["fixed"], do: "bg-green-950/50 border border-green-900", else: "bg-gray-800 border border-gray-700"}"}>
                <div>
                  <span class={"font-mono text-xs #{if issue["fixed"], do: "text-green-400", else: "text-amber-300"}"}>
                    {issue_label(issue)}
                  </span>
                  <span :if={issue["description"]} class="text-gray-500 text-xs ml-2">{issue["description"]}</span>
                </div>
                <div>
                  <%= if issue["fixed"] do %>
                    <span class="text-green-400 text-xs font-medium">Fixed</span>
                  <% else %>
                    <button
                      phx-click="fix_issue"
                      phx-value-index={idx}
                      class="px-2 py-1 text-xs font-medium rounded bg-amber-800 text-amber-200 hover:bg-amber-700"
                    >
                      Fix
                    </button>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>

          <div class="flex items-center justify-between">
            <code class="text-xs text-gray-500">{@setup_command}</code>
            <button
              :if={Enum.any?(@setup_issues, &(!&1["fixed"]))}
              phx-click="fix_all"
              class="px-3 py-1.5 text-xs font-medium rounded-md bg-amber-700 text-white hover:bg-amber-600"
            >
              Fix All
            </button>
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
              rows="1"
              class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-3 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500 resize-none disabled:opacity-50 overflow-hidden"
            />
          </div>
          <button
            type="submit"
            disabled={@running || @input == "" || @model == ""}
            class="inline-flex items-center justify-center gap-2 rounded-lg px-4 py-2 text-sm font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-offset-gray-900 bg-blue-600 text-white hover:bg-blue-500 focus:ring-blue-500 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            Send
          </button>
        </form>
        <p class="text-xs text-gray-600 mt-2">
          Press Shift+Enter to send, Enter for new line
        </p>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Render helpers
  # ---------------------------------------------------------------------------

  defp provider_label("claude"), do: "Claude"
  defp provider_label("openai"), do: "OpenAI"
  defp provider_label("gemini"), do: "Gemini"
  defp provider_label("grok"), do: "Grok"
  defp provider_label("openrouter"), do: "OpenRouter"
  defp provider_label(p), do: p

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

  defp issue_label(%{"type" => "missing_policy", "field" => field}),
    do: "Missing policy: #{field}"

  defp issue_label(%{"type" => "missing_secret_grant", "secret_name" => name}),
    do: "Secret not granted: #{name}"

  defp issue_label(%{"type" => "missing_secret", "secret_name" => name}),
    do: "Secret not set: #{name}"

  defp issue_label(%{"type" => type}), do: type
  defp issue_label(_), do: "Unknown issue"
end
