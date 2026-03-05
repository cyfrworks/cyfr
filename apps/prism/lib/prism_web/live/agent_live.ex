defmodule PrismWeb.AgentLive do
  use PrismWeb, :live_view

  @list_models_ref "formula:local.list-models:0.5.0"
  @agent_ref "formula:local.agent:0.9.2"
  @default_provider "claude"
  @default_max_turns 30

  @conversations_path ["data", "agent_conversations"]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Emissary.PubSub, "prism:executions")
      send(self(), :load_conversations)
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
     |> assign(:stream_segments, [])
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
     |> assign(:pending_model, nil)
     |> assign(:cancel_requested, false)
     |> assign(:conversation_id, nil)
     |> assign(:conversations, [])
     |> assign(:conversations_open, false)
     |> assign(:background_executions, %{})
     |> assign(:token_usage, %{input: 0, output: 0})
     |> assign(:started_at, nil)}
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

        # Generate conversation ID if new conversation
        conversation_id = socket.assigns.conversation_id || generate_conversation_id()

        {:noreply,
         socket
         |> assign(:messages, messages)
         |> assign(:input, "")
         |> assign(:running, true)
         |> assign(:streaming_text, "")
         |> assign(:stream_segments, [])
         |> assign(:tool_activity, [])
         |> assign(:current_turn, 0)
         |> assign(:progress, "Starting...")
         |> assign(:cancel_requested, false)
         |> assign(:conversation_id, conversation_id)
         |> assign(:token_usage, %{input: 0, output: 0})
         |> assign(:started_at, nil)
         |> persist_messages()}
    end
  end

  def handle_event("submit", _params, socket), do: {:noreply, socket}

  def handle_event("stop", _params, socket) do
    cond do
      # Execution already started — cancel it
      socket.assigns.running && socket.assigns.current_execution_id ->
        exec_id = socket.assigns.current_execution_id
        Opus.ExecutionEventBuffer.unsubscribe(exec_id)

        Task.start(fn ->
          ctx = socket.assigns.context
          Opus.cancel(ctx, exec_id)
        end)

        socket = maybe_save_partial_as_message(socket)

        {:noreply,
         socket
         |> assign(:running, false)
         |> assign(:progress, nil)
         |> assign(:streaming_text, "")
         |> assign(:stream_segments, [])
         |> assign(:tool_activity, [])
         |> assign(:current_execution_id, nil)
         |> assign(:cancel_requested, false)
         |> persist_messages()
         |> push_event("clear_partial", %{})}

      # Running but execution_id hasn't arrived yet — flag for cancellation
      socket.assigns.running ->
        {:noreply,
         socket
         |> assign(:cancel_requested, true)
         |> assign(:progress, "Cancelling...")}

      # Not running — no-op
      true ->
        {:noreply, socket}
    end
  end

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
        base = if msg["duration_seconds"], do: Map.put(base, :duration_seconds, msg["duration_seconds"]), else: base
        base = if msg["token_usage"], do: Map.put(base, :token_usage, %{input: msg["token_usage"]["input"] || 0, output: msg["token_usage"]["output"] || 0}), else: base

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

  def handle_event("new_chat", _params, socket) do
    socket =
      if socket.assigns.running && socket.assigns.current_execution_id do
        # Move current execution to background
        exec_id = socket.assigns.current_execution_id
        conv_id = socket.assigns.conversation_id
        bg = Map.put(socket.assigns.background_executions, exec_id, conv_id)

        # Save current state as partial before switching
        socket
        |> save_conversation_partial()
        |> assign(:background_executions, bg)
        |> assign(:current_execution_id, nil)
        |> assign(:running, false)
        |> assign(:progress, nil)
        |> assign(:streaming_text, "")
        |> assign(:stream_segments, [])
        |> assign(:tool_activity, [])
      else
        socket
      end

    {:noreply,
     socket
     |> assign(:messages, [])
     |> assign(:conversation_history, [])
     |> assign(:conversation_id, nil)
     |> assign(:expanded_tools, MapSet.new())
     |> assign(:conversations_open, false)
     |> push_event("clear_partial", %{})}
  end

  def handle_event("toggle_conversations", _params, socket) do
    opening = !socket.assigns.conversations_open

    socket =
      if opening do
        load_conversations(socket)
        |> assign(:conversations_open, true)
      else
        assign(socket, :conversations_open, false)
      end

    {:noreply, socket}
  end

  def handle_event("load_conversation", %{"id" => id}, socket) do
    socket =
      if socket.assigns.running && socket.assigns.current_execution_id do
        # Move current execution to background
        exec_id = socket.assigns.current_execution_id
        conv_id = socket.assigns.conversation_id
        bg = Map.put(socket.assigns.background_executions, exec_id, conv_id)

        socket
        |> save_conversation_partial()
        |> assign(:background_executions, bg)
        |> assign(:current_execution_id, nil)
        |> assign(:running, false)
        |> assign(:progress, nil)
        |> assign(:streaming_text, "")
        |> assign(:stream_segments, [])
        |> assign(:tool_activity, [])
      else
        socket
      end

    # Check if this conversation has a background execution
    {bg_exec_id, bg_execs} =
      Enum.find_value(socket.assigns.background_executions, {nil, socket.assigns.background_executions}, fn {exec_id, conv_id} ->
        if conv_id == id, do: {exec_id, Map.delete(socket.assigns.background_executions, exec_id)}
      end)

    socket =
      socket
      |> load_conversation(id)
      |> assign(:conversations_open, false)
      |> assign(:background_executions, bg_execs)

    # Resume background execution if one exists for this conversation
    socket =
      if bg_exec_id do
        socket
        |> assign(:current_execution_id, bg_exec_id)
        |> assign(:running, true)
        |> assign(:progress, "Resuming...")
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("delete_conversation", %{"id" => id}, socket) do
    ctx = socket.assigns.context
    path = @conversations_path ++ ["#{id}.json"]
    Task.start(fn -> Arca.delete(ctx, path) end)

    conversations = Enum.reject(socket.assigns.conversations, &(&1.id == id))

    socket =
      if socket.assigns.conversation_id == id do
        socket
        |> assign(:messages, [])
        |> assign(:conversation_history, [])
        |> assign(:conversation_id, nil)
        |> assign(:expanded_tools, MapSet.new())
        |> push_event("clear_partial", %{})
      else
        socket
      end

    {:noreply, assign(socket, :conversations, conversations)}
  end

  def handle_event("clear_conversation", _params, socket) do
    {:noreply,
     socket
     |> assign(:messages, [])
     |> assign(:conversation_history, [])
     |> assign(:conversation_id, nil)
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
    if socket.assigns.cancel_requested do
      # User clicked Stop before execution_id arrived — cancel immediately
      Task.start(fn ->
        ctx = socket.assigns.context
        Opus.cancel(ctx, execution_id)
      end)

      {:noreply,
       socket
       |> assign(:running, false)
       |> assign(:progress, nil)
       |> assign(:current_execution_id, nil)
       |> assign(:cancel_requested, false)}
    else
      if connected?(socket) do
        Opus.ExecutionEventBuffer.subscribe(execution_id)
      end

      {:noreply,
       socket
       |> assign(:current_execution_id, execution_id)
       |> assign(:started_at, DateTime.utc_now())
       |> assign(:progress, "Thinking...")}
    end
  end

  # Execution events from the formula's emit() calls
  def handle_info({:execution_event, %{type: "emit", data: data, execution_id: exec_id}}, socket) do
    case route_execution_event(socket, exec_id) do
      :current -> handle_emit_event(socket, data)
      :background -> handle_background_emit(socket, exec_id, data)
      :ignore -> {:noreply, socket}
    end
  end

  def handle_info({:execution_event, %{type: "emit", data: _data}}, %{assigns: %{running: false}} = socket) do
    {:noreply, socket}
  end

  def handle_info({:execution_event, %{type: "emit", data: data}}, socket) do
    handle_emit_event(socket, data)
  end

  # Terminal event: execution completed (with execution_id for routing)
  def handle_info({:execution_event, %{type: "complete", execution_id: exec_id}}, socket) do
    case route_execution_event(socket, exec_id) do
      :background ->
        handle_background_complete(socket, exec_id)
      :ignore ->
        {:noreply, socket}
      :current ->
        handle_current_complete(socket)
    end
  end

  # Terminal event: execution completed (without execution_id — legacy)
  def handle_info({:execution_event, %{type: "complete"}}, %{assigns: %{running: false}} = socket) do
    {:noreply, socket}
  end

  def handle_info({:execution_event, %{type: "complete"}}, socket) do
    handle_current_complete(socket)
  end

  # Terminal event: execution error (with execution_id for routing)
  def handle_info({:execution_event, %{type: "error", execution_id: exec_id, data: data}}, socket) do
    case route_execution_event(socket, exec_id) do
      :background ->
        handle_background_complete(socket, exec_id)
      :ignore ->
        {:noreply, socket}
      :current ->
        handle_current_error(socket, data)
    end
  end

  # Terminal event: execution error (without execution_id — legacy)
  def handle_info({:execution_event, %{type: "error"}}, %{assigns: %{running: false}} = socket) do
    {:noreply, socket}
  end

  def handle_info({:execution_event, %{type: "error", data: data}}, socket) do
    handle_current_error(socket, data)
  end

  # Legacy: agent_result from run (fallback if complete event didn't carry content)
  def handle_info({:agent_result, {:ok, result}}, socket) do
    {content, conversation_history, turns} = parse_agent_result(result)

    # Only add message if we didn't already add one from streaming
    if socket.assigns.running do
      segments = socket.assigns.stream_segments
      duration_seconds = compute_duration(socket.assigns.started_at)
      usage = socket.assigns.token_usage

      assistant_msg = %{
        role: "assistant",
        content: content,
        turns: turns,
        timestamp: DateTime.utc_now(),
        duration_seconds: duration_seconds,
        token_usage: usage
      }

      assistant_msg =
        if segments != [], do: Map.put(assistant_msg, :segments, segments), else: assistant_msg

      {:noreply,
       socket
       |> assign(:messages, socket.assigns.messages ++ [assistant_msg])
       |> assign(:conversation_history, conversation_history)
       |> assign(:running, false)
       |> assign(:progress, nil)
       |> assign(:streaming_text, "")
       |> assign(:stream_segments, [])
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
     |> assign(:stream_segments, [])
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

  def handle_info(:load_conversations, socket) do
    {:noreply, load_conversations(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Emit event dispatch
  # ---------------------------------------------------------------------------

  defp handle_emit_event(socket, data) do
    kind = data["kind"] || data[:kind]

    socket =
      case kind do
        "turn_start" ->
          turn = data["turn"] || data[:turn] || 0
          new_segment = %{turn: turn, tools: [], text: ""}
          socket
          |> assign(:current_turn, turn)
          |> assign(:stream_segments, socket.assigns.stream_segments ++ [new_segment])
          |> assign(:progress, "Turn #{turn}...")

        "text_delta" ->
          content = data["content"] || data[:content] || ""
          new_text = socket.assigns.streaming_text <> content
          segments = update_current_segment_text(socket.assigns.stream_segments, content)
          socket
          |> assign(:streaming_text, new_text)
          |> assign(:stream_segments, segments)
          |> assign(:progress, "Writing...")
          |> push_event("streaming_delta", %{text: current_segment_text(segments)})
          |> push_event("save_partial", %{text: new_text})
          |> push_event("scroll_bottom", %{})

        "tool_use" ->
          tool = data["tool"] || data[:tool] || "tool"
          turn = data["turn"] || data[:turn] || socket.assigns.current_turn
          input = data["input"] || data[:input]
          entry = %{tool: tool, status: :running, turn: turn, preview: nil, input: input}
          segments = add_tool_to_current_segment(socket.assigns.stream_segments, entry)

          socket
          |> assign(:tool_activity, socket.assigns.tool_activity ++ [entry])
          |> assign(:stream_segments, segments)
          |> assign(:progress, "Using #{tool}...")
          |> push_event("scroll_bottom", %{})

        "tool_result" ->
          tool = data["tool"] || data[:tool] || "tool"
          preview = data["preview"] || data[:preview]

          activity = update_last_running(socket.assigns.tool_activity, tool, preview)
          segments = update_tool_in_segments(socket.assigns.stream_segments, tool, preview)

          socket
          |> assign(:tool_activity, activity)
          |> assign(:stream_segments, segments)
          |> assign(:progress, "#{tool} completed")

        "usage" ->
          input = data["input_tokens"] || data[:input_tokens] || 0
          output = data["output_tokens"] || data[:output_tokens] || 0
          current = socket.assigns.token_usage
          assign(socket, :token_usage, %{input: current.input + input, output: current.output + output})

        "conversation_complete" ->
          messages = data["messages"] || data[:messages] || []
          assign(socket, :conversation_history, messages)

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

  defp maybe_save_partial_as_message(socket) do
    streaming = socket.assigns.streaming_text

    if streaming != "" do
      activity = mark_tools_done(socket.assigns.tool_activity)

      msg = %{
        role: "assistant",
        content: streaming <> "\n\n_(cancelled)_",
        turns: socket.assigns.current_turn,
        timestamp: DateTime.utc_now()
      }

      msg = if activity != [], do: Map.put(msg, :tool_activity, activity), else: msg

      assign(socket, :messages, socket.assigns.messages ++ [msg])
    else
      socket
    end
  end

  defp mark_tools_done(activity) do
    Enum.map(activity, fn
      %{status: :running} = entry -> %{entry | status: :cancelled}
      entry -> entry
    end)
  end

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
  # Stream segment helpers
  # ---------------------------------------------------------------------------

  defp update_current_segment_text([], _content), do: []
  defp update_current_segment_text(segments, content) do
    List.update_at(segments, -1, fn seg ->
      %{seg | text: seg.text <> content}
    end)
  end

  defp current_segment_text([]), do: ""
  defp current_segment_text(segments) do
    List.last(segments).text
  end

  defp add_tool_to_current_segment([], entry) do
    [%{turn: entry.turn, tools: [entry], text: ""}]
  end
  defp add_tool_to_current_segment(segments, entry) do
    List.update_at(segments, -1, fn seg ->
      %{seg | tools: seg.tools ++ [entry]}
    end)
  end

  defp update_tool_in_segments(segments, tool, preview) do
    # Find last segment with a running tool matching the name
    idx =
      segments
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {seg, i} ->
        if Enum.any?(seg.tools, &(&1.tool == tool && &1.status == :running)), do: i
      end)

    if idx do
      List.update_at(segments, idx, fn seg ->
        tools = update_last_running(seg.tools, tool, preview)
        %{seg | tools: tools}
      end)
    else
      segments
    end
  end

  # ---------------------------------------------------------------------------
  # Execution event routing
  # ---------------------------------------------------------------------------

  defp route_execution_event(socket, execution_id) do
    cond do
      socket.assigns.current_execution_id == execution_id -> :current
      Map.has_key?(socket.assigns.background_executions, execution_id) -> :background
      true -> :ignore
    end
  end

  defp handle_background_emit(socket, _exec_id, _data) do
    # Background executions: we don't update UI, just let them run.
    # The conversation file will be updated on completion.
    {:noreply, socket}
  end

  defp handle_background_complete(socket, exec_id) do
    Opus.ExecutionEventBuffer.unsubscribe(exec_id)
    bg = Map.delete(socket.assigns.background_executions, exec_id)

    # Update conversation list status
    conversations =
      Enum.map(socket.assigns.conversations, fn conv ->
        bg_conv_id = socket.assigns.background_executions[exec_id]
        if conv.id == bg_conv_id, do: %{conv | status: :idle}, else: conv
      end)

    {:noreply,
     socket
     |> assign(:background_executions, bg)
     |> assign(:conversations, conversations)}
  end

  defp handle_current_complete(socket) do
    exec_id = socket.assigns.current_execution_id
    if exec_id, do: Opus.ExecutionEventBuffer.unsubscribe(exec_id)

    streaming = socket.assigns.streaming_text

    if streaming != "" do
      segments = socket.assigns.stream_segments

      duration_seconds = compute_duration(socket.assigns.started_at)
      usage = socket.assigns.token_usage

      assistant_msg = %{
        role: "assistant",
        content: streaming,
        turns: socket.assigns.current_turn,
        timestamp: DateTime.utc_now(),
        duration_seconds: duration_seconds,
        token_usage: usage
      }

      assistant_msg =
        if segments != [], do: Map.put(assistant_msg, :segments, segments), else: assistant_msg

      {:noreply,
       socket
       |> assign(:messages, socket.assigns.messages ++ [assistant_msg])
       |> assign(:running, false)
       |> assign(:progress, nil)
       |> assign(:streaming_text, "")
       |> assign(:stream_segments, [])
       |> assign(:tool_activity, [])
       |> assign(:current_execution_id, nil)
       |> assign(:started_at, nil)
       |> persist_messages()
       |> push_event("clear_partial", %{})
       |> push_event("scroll_bottom", %{})}
    else
      {:noreply,
       socket
       |> assign(:current_execution_id, nil)}
    end
  end

  defp handle_current_error(socket, data) do
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
     |> assign(:stream_segments, [])
     |> assign(:tool_activity, [])
     |> assign(:current_execution_id, nil)
     |> persist_messages()
     |> push_event("clear_partial", %{})}
  end

  # ---------------------------------------------------------------------------
  # Conversation persistence (Arca storage)
  # ---------------------------------------------------------------------------

  defp generate_conversation_id do
    "conv_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp persist_messages(socket) do
    socket
    |> save_conversation()
    |> push_event("save_preferences", %{
      provider: socket.assigns.provider,
      model: socket.assigns.model
    })
  end

  defp save_conversation(socket) do
    conv_id = socket.assigns.conversation_id
    messages = socket.assigns.messages

    if conv_id && messages != [] do
      first_user_msg =
        Enum.find_value(messages, "New conversation", fn
          %{role: "user", content: c} -> String.slice(c, 0..80)
          _ -> nil
        end)

      conv_data = %{
        "id" => conv_id,
        "title" => first_user_msg,
        "created_at" => DateTime.to_iso8601(List.first(messages).timestamp),
        "updated_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "provider" => socket.assigns.provider,
        "model" => socket.assigns.model,
        "messages" => serialize_messages(messages),
        "conversation_history" => socket.assigns.conversation_history
      }

      ctx = socket.assigns.context
      path = @conversations_path ++ ["#{conv_id}.json"]

      Task.start(fn ->
        Arca.put_json(ctx, path, conv_data)
      end)

      # Update conversations list in-place
      entry = %{id: conv_id, title: first_user_msg, updated_at: DateTime.utc_now(), status: :idle}
      conversations = update_conversation_entry(socket.assigns.conversations, entry)
      assign(socket, :conversations, conversations)
    else
      socket
    end
  end

  defp save_conversation_partial(socket) do
    conv_id = socket.assigns.conversation_id
    if conv_id && socket.assigns.messages != [] do
      save_conversation(socket)
    else
      socket
    end
  end

  defp serialize_messages(messages) do
    Enum.map(messages, fn msg ->
      base = %{
        "role" => msg.role,
        "content" => msg.content,
        "timestamp" => DateTime.to_iso8601(msg.timestamp)
      }

      base = if Map.has_key?(msg, :turns), do: Map.put(base, "turns", msg.turns), else: base
      base = if msg[:duration_seconds], do: Map.put(base, "duration_seconds", msg.duration_seconds), else: base
      base = if msg[:token_usage], do: Map.put(base, "token_usage", %{"input" => msg.token_usage.input, "output" => msg.token_usage.output}), else: base

      base =
        if Map.has_key?(msg, :segments) && msg.segments != [] do
          serialized_segments =
            Enum.map(msg.segments, fn seg ->
              %{
                "turn" => seg.turn,
                "text" => seg.text,
                "tools" => Enum.map(seg.tools, fn t ->
                  tool_map = %{"tool" => t.tool, "status" => to_string(t.status), "preview" => t.preview}
                  if Map.has_key?(t, :input) && t.input, do: Map.put(tool_map, "input", t.input), else: tool_map
                end)
              }
            end)
          Map.put(base, "segments", serialized_segments)
        else
          base
        end

      if Map.has_key?(msg, :tool_activity) && msg[:tool_activity] != [] do
        activity = Enum.map(msg.tool_activity, fn e ->
          %{"tool" => e.tool, "status" => to_string(e.status), "preview" => e.preview}
        end)
        Map.put(base, "tool_activity", activity)
      else
        base
      end
    end)
  end

  defp update_conversation_entry(conversations, entry) do
    if Enum.any?(conversations, &(&1.id == entry.id)) do
      Enum.map(conversations, fn conv ->
        if conv.id == entry.id, do: entry, else: conv
      end)
    else
      [entry | conversations]
    end
  end

  defp load_conversations(socket) do
    ctx = socket.assigns.context

    case Arca.list(ctx, @conversations_path) do
      {:ok, entries} ->
        conversations =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.map(fn filename ->
            path = @conversations_path ++ [filename]
            case Arca.get_json(ctx, path) do
              {:ok, data} ->
                bg_status =
                  if Enum.any?(socket.assigns.background_executions, fn {_exec, conv} ->
                    conv == data["id"]
                  end), do: :running, else: :idle

                %{
                  id: data["id"],
                  title: data["title"] || "Untitled",
                  updated_at: parse_timestamp(data["updated_at"]),
                  status: bg_status
                }
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

        assign(socket, :conversations, conversations)

      {:error, _} ->
        assign(socket, :conversations, [])
    end
  end

  defp load_conversation(socket, id) do
    ctx = socket.assigns.context
    path = @conversations_path ++ ["#{id}.json"]

    case Arca.get_json(ctx, path) do
      {:ok, data} ->
        messages = deserialize_messages(data["messages"] || [])
        conversation_history = data["conversation_history"] || []

        socket
        |> assign(:messages, messages)
        |> assign(:conversation_id, id)
        |> assign(:conversation_history, conversation_history)
        |> assign(:expanded_tools, MapSet.new())

      {:error, _} ->
        put_flash(socket, :error, "Failed to load conversation")
    end
  end

  defp deserialize_messages(raw_messages) do
    Enum.map(raw_messages, fn msg ->
      base = %{
        role: msg["role"] || "user",
        content: msg["content"] || "",
        timestamp: parse_timestamp(msg["timestamp"])
      }

      base = if msg["turns"], do: Map.put(base, :turns, msg["turns"]), else: base
      base = if msg["duration_seconds"], do: Map.put(base, :duration_seconds, msg["duration_seconds"]), else: base
      base = if msg["token_usage"], do: Map.put(base, :token_usage, %{input: msg["token_usage"]["input"] || 0, output: msg["token_usage"]["output"] || 0}), else: base

      base =
        if is_list(msg["segments"]) && msg["segments"] != [] do
          segments =
            Enum.map(msg["segments"], fn seg ->
              %{
                turn: seg["turn"] || 0,
                text: seg["text"] || "",
                tools: Enum.map(seg["tools"] || [], fn t ->
                  tool_map = %{
                    tool: t["tool"] || "tool",
                    status: String.to_existing_atom(t["status"] || "done"),
                    preview: t["preview"]
                  }
                  if t["input"], do: Map.put(tool_map, :input, t["input"]), else: tool_map
                end)
              }
            end)
          Map.put(base, :segments, segments)
        else
          base
        end

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
  end

  defp compute_duration(nil), do: nil
  defp compute_duration(started_at) do
    DateTime.diff(DateTime.utc_now(), started_at, :second)
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
    case fetch_guide(ctx, "agent-guide") do
      {:ok, guide} -> guide
      _ -> "You are an agent running inside CYFR, a governed computation platform."
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
          <span :if={@model != ""} class="text-xs text-gray-500 font-mono">
            {provider_label(@provider)} / {@model}
          </span>
        </div>
        <div class="flex items-center gap-2">
          <span :if={@model == ""} class="text-xs text-amber-400 animate-pulse">
            Please choose model →
          </span>
          <button
            phx-click="new_chat"
            class="px-3 py-1.5 text-xs font-medium rounded-md bg-gray-800 text-gray-400 border border-gray-700 hover:bg-gray-700 hover:text-gray-300"
          >
            New Chat
          </button>
          <div class="relative">
            <button
              phx-click="toggle_conversations"
              class={"px-3 py-1.5 text-xs font-medium rounded-md border #{if @conversations_open, do: "bg-blue-900 text-blue-300 border-blue-700", else: "bg-gray-800 text-gray-400 border-gray-700 hover:bg-gray-700"}"}
            >
              History
              <span :if={running_background_count(@background_executions) > 0} class="ml-1 inline-block w-1.5 h-1.5 rounded-full bg-blue-400 animate-pulse" />
            </button>
            <div
              :if={@conversations_open}
              class="absolute right-0 top-full mt-1 w-80 max-h-96 overflow-y-auto bg-gray-800 border border-gray-700 rounded-lg shadow-xl z-50"
            >
              <div :if={@conversations == []} class="px-4 py-3 text-xs text-gray-500">
                No saved conversations
              </div>
              <%= for conv <- @conversations do %>
                <div class={"flex items-center border-b border-gray-700 last:border-0 hover:bg-gray-700 transition-colors #{if conv.id == @conversation_id, do: "bg-gray-700/50"}"}>
                  <button
                    phx-click="load_conversation"
                    phx-value-id={conv.id}
                    class="flex-1 text-left px-4 py-2.5 min-w-0"
                  >
                    <div class="flex items-center gap-2">
                      <span :if={conv.status == :running} class="shrink-0 w-1.5 h-1.5 rounded-full bg-blue-400 animate-pulse" />
                      <span class="text-sm text-gray-300 truncate">{conv.title}</span>
                    </div>
                    <span class="text-xs text-gray-600">{relative_time(conv.updated_at)}</span>
                  </button>
                  <button
                    phx-click="delete_conversation"
                    phx-value-id={conv.id}
                    class="shrink-0 p-2 mr-1 text-gray-600 hover:text-red-400 transition-colors"
                    title="Delete conversation"
                  >
                    <svg class="w-3.5 h-3.5" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2">
                      <path d="M4 4l8 8M12 4l-8 8" />
                    </svg>
                  </button>
                </div>
              <% end %>
            </div>
          </div>
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
              <span :if={msg[:turns] || msg[:duration_seconds] || msg[:token_usage]} class="text-xs text-gray-600">
                {format_message_stats(msg)}
              </span>
            </div>

            <%= if msg.role == "assistant" && msg[:segments] && msg[:segments] != [] do %>
              <%
                all_tools = Enum.flat_map(msg.segments, & &1.tools)
                total_tools = length(all_tools)
                intermediate_segments = if length(msg.segments) > 1, do: Enum.slice(msg.segments, 0..-2//1), else: []
                has_thinking = Enum.any?(intermediate_segments, & &1.text != "")
                final_segment = List.last(msg.segments)
              %>
              <!-- Collapsed reasoning: tools + intermediate thinking -->
              <%= if total_tools > 0 || has_thinking do %>
                <details class="bg-gray-900 rounded-lg border border-gray-800">
                  <summary class="px-4 py-2 text-xs text-gray-500 cursor-pointer hover:text-gray-400 select-none">
                    <%= if total_tools > 0 do %>
                      {total_tools} tool call(s) across {msg[:turns] || length(msg.segments)} turn(s)
                    <% else %>
                      {length(msg.segments)} reasoning step(s)
                    <% end %>
                  </summary>
                  <div class="px-4 pb-3 space-y-2">
                    <%= for {seg, si} <- Enum.with_index(intermediate_segments) do %>
                      <!-- Thinking text for this turn -->
                      <%= if seg.text != "" do %>
                        <div
                          id={"msg-#{idx}-think-#{si}"}
                          phx-hook="MarkdownContent"
                          data-raw-content={seg.text}
                          class="text-xs text-gray-500 prose prose-invert prose-xs max-w-none border-l-2 border-gray-700 pl-3"
                        >
                          <pre class="whitespace-pre-wrap break-words text-xs font-sans">{seg.text}</pre>
                        </div>
                      <% end %>
                      <!-- Tools for this turn -->
                      <%= for {entry, ti} <- Enum.with_index(seg.tools) do %>
                        <.tool_entry_detail entry={entry} id={"msg-#{idx}-seg-#{si}-tool-#{ti}"} />
                      <% end %>
                    <% end %>
                    <!-- Final turn's tools (if any) go here too -->
                    <%= if final_segment do %>
                      <%= for {entry, ti} <- Enum.with_index(final_segment.tools) do %>
                        <.tool_entry_detail entry={entry} id={"msg-#{idx}-seg-final-tool-#{ti}"} />
                      <% end %>
                    <% end %>
                  </div>
                </details>
              <% end %>
              <!-- Final response text (only the last segment) -->
              <%= if final_segment && final_segment.text != "" do %>
                <div
                  id={"md-#{idx}-final"}
                  phx-hook="MarkdownContent"
                  data-raw-content={final_segment.text}
                  class={"#{content_class("assistant")} prose prose-invert prose-sm max-w-none"}
                >
                  <pre class="whitespace-pre-wrap break-words text-sm font-sans">{final_segment.text}</pre>
                </div>
              <% end %>
            <% else %>
              <!-- Legacy: tool_activity + single content block -->
              <%= if msg.role == "assistant" && msg[:tool_activity] && msg[:tool_activity] != [] do %>
                <details class="bg-gray-900 rounded-lg border border-gray-800">
                  <summary class="px-4 py-2 text-xs text-gray-500 cursor-pointer hover:text-gray-400 select-none">
                    {length(msg.tool_activity)} tool call(s)
                  </summary>
                  <div class="px-4 pb-2 space-y-1">
                    <%= for {entry, ti} <- Enum.with_index(msg.tool_activity) do %>
                      <div id={"msg-#{idx}-tool-#{ti}"} class="flex items-start gap-2 text-xs font-mono">
                        <%= if entry.status == :cancelled do %>
                          <span class="text-amber-500 shrink-0">&#10007;</span>
                          <span class="text-gray-500">{entry.tool}</span>
                        <% else %>
                          <span class="text-green-500 shrink-0">&#10003;</span>
                          <span class="text-gray-500">{entry.tool}</span>
                          <span :if={entry.preview} class="text-gray-600 truncate max-w-md">{String.slice(entry.preview, 0..80)}</span>
                        <% end %>
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
            <% end %>
          </div>
        <% end %>

        <!-- Progress indicator with streaming content -->
        <div :if={@running} class="flex items-start gap-3">
          <div class="flex-1">
            <div class="flex items-center gap-2 mb-1">
              <span class="text-xs font-medium text-blue-400">Agent</span>
              <div class="flex items-center gap-1">
                <div class="w-1.5 h-1.5 rounded-full bg-blue-400 animate-pulse" />
                <span class="text-xs text-gray-500">{streaming_progress(@stream_segments, @progress)}</span>
              </div>
              <span
                :if={@started_at}
                id="elapsed-timer"
                phx-hook="ElapsedTimer"
                data-started-at={DateTime.to_iso8601(@started_at)}
                class="text-xs text-gray-600 font-mono"
              />
              <span :if={@token_usage.input > 0 || @token_usage.output > 0} class="text-xs text-gray-600 font-mono">
                {format_tokens(@token_usage.input)} in / {format_tokens(@token_usage.output)} out
              </span>
            </div>

            <%
              past_segments = if length(@stream_segments) > 1, do: Enum.slice(@stream_segments, 0..-2//1), else: []
              current_segment = List.last(@stream_segments)
              past_tools = Enum.flat_map(past_segments, & &1.tools)
              has_past_thinking = Enum.any?(past_segments, & &1.text != "")
            %>

            <!-- Collapsed past reasoning (tools + thinking steps) -->
            <%= if past_tools != [] || has_past_thinking do %>
              <details class="bg-gray-900 rounded-lg border border-gray-800 mt-1">
                <summary class="px-4 py-1.5 text-xs text-gray-600 cursor-pointer hover:text-gray-500 select-none">
                  {length(past_segments)} previous step(s), {length(past_tools)} tool call(s)
                </summary>
                <div class="px-4 pb-3 space-y-2">
                  <%= for {seg, si} <- Enum.with_index(past_segments) do %>
                    <%= if seg.text != "" do %>
                      <div
                        id={"past-think-#{si}"}
                        phx-hook="MarkdownContent"
                        data-raw-content={seg.text}
                        class="text-xs text-gray-500 prose prose-invert prose-xs max-w-none border-l-2 border-gray-700 pl-3"
                      >
                        <pre class="whitespace-pre-wrap break-words text-xs font-sans">{seg.text}</pre>
                      </div>
                    <% end %>
                    <%= for {entry, ti} <- Enum.with_index(seg.tools) do %>
                      <div id={"past-tool-#{si}-#{ti}"} class="flex items-start gap-2 text-xs font-mono">
                        <span class="text-green-500 shrink-0">&#10003;</span>
                        <span class="text-gray-500">{entry.tool}</span>
                        <span :if={entry.preview} class="text-gray-600 truncate max-w-md">{String.slice(entry.preview, 0..80)}</span>
                      </div>
                    <% end %>
                  <% end %>
                </div>
              </details>
            <% end %>

            <!-- Current segment: active tools inline -->
            <%= if current_segment && current_segment.tools != [] do %>
              <div class="mt-1 space-y-0.5">
                <%= for {entry, ti} <- Enum.with_index(current_segment.tools) do %>
                  <div id={"cur-tool-#{ti}"} class="flex items-center gap-2 text-xs font-mono text-gray-500 px-1">
                    <%= if entry.status == :running do %>
                      <svg class="w-3 h-3 animate-spin text-blue-400 shrink-0" viewBox="0 0 24 24" fill="none">
                        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
                        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
                      </svg>
                      <span class="text-gray-400">{entry.tool}</span>
                    <% else %>
                      <span class="text-green-500 shrink-0">&#10003;</span>
                      <span class="text-gray-600">{entry.tool}</span>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>

            <!-- Current segment: streaming text -->
            <%= if current_segment && current_segment.text != "" do %>
              <div
                id={"streaming-md-#{length(@stream_segments) - 1}"}
                phx-hook="StreamingMarkdown"
                phx-update="ignore"
                class="bg-gray-900 rounded-lg px-4 py-3 text-gray-300 border border-gray-800 mt-1 prose prose-invert prose-sm max-w-none"
              >
                <pre class="whitespace-pre-wrap break-words text-sm font-sans">{current_segment.text}</pre>
              </div>
            <% end %>
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
          <%= if @running do %>
            <button
              type="button"
              phx-click="stop"
              class="inline-flex items-center justify-center gap-2 rounded-lg px-4 py-2 text-sm font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-offset-gray-900 bg-red-600 text-white hover:bg-red-500 focus:ring-red-500"
            >
              <svg class="w-4 h-4" viewBox="0 0 16 16" fill="currentColor">
                <rect x="3" y="3" width="10" height="10" rx="1" />
              </svg>
              Stop
            </button>
          <% else %>
            <button
              type="submit"
              disabled={@input == "" || @model == ""}
              class="inline-flex items-center justify-center gap-2 rounded-lg px-4 py-2 text-sm font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-offset-gray-900 bg-blue-600 text-white hover:bg-blue-500 focus:ring-blue-500 disabled:opacity-50 disabled:cursor-not-allowed"
            >
              Send
            </button>
          <% end %>
        </form>
        <p class="text-xs text-gray-600 mt-2">
          Press Shift+Enter to send, Enter for new line
        </p>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Function components
  # ---------------------------------------------------------------------------

  defp tool_entry_detail(assigns) do
    ~H"""
    <div id={@id} class="text-xs font-mono">
      <div class="flex items-start gap-2">
        <%= if @entry.status == :cancelled do %>
          <span class="text-amber-500 shrink-0">&#10007;</span>
          <span class="text-gray-500">{@entry.tool}</span>
        <% else %>
          <span class="text-green-500 shrink-0">&#10003;</span>
          <span class="text-gray-500">{@entry.tool}</span>
        <% end %>
      </div>
      <div :if={@entry[:input] || @entry.preview} class="ml-5 mt-0.5 flex gap-3">
        <%= if @entry[:input] do %>
          <details>
            <summary class="text-gray-600 cursor-pointer hover:text-gray-500 select-none">input</summary>
            <pre class="text-gray-600 whitespace-pre-wrap break-all mt-0.5 text-[11px] max-h-40 overflow-y-auto">{format_tool_input(@entry.input)}</pre>
          </details>
        <% end %>
        <%= if @entry.preview do %>
          <details>
            <summary class="text-gray-600 cursor-pointer hover:text-gray-500 select-none">output</summary>
            <pre class="text-gray-600 whitespace-pre-wrap break-all mt-0.5 text-[11px] max-h-40 overflow-y-auto">{@entry.preview}</pre>
          </details>
        <% end %>
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

  defp running_background_count(bg_executions), do: map_size(bg_executions)

  defp streaming_progress(segments, fallback) do
    current = List.last(segments)

    if current do
      running_tool = Enum.find(current.tools, &(&1.status == :running))

      cond do
        running_tool -> "Using #{running_tool.tool}..."
        current.text != "" -> "Writing..."
        true -> fallback
      end
    else
      fallback
    end
  end

  defp format_message_stats(msg) do
    parts = []
    parts = if msg[:turns], do: parts ++ ["#{msg.turns} turn(s)"], else: parts
    parts = if msg[:duration_seconds], do: parts ++ [format_elapsed(msg.duration_seconds)], else: parts
    parts = if msg[:token_usage] && (msg.token_usage.input > 0 || msg.token_usage.output > 0),
      do: parts ++ ["#{format_tokens(msg.token_usage.input)} in / #{format_tokens(msg.token_usage.output)} out"],
      else: parts
    Enum.join(parts, " \u00b7 ")
  end

  defp format_elapsed(nil), do: ""
  defp format_elapsed(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_elapsed(seconds) do
    m = div(seconds, 60)
    s = rem(seconds, 60)
    "#{m}m #{s}s"
  end

  defp format_tokens(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp format_tokens(n), do: "#{n}"

  defp format_tool_input(input) when is_map(input) or is_list(input) do
    case Jason.encode(input, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(input)
    end
  end

  defp format_tool_input(input) when is_binary(input), do: input
  defp format_tool_input(input), do: inspect(input)
end
