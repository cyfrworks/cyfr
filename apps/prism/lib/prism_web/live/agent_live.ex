defmodule PrismWeb.AgentLive do
  use PrismWeb, :live_view

  @list_models_ref "formula:local.list-models:0.5.0"
  @agent_ref "formula:local.agent:0.9.0"
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
     |> assign(:model, "")
     |> assign(:settings_provider, @default_provider)
     |> assign(:settings_model, "")
     |> assign(:providers, [])
     |> assign(:catalyst_refs, %{})
     |> assign(:models_by_provider, %{})
     |> assign(:models_loading, false)
     |> assign(:tool_activity, [])
     |> assign(:expanded_tools, MapSet.new())
     |> assign(:setup_issues, [])
     |> assign(:setup_component_ref, nil)
     |> assign(:setup_command, nil)
     |> assign(:pending_provider, nil)
     |> assign(:pending_model, nil)}
  end

  @impl true
  def handle_event("submit", %{"message" => raw_message}, socket) when raw_message != "" do
    message = String.trim(raw_message)

    cond do
      message == "" ->
        {:noreply, socket}

      socket.assigns.model == "" ->
        {:noreply, put_flash(socket, :error, "Please select a model in Settings first.")}

      true ->
        # Add user message to display
        user_msg = %{role: "user", content: message, timestamp: DateTime.utc_now()}
        messages = socket.assigns.messages ++ [user_msg]

        # Build the CYFR agent system prompt
        ctx = socket.assigns.context
        system_prompt = build_system_prompt(ctx)

        # Get catalyst ref from dynamic refs map
        catalyst_ref = socket.assigns.catalyst_refs[socket.assigns.provider]

        # Build the agent formula input
        input = %{
          "catalyst_ref" => catalyst_ref,
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
            %{"action" => "run_stream", "reference" => @agent_ref, "input" => input}
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
         |> assign(:tool_activity, [])
         |> assign(:current_turn, 0)
         |> assign(:progress, "Starting...")
         |> persist_messages()}
    end
  end

  def handle_event("submit", _params, socket), do: {:noreply, socket}

  def handle_event("update_input", %{"message" => value}, socket) do
    {:noreply, assign(socket, :input, value)}
  end

  def handle_event("toggle_settings", _params, socket) do
    opening = !socket.assigns.settings_open

    socket =
      if opening do
        socket =
          socket
          |> assign(:settings_open, true)
          |> assign(:settings_provider, socket.assigns.provider)
          |> assign(:settings_model, socket.assigns.model)
          |> clear_flash()

        # Load all models if not yet loaded
        if socket.assigns.providers == [] do
          load_all_models(socket)
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

    socket =
      if provider_changed do
        cached = Map.get(socket.assigns.models_by_provider, provider)
        model = if cached, do: List.first(cached) || "", else: ""

        socket
        |> assign(:settings_provider, provider)
        |> assign(:settings_model, model)
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

    {:noreply,
     socket
     |> assign(:provider, provider)
     |> assign(:model, model)
     |> assign(:settings_open, false)
     |> clear_flash()
     |> push_event("save_preferences", %{provider: provider, model: model})}
  end

  def handle_event("cancel_settings", _params, socket) do
    {:noreply, assign(socket, :settings_open, false)}
  end

  def handle_event("restore_preferences", %{"provider" => provider, "model" => model}, socket)
      when is_binary(provider) and provider != "" do
    # Always apply immediately so header/submit work right away.
    # Also stash as pending so apply_provider_defaults can validate
    # or correct once models actually load.
    socket =
      socket
      |> assign(:provider, provider)
      |> assign(:model, model || "")
      |> assign(:pending_provider, provider)
      |> assign(:pending_model, model || "")

    # Eagerly load models so catalyst_refs gets populated
    socket =
      if socket.assigns.providers == [] and not socket.assigns.models_loading do
        load_all_models(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("restore_preferences", _params, socket), do: {:noreply, socket}

  def handle_event("restore_messages", %{"messages" => messages}, socket)
      when is_list(messages) and messages != [] do
    restored =
      Enum.map(messages, fn msg ->
        base = %{
          role: msg["role"] || "user",
          content: msg["content"] || "",
          timestamp: parse_timestamp(msg["timestamp"])
        }

        base = if msg["turns"], do: Map.put(base, :turns, msg["turns"]), else: base

        if is_list(msg["tool_activity"]) && msg["tool_activity"] != [] do
          activity = Enum.map(msg["tool_activity"], fn e ->
            %{
              tool: e["tool"] || "tool",
              status: String.to_existing_atom(e["status"] || "done"),
              preview: e["preview"]
            }
          end)
          Map.put(base, :tool_activity, activity)
        else
          base
        end
      end)

    {:noreply, assign(socket, :messages, restored)}
  end

  def handle_event("restore_messages", _params, socket), do: {:noreply, socket}

  def handle_event("clear_conversation", _params, socket) do
    {:noreply,
     socket
     |> assign(:messages, [])
     |> assign(:conversation_history, [])
     |> assign(:expanded_tools, MapSet.new())
     |> push_event("clear_messages", %{})}
  end

  def handle_event("toggle_tool", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded_tools

    expanded =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)

    {:noreply, assign(socket, :expanded_tools, expanded)}
  end

  def handle_event("dismiss_setup", _params, socket) do
    {:noreply,
     socket
     |> assign(:setup_issues, [])
     |> assign(:setup_component_ref, nil)
     |> assign(:setup_command, nil)
     |> assign(:pending_provider, nil)
     |> assign(:pending_model, nil)}
  end

  @impl true
  # list-models formula result
  def handle_info({:list_models_result, {:ok, result}}, socket) do
    data = parse_formula_output(result)
    models_map = data["models"] || %{}
    refs_map = data["refs"] || %{}
    errors_map = data["errors"] || %{}

    provider_names = models_map |> Map.keys() |> Enum.sort()
    models_by_provider =
      for {provider, raw} <- models_map, into: %{} do
        {provider, parse_model_ids(provider, raw)}
      end

    socket =
      socket
      |> assign(:providers, provider_names)
      |> assign(:catalyst_refs, refs_map)
      |> assign(:models_by_provider, models_by_provider)
      |> assign(:models_loading, false)
      |> maybe_auto_select_model()
      |> apply_provider_defaults()

    # Show flash if some providers failed
    failed = errors_map |> Map.keys() |> Enum.sort()

    socket =
      cond do
        provider_names == [] && failed != [] ->
          put_flash(socket, :error, "All providers failed: #{Enum.join(failed, ", ")}. Check catalyst policies and secrets.")

        failed != [] ->
          put_flash(socket, :warning, "Some providers failed: #{Enum.join(failed, ", ")}")

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info({:list_models_result, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:models_loading, false)
     |> put_flash(:error, "Failed to load models: #{inspect(reason)}")}
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
          new_text = socket.assigns.streaming_text <> content
          socket
          |> assign(:streaming_text, new_text)
          |> assign(:progress, "Writing...")
          |> push_event("streaming_delta", %{text: new_text})
          |> push_event("save_partial", %{text: new_text})
          |> push_event("scroll_bottom", %{})

        "tool_use" ->
          tool = data["tool"] || data[:tool] || "tool"
          turn = data["turn"] || data[:turn] || socket.assigns.current_turn
          entry = %{tool: tool, status: :running, turn: turn, preview: nil}

          socket
          |> assign(:tool_activity, socket.assigns.tool_activity ++ [entry])
          |> assign(:progress, "Using #{tool}...")
          |> push_event("scroll_bottom", %{})

        "tool_result" ->
          tool = data["tool"] || data[:tool] || "tool"
          preview = data["preview"] || data[:preview]

          activity = update_last_running(socket.assigns.tool_activity, tool, preview)

          socket
          |> assign(:tool_activity, activity)
          |> assign(:progress, "#{tool} completed")

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
      activity = socket.assigns.tool_activity

      assistant_msg = %{
        role: "assistant",
        content: streaming,
        turns: socket.assigns.current_turn,
        timestamp: DateTime.utc_now()
      }

      assistant_msg =
        if activity != [], do: Map.put(assistant_msg, :tool_activity, activity), else: assistant_msg

      {:noreply,
       socket
       |> assign(:messages, socket.assigns.messages ++ [assistant_msg])
       |> assign(:running, false)
       |> assign(:progress, nil)
       |> assign(:streaming_text, "")
       |> assign(:tool_activity, [])
       |> assign(:current_execution_id, nil)
       |> persist_messages()
       |> push_event("clear_partial", %{})
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
     |> assign(:tool_activity, [])
     |> assign(:current_execution_id, nil)
     |> persist_messages()
     |> push_event("clear_partial", %{})}
  end

  # Legacy: agent_result from run (fallback if complete event didn't carry content)
  def handle_info({:agent_result, {:ok, result}}, socket) do
    {content, conversation_history, turns} = parse_agent_result(result)

    # Only add message if we didn't already add one from streaming
    if socket.assigns.running do
      activity = socket.assigns.tool_activity

      assistant_msg = %{
        role: "assistant",
        content: content,
        turns: turns,
        timestamp: DateTime.utc_now()
      }

      assistant_msg =
        if activity != [], do: Map.put(assistant_msg, :tool_activity, activity), else: assistant_msg

      {:noreply,
       socket
       |> assign(:messages, socket.assigns.messages ++ [assistant_msg])
       |> assign(:conversation_history, conversation_history)
       |> assign(:running, false)
       |> assign(:progress, nil)
       |> assign(:streaming_text, "")
       |> assign(:tool_activity, [])
       |> persist_messages()
       |> push_event("clear_partial", %{})
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
     |> assign(:streaming_text, "")
     |> assign(:tool_activity, [])
     |> persist_messages()
     |> push_event("clear_partial", %{})}
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
  # Model loading via list-models formula
  # ---------------------------------------------------------------------------

  defp load_all_models(socket) do
    lv = self()
    ctx = socket.assigns.context

    Task.start(fn ->
      result = Emissary.MCP.ToolRegistry.call(
        "execution",
        ctx,
        %{"action" => "run", "reference" => @list_models_ref, "input" => %{}, "type" => "formula"}
      )

      send(lv, {:list_models_result, result})
    end)

    assign(socket, :models_loading, true)
  end

  defp parse_formula_output(result) when is_map(result) do
    raw = result[:result] || result["result"] || result

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
  end

  defp parse_formula_output(result) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, d} -> d
      _ -> %{}
    end
  end

  defp parse_formula_output(_), do: %{}

  defp parse_model_ids("gemini", data) do
    (data["models"] || [])
    |> Enum.map(fn m ->
      name = m["name"] || ""
      String.replace_prefix(name, "models/", "")
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_model_ids(_provider, data) do
    (data["data"] || [])
    |> Enum.map(fn m -> m["id"] || "" end)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_auto_select_model(socket) do
    if socket.assigns.settings_open do
      provider = socket.assigns.settings_provider
      providers = socket.assigns.providers
      models_by_provider = socket.assigns.models_by_provider

      # If current settings_provider isn't in loaded providers, switch to first available
      {provider, models} =
        if provider in providers do
          {provider, Map.get(models_by_provider, provider, [])}
        else
          first = List.first(providers) || provider
          {first, Map.get(models_by_provider, first, [])}
        end

      current = socket.assigns.settings_model

      socket
      |> assign(:settings_provider, provider)
      |> then(fn s ->
        if current != "" && current != nil && current in models do
          s
        else
          assign(s, :settings_model, "")
        end
      end)
    else
      socket
    end
  end

  defp apply_provider_defaults(socket) do
    providers = socket.assigns.providers
    pending_provider = socket.assigns.pending_provider
    pending_model = socket.assigns.pending_model

    cond do
      # Pending preference matches a loaded provider — validate the model
      pending_provider && pending_provider in providers ->
        model =
          if pending_model && pending_model != "" do
            models = Map.get(socket.assigns.models_by_provider, pending_provider, [])
            if pending_model in models, do: pending_model, else: ""
          else
            ""
          end

        socket
        |> assign(:provider, pending_provider)
        |> assign(:model, model)
        |> assign(:pending_provider, nil)
        |> assign(:pending_model, nil)

      # Current provider not in loaded list — update provider but don't auto-select model
      socket.assigns.provider not in providers && providers != [] ->
        first = List.first(providers)

        socket
        |> assign(:provider, first)
        |> assign(:model, "")
        |> assign(:pending_provider, nil)
        |> assign(:pending_model, nil)

      true ->
        assign(socket, pending_provider: nil, pending_model: nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Tool activity helpers
  # ---------------------------------------------------------------------------

  defp update_last_running(activity, tool, preview) do
    # Find last entry with matching tool name and :running status, mark it :done
    idx =
      activity
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {entry, i} ->
        if entry.tool == tool && entry.status == :running, do: i
      end)

    if idx do
      List.update_at(activity, idx, &%{&1 | status: :done, preview: preview})
    else
      activity
    end
  end

  # ---------------------------------------------------------------------------
  # Message persistence
  # ---------------------------------------------------------------------------

  defp persist_messages(socket) do
    messages = socket.assigns.messages

    serialized =
      Enum.map(messages, fn msg ->
        base = %{role: msg.role, content: msg.content, timestamp: DateTime.to_iso8601(msg.timestamp)}
        base = if Map.has_key?(msg, :turns), do: Map.put(base, :turns, msg.turns), else: base

        if Map.has_key?(msg, :tool_activity) && msg.tool_activity != [] do
          activity = Enum.map(msg.tool_activity, fn e ->
            %{tool: e.tool, status: to_string(e.status), preview: e.preview}
          end)
          Map.put(base, :tool_activity, activity)
        else
          base
        end
      end)

    push_event(socket, "save_messages", %{messages: serialized})
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: DateTime.utc_now()

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

  # ---------------------------------------------------------------------------
  # System prompt composition
  # ---------------------------------------------------------------------------

  defp build_system_prompt(ctx) do
    sections = [
      "You are an agent running inside CYFR, a governed computation platform. " <>
        "You have access to tools for interacting with files and CYFR components."
    ]

    # MCP tools list
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
          <span :if={@model != ""} class="text-xs text-gray-500 font-mono">
            {provider_label(@provider)} / {@model}
          </span>
        </div>
        <div class="flex items-center gap-2">
          <span :if={@model == ""} class="text-xs text-amber-400 animate-pulse">
            Please choose model →
          </span>
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
              <%= if @models_loading do %>
                <div class="w-full rounded-lg bg-gray-800 border border-gray-700 px-3 py-1.5 text-sm text-gray-500 flex items-center gap-2">
                  <div class="w-3 h-3 border-2 border-gray-600 border-t-blue-400 rounded-full animate-spin" />
                  Loading providers...
                </div>
              <% else %>
                <select
                  name="provider"
                  class="w-full rounded-lg bg-gray-800 border border-gray-700 px-3 py-1.5 text-sm text-white focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
                >
                  <%= for p <- @providers do %>
                    <option value={p} selected={p == @settings_provider}>{provider_label(p)}</option>
                  <% end %>
                </select>
              <% end %>
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
          <div id={"msg-#{idx}"} class="space-y-1">
            <!-- Role label -->
            <div class="flex items-center gap-2">
              <span class={role_label_class(msg.role)}>
                {role_label(msg.role)}
              </span>
              <span :if={msg[:turns] && (!msg[:tool_activity] || msg[:tool_activity] == [])} class="text-xs text-gray-600">
                {msg.turns} turn(s)
              </span>
            </div>

            <!-- Tool activity (collapsible) -->
            <%= if msg.role == "assistant" && msg[:tool_activity] && msg[:tool_activity] != [] do %>
              <details class="bg-gray-900 rounded-lg border border-gray-800">
                <summary class="px-4 py-2 text-xs text-gray-500 cursor-pointer hover:text-gray-400 select-none">
                  {length(msg.tool_activity)} tool call(s)
                </summary>
                <div class="px-4 pb-2 space-y-1">
                  <%= for {entry, ti} <- Enum.with_index(msg.tool_activity) do %>
                    <div id={"msg-#{idx}-tool-#{ti}"} class="flex items-start gap-2 text-xs font-mono">
                      <span class="text-green-500 shrink-0">&#10003;</span>
                      <span class="text-gray-500">{entry.tool}</span>
                      <span :if={entry.preview} class="text-gray-600 truncate max-w-md">{String.slice(entry.preview, 0..80)}</span>
                    </div>
                  <% end %>
                </div>
              </details>
            <% end %>

            <!-- Content -->
            <%= if msg.role == "assistant" do %>
              <div
                id={"md-#{idx}"}
                phx-hook="MarkdownContent"
                data-raw-content={msg.content}
                class={"#{content_class(msg.role)} prose prose-invert prose-sm max-w-none"}
              >
                <pre class="whitespace-pre-wrap break-words text-sm font-sans">{msg.content}</pre>
              </div>
            <% else %>
              <div class={content_class(msg.role)}>
                <pre class="whitespace-pre-wrap break-words text-sm font-sans">{msg.content}</pre>
              </div>
            <% end %>
          </div>
        <% end %>

        <!-- Progress indicator with tool activity and streaming text -->
        <div :if={@running} class="flex items-start gap-3">
          <div class="flex-1">
            <div class="flex items-center gap-2 mb-1">
              <span class="text-xs font-medium text-blue-400">Agent</span>
              <div class="flex items-center gap-1">
                <div class="w-1.5 h-1.5 rounded-full bg-blue-400 animate-pulse" />
                <span class="text-xs text-gray-500">{@progress}</span>
              </div>
            </div>

            <!-- Tool activity log -->
            <div :if={@tool_activity != []} class="bg-gray-900 rounded-lg border border-gray-800 mt-1 px-4 py-2 space-y-1">
              <%= for {entry, i} <- Enum.with_index(@tool_activity) do %>
                <div id={"tool-#{i}"} class="flex items-start gap-2 text-xs font-mono">
                  <%= if entry.status == :running do %>
                    <span class="text-blue-400 shrink-0 mt-0.5">
                      <svg class="w-3 h-3 animate-spin" viewBox="0 0 24 24" fill="none">
                        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
                        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
                      </svg>
                    </span>
                    <span class="text-gray-400">{entry.tool}</span>
                  <% else %>
                    <span class="text-green-500 shrink-0">&#10003;</span>
                    <span class="text-gray-500">{entry.tool}</span>
                    <span :if={entry.preview} class="text-gray-600 truncate max-w-md">{String.slice(entry.preview, 0..80)}</span>
                  <% end %>
                </div>
              <% end %>
            </div>

            <!-- Streaming text -->
            <div
              :if={@streaming_text != ""}
              id="streaming-md"
              phx-hook="StreamingMarkdown"
              phx-update="ignore"
              class="bg-gray-900 rounded-lg px-4 py-3 text-gray-300 border border-gray-800 mt-1 prose prose-invert prose-sm max-w-none"
            >
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

          <div class="space-y-1 mb-3">
            <%= for issue <- @setup_issues do %>
              <div class="flex items-center gap-2 rounded px-3 py-2 text-sm bg-gray-800 border border-gray-700">
                <span class="font-mono text-xs text-amber-300">{issue_label(issue)}</span>
                <span :if={issue["description"]} class="text-gray-500 text-xs">{issue["description"]}</span>
              </div>
            <% end %>
          </div>

          <div class="flex items-center justify-between">
            <code class="text-xs text-gray-500">{@setup_command}</code>
            <.link
              :if={@setup_component_ref}
              navigate={~p"/components/#{@setup_component_ref}"}
              class="px-3 py-1.5 text-xs font-medium rounded-md bg-amber-700 text-white hover:bg-amber-600"
            >
              Configure Component
            </.link>
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
