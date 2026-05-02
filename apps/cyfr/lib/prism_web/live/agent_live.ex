defmodule PrismWeb.AgentLive do
  use PrismWeb, :live_view

  @compile {:no_warn_undefined, [Opus, Opus.ExecutionEventBuffer, Opus.ExecutionRecord]}

  require Logger

  @known_tool_statuses %{
    "done" => :done,
    "running" => :running,
    "error" => :error,
    "pending" => :pending,
    "cancelled" => :cancelled
  }

  @list_models_ref "formula:local.list-models"
  @agent_ref "formula:local.aqua"
  @default_provider "claude"

  @conversations_path ["data", "agent_conversations"]
  @index_path ["data", "agent_conversations", "index.json"]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ctx = socket.assigns[:context]
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.PubSub.topic("prism:executions", ctx))
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.PubSub.topic("prism:setup_complete", ctx))
      send(self(), :load_conversations)
    end

    {:ok,
     socket
     |> assign(:page_title, "Agent")
     |> assign(:active_nav, "agent")
     |> assign(:messages, [])
     |> assign(:conversation_history, [])
     |> assign(:input, "")
     |> assign(:running, false)
     |> assign(:progress, nil)
     |> assign(:streaming_text, "")
     |> assign(:stream_segments, [])
     |> assign(:current_turn, 0)
     |> assign(:current_execution_id, nil)
     |> assign(:editor_open, false)
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
     |> assign(:pending_setup, nil)
     |> assign(:pending_retry_input, nil)
     |> assign(:pending_provider, nil)
     |> assign(:pending_model, nil)
     |> assign(:cancel_requested, false)
     |> assign(:conversation_id, nil)
     |> assign(:conversations, [])
     |> assign(:conversations_open, false)
     |> assign(:background_executions, %{})
     |> assign(:token_usage, %{input: 0, output: 0})
     |> assign(:started_at, nil)
     |> assign(:active_orchestrator, nil)
     |> assign(:orchestrators, [])
     |> assign(:orchestrator_selector_open, false)
     |> assign(:editor_open, false)
     |> assign(:editor_agents, [])
     |> assign(:editor_editing_prompt, nil)
     |> assign(:editor_prompt_content, "")
     |> allow_upload(:attachments,
          accept: :any,
          max_entries: 10,
          max_file_size: 20_000_000,
          auto_upload: true
        )}
  end

  @impl true
  def terminate(_reason, socket) do
    should_save =
      (socket.assigns[:running] && socket.assigns[:current_execution_id]) ||
        socket.assigns[:setup_component_ref]

    if should_save && socket.assigns[:conversation_id] && socket.assigns.messages != [] do
      conv_data = build_conversation_data(socket)
      ctx = socket.assigns.context
      path = @conversations_path ++ ["#{socket.assigns.conversation_id}.json"]
      Arca.put_json(ctx, path, conv_data)

      # Update index synchronously (process is dying, can't use Task)
      case read_index(ctx) do
        {:ok, entries} ->
          index_entry = %{
            "id" => socket.assigns.conversation_id,
            "title" => conv_data["title"],
            "updated_at" => conv_data["updated_at"],
            "status" => if(conv_data["running"], do: "running", else: "idle")
          }

          write_index(ctx, upsert_index_entry(entries, index_entry))

        _ ->
          :ok
      end
    end

    :ok
  end

  @impl true
  def handle_event("submit", params, socket) do
    raw_message = params["message"] || ""
    message = String.trim(raw_message)
    has_uploads = socket.assigns.uploads.attachments.entries != []

    cond do
      message == "" and not has_uploads ->
        {:noreply, socket}

      socket.assigns.orchestrators == [] ->
        {:noreply, put_flash(socket, :error, "No orchestrators configured.")}

      true ->
        # Consume uploaded files and convert to base64 attachments
        attachments =
          try do
            consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
              data = File.read!(path) |> Base.encode64()

              {:ok,
               %{
                 "filename" => entry.client_name,
                 "media_type" => entry.client_type,
                 "data" => data
               }}
            end)
          rescue
            e ->
              Logger.warning("[AgentLive] Failed to consume uploads: #{inspect(e)}")
              []
          end

        attachment_meta =
          Enum.map(attachments, fn att ->
            %{filename: att["filename"], media_type: att["media_type"]}
          end)

        # Parse @mention → resolve to single orchestrator
        {parsed_task, mention_name} = parse_orchestrator_mention(message, socket.assigns.orchestrators)

        orchestrator =
          if mention_name do
            Enum.find(socket.assigns.orchestrators, &(&1["name"] == mention_name))
          else
            active = socket.assigns.active_orchestrator
            if active,
              do: Enum.find(socket.assigns.orchestrators, &(&1["name"] == active)),
              else: List.first(socket.assigns.orchestrators)
          end

        if orchestrator == nil do
          {:noreply, put_flash(socket, :error, "No orchestrator available.")}
        else
          orchestrator_name = orchestrator["name"]

          user_msg = %{
            role: "user",
            content: message,
            attachments: attachment_meta,
            orchestrator: orchestrator_name,
            timestamp: DateTime.utc_now()
          }

          messages = socket.assigns.messages ++ [user_msg]

          ctx = socket.assigns.context
          system_prompt = build_system_prompt(ctx, orchestrator_name)
          task_text = if(parsed_task == "", do: "Describe the attached file(s).", else: parsed_task)

          # Resolve versionless catalyst_ref to installed version
          resolved_catalyst =
            case Prism.AgentConfig.resolve_catalyst(ctx, orchestrator["catalyst_ref"]) do
              {:ok, ref} -> ref
              _ -> orchestrator["catalyst_ref"]
            end

          sub_agents =
            Prism.AgentConfig.sub_agent_definitions(
              ctx, orchestrator_name,
              resolved_catalyst, orchestrator["model"]
            )

          input = %{
            "task" => task_text,
            "system" => system_prompt,
            "sub_agents" => sub_agents,
            "catalyst_ref" => resolved_catalyst,
            "model" => orchestrator["model"]
          }

          input =
            if attachments != [],
              do: Map.put(input, "attachments", attachments),
              else: input

          input =
            if socket.assigns.conversation_history != [],
              do: Map.put(input, "messages",
                    Prism.ConversationCompactor.compact(socket.assigns.conversation_history)),
              else: input

          # Single execution — no parallel
          lv = self()

          Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
            result = Emissary.MCP.ToolRegistry.call(
              "execution", ctx,
              %{"action" => "run_stream", "reference" => @agent_ref, "input" => input}
            )

            case result do
              {:ok, %{execution_id: eid}} ->
                send(lv, {:stream_started, eid, orchestrator_name})

              {:ok, %{"execution_id" => eid}} ->
                send(lv, {:stream_started, eid, orchestrator_name})

              {:error, reason} ->
                Logger.warning("[AgentLive] Execution failed: #{inspect(reason)}")
                send(lv, {:stream_error, reason})
            end
          end)

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
           |> assign(:current_execution_id, nil)
           |> assign(:progress, "Starting...")
           |> assign(:cancel_requested, false)
           |> assign(:conversation_id, conversation_id)
           |> assign(:active_orchestrator, orchestrator_name)
           |> assign(:token_usage, %{input: 0, output: 0})
           |> assign(:started_at, nil)
           |> persist_messages()}
        end
    end
  end

  def handle_event("stop", _params, socket) do
    cond do
      # Execution already started — cancel it
      socket.assigns.running && socket.assigns.current_execution_id ->
        exec_id = socket.assigns.current_execution_id

        if opus_available?() do
          Opus.ExecutionEventBuffer.unsubscribe(exec_id, socket.assigns[:context])

          case Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
                 ctx = socket.assigns.context
                 Opus.cancel(ctx, exec_id)
               end) do
            {:ok, _pid} ->
              :ok

            {:error, reason} ->
              Logger.warning("[AgentLive] Failed to start cancel task: #{inspect(reason)}")
          end
        else
          Logger.warning("[AgentLive] Opus not available, cannot cancel execution #{exec_id}")
        end

        socket = maybe_save_partial_as_message(socket)

        # Preserve partial conversation history so the next message has context.
        # The formula emits conversation_complete only on normal completion —
        # on cancel, we build partial history from what we have.
        socket = assign(socket, :conversation_history, build_partial_history(socket))

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

  def handle_event("toggle_editor", _params, socket) do
    opening = !socket.assigns.editor_open

    socket =
      if opening do
        socket =
          socket
          |> assign(:editor_open, true)
          |> clear_flash()

        # Load agent details for editor
        socket =
          case handle_event("editor_load_agents", %{}, socket) do
            {:noreply, s} -> s
          end

        # Load all models for the agent editor dropdowns
        if socket.assigns.providers == [] do
          load_all_models(socket)
        else
          socket
        end
      else
        assign(socket, :editor_open, false)
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
    provider_changed = provider != socket.assigns.provider
    model_changed = model != socket.assigns.model

    # Start a new conversation when provider or model changes —
    # conversation history is in canonical format but switching models
    # means the context should be fresh
    socket =
      if provider_changed || model_changed do
        socket
        |> assign(:messages, [])
        |> assign(:conversation_history, [])
        |> assign(:conversation_id, nil)
        |> assign(:token_usage, %{input: 0, output: 0})
        |> assign(:streaming_text, "")
        |> assign(:stream_segments, [])
        |> assign(:tool_activity, [])
        |> assign(:expanded_tools, MapSet.new())
        |> push_event("clear_messages", %{})
      else
        socket
      end

    {:noreply,
     socket
     |> assign(:provider, provider)
     |> assign(:model, model)
     |> assign(:editor_open, false)
     |> clear_flash()
     |> push_event("save_preferences", %{provider: provider, model: model})}
  end

  def handle_event("cancel_settings", _params, socket) do
    {:noreply, assign(socket, :editor_open, false)}
  end

  # Backward compat: ignore old client restore_preferences events
  def handle_event("restore_preferences", _params, socket), do: {:noreply, socket}

  # --- Orchestrator selector ---

  def handle_event("toggle_orchestrator_selector", _params, socket) do
    {:noreply, assign(socket, :orchestrator_selector_open, !socket.assigns.orchestrator_selector_open)}
  end

  def handle_event("select_orchestrator", %{"name" => name}, socket) do
    orch = Enum.find(socket.assigns.orchestrators, &(&1["name"] == name))

    if orch do
      {:noreply,
       socket
       |> assign(:active_orchestrator, name)
       |> assign(:orchestrator_selector_open, false)}
    else
      {:noreply, socket}
    end
  end

  # --- Agent editor ---

  def handle_event("editor_set_model", %{"name" => agent_name, "provider" => "inherit"}, socket) do
    # Remove model + catalyst_ref → inherit from parent
    ctx = socket.assigns.context

    case Emissary.MCP.ToolRegistry.call("aqua", ctx, %{
           "action" => "update",
           "name" => agent_name,
           "model" => nil,
           "catalyst_ref" => nil
         }) do
      {:ok, _} ->
        send(self(), {:editor_refresh})
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Model update failed: #{inspect(reason)}")}
    end
  end

  def handle_event("editor_set_model", %{"name" => agent_name, "provider" => provider, "model" => model}, socket) do
    ctx = socket.assigns.context
    agent = Enum.find(socket.assigns.editor_agents, &(&1["name"] == agent_name))
    current_provider = detect_provider_from_ref(agent && agent["catalyst_ref"])
    provider_changed = provider != current_provider

    catalyst_ref = socket.assigns.catalyst_refs[provider]
    catalyst_ref_clean =
      if catalyst_ref, do: Regex.replace(~r/:\d+\.\d+\.\d+$/, catalyst_ref, ""), else: "catalyst:moonmoon69.#{provider}"

    # When provider changed, pick first model of new provider instead of stale old model
    resolved_model =
      if provider_changed do
        models = Map.get(socket.assigns.models_by_provider, provider, [])
        List.first(models) || model
      else
        model
      end

    case Emissary.MCP.ToolRegistry.call("aqua", ctx, %{
           "action" => "update",
           "name" => agent_name,
           "model" => resolved_model,
           "catalyst_ref" => catalyst_ref_clean
         }) do
      {:ok, _} ->
        send(self(), {:editor_refresh})
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Model update failed: #{inspect(reason)}")}
    end
  end

  def handle_event("editor_create_agent", %{"name" => name}, socket) when name != "" do
    ctx = socket.assigns.context

    case Emissary.MCP.ToolRegistry.call("aqua", ctx, %{
           "action" => "create_agent",
           "name" => name,
           "title" => name,
           "content" => "# #{name}\n\nYou are #{name}."
         }) do
      {:ok, _} ->
        send(self(), {:editor_refresh})
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  def handle_event("editor_create_agent", _params, socket), do: {:noreply, socket}

  def handle_event("editor_create_sub_agent", %{"parent" => parent, "name" => name}, socket)
      when name != "" do
    ctx = socket.assigns.context

    case Emissary.MCP.ToolRegistry.call("aqua", ctx, %{
           "action" => "create",
           "parent" => parent,
           "name" => name,
           "title" => name,
           "description" => "Spawn a #{name} specialist.",
           "content" => "# #{name}\n\nYou are the #{name} agent."
         }) do
      {:ok, _} ->
        send(self(), {:editor_refresh})
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  def handle_event("editor_create_sub_agent", _params, socket), do: {:noreply, socket}

  @available_tools ~w(component build execution aqua secret policy system request_setup files storage schedule http oauth native_search)

  def handle_event("editor_toggle_tool", %{"name" => agent_name, "tool" => tool}, socket) do
    ctx = socket.assigns.context
    agent = Enum.find(socket.assigns.editor_agents, &(&1["name"] == agent_name))
    current_tools = agent && agent["visible_tools"]

    new_tools =
      cond do
        # First click on unrestricted agent (visible_tools: null) — remove the clicked tool
        current_tools == nil && tool == "native_search" ->
          ["native_search"]

        current_tools == nil ->
          @available_tools -- [tool]

        # native_search is exclusive — toggle on (alone) or off (empty)
        tool == "native_search" ->
          if "native_search" in current_tools, do: [], else: ["native_search"]

        # Toggle off
        tool in current_tools ->
          List.delete(current_tools, tool) -- ["native_search"]

        # Toggle on
        true ->
          (current_tools -- ["native_search"]) ++ [tool]
      end

    case Emissary.MCP.ToolRegistry.call("aqua", ctx, %{
           "action" => "update",
           "name" => agent_name,
           "visible_tools" => new_tools
         }) do
      {:ok, _} ->
        send(self(), {:editor_refresh})
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{inspect(reason)}")}
    end
  end

  def handle_event("editor_load_agents", _params, socket) do
    ctx = socket.assigns.context

    agents =
      case Emissary.MCP.ToolRegistry.call("aqua", ctx, %{"action" => "list"}) do
        {:ok, result} ->
          guides = result[:guides] || result["guides"] || []

          Enum.flat_map(guides, fn g ->
            name = g[:name] || g["name"]
            type = g[:type] || g["type"]

            if type in ["orchestrator", "sub-agent"] do
              case Emissary.MCP.ToolRegistry.call("aqua", ctx, %{"action" => "get", "name" => name}) do
                {:ok, detail} ->
                  [%{
                    "name" => name,
                    "title" => detail[:title] || detail["title"] || name,
                    "type" => type,
                    "parent" => detail[:parent] || detail["parent"],
                    "description" => detail[:description] || detail["description"] || "",
                    "model" => detail[:model] || detail["model"],
                    "catalyst_ref" => detail[:catalyst_ref] || detail["catalyst_ref"],
                    "visible_tools" => detail[:visible_tools] || detail["visible_tools"],
                    "content" => detail[:content] || detail["content"] || ""
                  }]

                _ ->
                  []
              end
            else
              []
            end
          end)

        _ ->
          []
      end

    {:noreply, assign(socket, :editor_agents, agents)}
  end

  def handle_event("editor_update_field", %{"name" => name, "field" => field, "value" => value}, socket) do
    ctx = socket.assigns.context
    args = %{"action" => "update", "name" => name, field => value}

    case Emissary.MCP.ToolRegistry.call("aqua", ctx, args) do
      {:ok, _} ->
        # Reload agents and orchestrators
        send(self(), {:editor_refresh})
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{inspect(reason)}")}
    end
  end

  def handle_event("editor_delete", %{"name" => name}, socket) do
    ctx = socket.assigns.context

    case Emissary.MCP.ToolRegistry.call("aqua", ctx, %{"action" => "delete", "name" => name}) do
      {:ok, _} ->
        send(self(), {:editor_refresh})
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("editor_edit_prompt", %{"name" => name}, socket) do
    agent = Enum.find(socket.assigns.editor_agents, &(&1["name"] == name))
    content = if agent, do: agent["content"], else: ""

    {:noreply,
     socket
     |> assign(:editor_editing_prompt, name)
     |> assign(:editor_prompt_content, content)}
  end

  def handle_event("editor_cancel_prompt", _params, socket) do
    {:noreply, assign(socket, :editor_editing_prompt, nil)}
  end

  def handle_event("editor_save_prompt", %{"content" => content}, socket) do
    ctx = socket.assigns.context
    name = socket.assigns.editor_editing_prompt

    case Emissary.MCP.ToolRegistry.call("aqua", ctx, %{
           "action" => "update",
           "name" => name,
           "content" => content
         }) do
      {:ok, _} ->
        send(self(), {:editor_refresh})
        {:noreply, assign(socket, :editor_editing_prompt, nil)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

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

        base =
          if msg["duration_seconds"],
            do: Map.put(base, :duration_seconds, msg["duration_seconds"]),
            else: base

        base =
          if msg["token_usage"],
            do:
              Map.put(base, :token_usage, %{
                input: msg["token_usage"]["input"] || 0,
                output: msg["token_usage"]["output"] || 0
              }),
            else: base

        if is_list(msg["tool_activity"]) && msg["tool_activity"] != [] do
          activity =
            Enum.map(msg["tool_activity"], fn e ->
              %{
                tool: e["tool"] || "tool",
                status: Map.get(@known_tool_statuses, e["status"] || "done", :done),
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
      Enum.find_value(
        socket.assigns.background_executions,
        {nil, socket.assigns.background_executions},
        fn {exec_id, conv_id} ->
          if conv_id == id,
            do: {exec_id, Map.delete(socket.assigns.background_executions, exec_id)}
        end
      )

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

    conversations = Enum.reject(socket.assigns.conversations, &(&1.id == id))

    case Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
           Arca.delete(ctx, path)

           # Read current index from disk and remove entry (avoids overwriting
           # entries added by other clients like Porta)
           case read_index(ctx) do
             {:ok, current_entries} ->
               updated = Enum.reject(current_entries, fn e -> e["id"] == id end)
               write_index(ctx, updated)

             _ ->
               :ok
           end
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("[AgentLive] Failed to start delete task: #{inspect(reason)}")
    end

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

  def handle_event("setup_form_change", params, socket) do
    setup = socket.assigns.pending_setup

    secret_inputs =
      (params["secret"] || %{})
      |> Enum.into(setup.secret_inputs)

    policy_inputs =
      (params["policy"] || %{})
      |> Enum.into(setup.policy_inputs)

    {:noreply,
     assign(socket, :pending_setup, %{setup | secret_inputs: secret_inputs, policy_inputs: policy_inputs})}
  end

  def handle_event("open_setup_in_components", %{"ref" => ref}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/components?ref=#{ref}&setup=true&from=agent")}
  end

  def handle_event("dismiss_setup", _params, socket) do
    {:noreply,
     socket
     |> assign(:setup_issues, [])
     |> assign(:setup_component_ref, nil)
     |> assign(:setup_command, nil)
     |> assign(:pending_setup, nil)
     |> assign(:pending_retry_input, nil)
     |> assign(:pending_provider, nil)
     |> assign(:pending_model, nil)}
  end

  def handle_event("complete_setup", params, socket) when is_map_key(params, "secret") or is_map_key(params, "policy") do
    setup = socket.assigns.pending_setup
    ctx = socket.assigns.context
    component_ref = setup.component_ref
    secrets_map = params["secret"] || %{}
    policy_map = params["policy"] || %{}

    # Save secrets: set value + grant for new ones, grant for already-set ones
    secret_errors =
      Enum.reduce(secrets_map, [], fn {name, value}, errors ->
        secret_status =
          Enum.find(setup.secrets || [], fn s -> setup_field(s, :name) == name end)

        already_set? = secret_status && setup_field(secret_status, :already_set) == true

        if already_set? do
          # Checkbox mode: grant if checked
          if value == "true" do
            case Emissary.MCP.ToolRegistry.call("secret", ctx, %{
                   "action" => "grant",
                   "name" => name,
                   "component_ref" => component_ref
                 }) do
              {:ok, _} -> errors
              {:error, reason} -> ["#{name} grant: #{inspect(reason)}" | errors]
            end
          else
            errors
          end
        else
          # Text input mode: set value and grant
          if String.trim(value) != "" do
            case Emissary.MCP.ToolRegistry.call("secret", ctx, %{
                   "action" => "set",
                   "name" => name,
                   "value" => value
                 }) do
              {:ok, _} ->
                case Emissary.MCP.ToolRegistry.call("secret", ctx, %{
                       "action" => "grant",
                       "name" => name,
                       "component_ref" => component_ref
                     }) do
                  {:ok, _} -> errors
                  {:error, reason} -> ["#{name} grant: #{inspect(reason)}" | errors]
                end

              {:error, reason} ->
                ["#{name}: #{inspect(reason)}" | errors]
            end
          else
            errors
          end
        end
      end)

    # Save policy fields from form inputs
    policy_errors =
      Enum.reduce(policy_map, [], fn {field, value}, errors ->
        if String.trim(value) != "" do
          encoded = parse_setup_policy_for_save(value, field)

          case Emissary.MCP.ToolRegistry.call("policy", ctx, %{
                 "action" => "update_field",
                 "component_ref" => component_ref,
                 "field" => field,
                 "value" => encoded
               }) do
            {:ok, _} -> errors
            {:error, reason} -> ["Policy #{field}: #{inspect(reason)}" | errors]
          end
        else
          errors
        end
      end)

    all_errors = secret_errors ++ policy_errors

    # Add confirmation message (no secret values exposed)
    confirm_msg = %{
      role: "assistant",
      content:
        if(all_errors == [],
          do: "Setup complete for #{component_ref}. Resuming your task...",
          else: "Setup partially complete for #{component_ref}. Errors: #{Enum.join(all_errors, "; ")}"
        ),
      timestamp: DateTime.utc_now()
    }

    socket =
      socket
      |> assign(:messages, socket.assigns.messages ++ [confirm_msg])
      |> assign(:pending_setup, nil)
      |> assign(:setup_issues, [])
      |> assign(:setup_component_ref, nil)
      |> assign(:setup_command, nil)

    # Auto-continue the task if setup succeeded
    if all_errors == [] && socket.assigns.pending_retry_input do
      send(self(), {:auto_retry, "Setup for #{component_ref} is saved. Please continue."})
    end

    {:noreply, assign(socket, :pending_retry_input, nil)}
  end

  def handle_event("complete_setup", _params, socket) do
    # No secrets submitted — just dismiss
    {:noreply,
     socket
     |> assign(:pending_setup, nil)
     |> assign(:setup_issues, [])
     |> assign(:setup_component_ref, nil)
     |> assign(:setup_command, nil)
     |> assign(:pending_retry_input, nil)}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
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
          put_flash(
            socket,
            :error,
            "All providers failed: #{Enum.join(failed, ", ")}. Check catalyst policies and secrets."
          )

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

  # Execution events from the formula's emit() calls
  def handle_info({:execution_event, %{type: "emit", data: data, execution_id: exec_id}}, socket) do
    case route_execution_event(socket, exec_id) do
      :current -> handle_emit_event(socket, data)
      :background -> handle_background_emit(socket, exec_id, data)
      :ignore -> {:noreply, socket}
    end
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

  def handle_info({:stream_started, exec_id, orchestrator_name}, socket) do
    Logger.info("[AgentLive] Stream started: #{orchestrator_name} (#{exec_id})")
    ctx = socket.assigns[:context]

    # Subscribe to this execution's event buffer
    if opus_available?(), do: Opus.ExecutionEventBuffer.subscribe(exec_id, ctx)

    {:noreply,
     socket
     |> assign(:current_execution_id, exec_id)
     |> assign(:running, true)
     |> assign(:started_at, DateTime.utc_now())
     |> assign(:progress, "#{orchestrator_name}...")
     |> save_conversation()}
  end

  def handle_info({:stream_error, reason}, socket) do
    error_msg = %{
      role: "error",
      content: "Execution failed: #{inspect(reason)}",
      timestamp: DateTime.utc_now()
    }

    {:noreply,
     socket
     |> assign(:messages, socket.assigns.messages ++ [error_msg])
     |> assign(:running, false)
     |> assign(:progress, nil)
     |> persist_messages()}
  end

  def handle_info({:editor_refresh}, socket) do
    socket = load_orchestrators(socket)

    {:noreply,
     socket
     |> then(fn s ->
       case handle_event("editor_load_agents", %{}, s) do
         {:noreply, s2} -> s2
       end
     end)}
  end

  def handle_info(:load_conversations, socket) do
    socket = socket |> load_conversations() |> load_orchestrators()
    send(self(), :check_running_conversations)
    {:noreply, socket}
  end

  def handle_info(:check_running_conversations, socket) do
    # Don't auto-reconnect if user already started a new task or loaded a conversation
    if socket.assigns.running || socket.assigns.conversation_id do
      {:noreply, socket}
    else
      # Find the most recent conversation that was left running
      running_conv = Enum.find(socket.assigns.conversations, &(&1.status == :running))

      if running_conv do
        {:noreply, load_conversation(socket, running_conv.id)}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_info({:task_timeout, :models}, socket) do
    if socket.assigns.models_loading do
      Logger.warning("[AgentLive] Model loading timed out after 60s")

      {:noreply,
       socket |> assign(:models_loading, false) |> put_flash(:error, "Model loading timed out")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:auto_retry, message}, socket) do
    # Re-submit the original user message as if they typed it again
    handle_event("submit", %{"message" => message}, socket)
  end

  def handle_info({:setup_complete, _component_ref}, socket) do
    retry_input = socket.assigns.pending_retry_input

    if retry_input && !socket.assigns.running do
      # Setup was completed externally (e.g., ComponentsLive) — auto-retry
      confirm_msg = %{
        role: "assistant",
        content: "Setup completed. Resuming your task...",
        timestamp: DateTime.utc_now()
      }

      socket =
        socket
        |> assign(:messages, socket.assigns.messages ++ [confirm_msg])
        |> assign(:pending_setup, nil)
        |> assign(:setup_issues, [])
        |> assign(:setup_component_ref, nil)
        |> assign(:setup_command, nil)

      component_ref = socket.assigns[:setup_component_ref] || "component"
      send(self(), {:auto_retry, "Setup for #{component_ref} is saved. Please continue."})
      {:noreply, assign(socket, :pending_retry_input, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(msg, socket) do
    Logger.debug("[AgentLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Emit event dispatch
  # ---------------------------------------------------------------------------

  defp handle_emit_event(socket, data) do
    kind = data["kind"] || data[:kind]
    emit_tag = data["emit_tag"] || data[:emit_tag]

    socket =
      if is_binary(emit_tag) && emit_tag != "" do
        # Sub-agent event — route to the matching tool entry's sub_events
        role = data["role"] || data[:role] || ""
        handle_sub_agent_event(socket, kind, emit_tag, role, data)
      else
        # Parent agent event — existing dispatch logic
        handle_parent_event(socket, kind, data)
      end

    {:noreply, socket}
  end

  defp handle_parent_event(socket, kind, data) do
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
        |> push_event("scroll_nudge", %{})

      "tool_use" ->
        tool = data["tool"] || data[:tool] || "tool"
        _tool_call_id = data["tool_call_id"] || data[:tool_call_id]
        turn = data["turn"] || data[:turn] || socket.assigns.current_turn
        input = data["input"] || data[:input]
        entry = %{tool: tool, status: :running, turn: turn, preview: nil, input: input,
                  sub_events: [], emit_tag: nil}

        segments = add_tool_to_current_segment(socket.assigns.stream_segments, entry)

        socket
        |> assign(:tool_activity, socket.assigns.tool_activity ++ [entry])
        |> assign(:stream_segments, segments)
        |> assign(:progress, "Using #{tool}...")
        |> push_event("scroll_nudge", %{})

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

        assign(socket, :token_usage, %{
          input: current.input + input,
          output: current.output + output
        })

      "conversation_complete" ->
        messages = data["messages"] || data[:messages] || []
        assign(socket, :conversation_history, messages)

      "setup_required" ->
        component_ref = data["component_ref"] || ""
        socket |> build_full_setup(component_ref) |> save_conversation()

      "request_setup" ->
        component_ref = data["component_ref"] || ""
        socket |> build_full_setup(component_ref) |> save_conversation()

      _ ->
        socket
    end
  end

  defp handle_sub_agent_event(socket, kind, emit_tag, role, data) do
    # Build a sub-event from the data
    sub_event =
      case kind do
        "turn_start" ->
          %{kind: :turn_start, turn: data["turn"] || data[:turn] || 0}

        "text_delta" ->
          %{kind: :text_delta, content: data["content"] || data[:content] || ""}

        "tool_use" ->
          tool = data["tool"] || data[:tool] || "tool"
          %{kind: :tool_use, tool: tool, status: :running}

        "tool_result" ->
          tool = data["tool"] || data[:tool] || "tool"
          preview = data["preview"] || data[:preview]
          %{kind: :tool_result, tool: tool, preview: preview}

        "usage" ->
          :usage

        _ ->
          nil
      end

    cond do
      sub_event == :usage ->
        # Sub-agent usage: accumulate into parent totals, no sub_event entry
        input = data["input_tokens"] || data[:input_tokens] || 0
        output = data["output_tokens"] || data[:output_tokens] || 0
        current = socket.assigns.token_usage

        assign(socket, :token_usage, %{
          input: current.input + input,
          output: current.output + output
        })

      sub_event != nil ->
        # Find the tool entry in segments whose emit_tag matches
        segments = append_sub_event(socket.assigns.stream_segments, emit_tag, sub_event)

        # Update progress label
        role_label = if role != "", do: String.capitalize(role), else: "Sub-agent"

        progress =
          case kind do
            "tool_use" -> "#{role_label} using #{sub_event[:tool]}..."
            "text_delta" -> "#{role_label} writing..."
            "tool_result" -> "#{role_label}: #{sub_event[:tool]} done"
            _ -> socket.assigns.progress
          end

        socket
        |> assign(:stream_segments, segments)
        |> assign(:progress, progress)

      true ->
        socket
    end
  end

  defp append_sub_event(segments, emit_tag, sub_event) do
    # Walk segments in reverse, find the tool entry with matching emit_tag
    idx =
      segments
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {seg, i} ->
        if Enum.any?(seg.tools, &(Map.get(&1, :emit_tag) == emit_tag)), do: i
      end)

    if idx do
      List.update_at(segments, idx, fn seg ->
        tools =
          Enum.map(seg.tools, fn tool ->
            if Map.get(tool, :emit_tag) == emit_tag do
              existing = Map.get(tool, :sub_events, [])

              # Coalesce consecutive text_deltas
              updated =
                case sub_event do
                  %{kind: :text_delta, content: content} ->
                    case List.last(existing) do
                      %{kind: :text_delta, content: prev} ->
                        List.replace_at(existing, -1, %{kind: :text_delta, content: prev <> content})

                      _ ->
                        existing ++ [sub_event]
                    end

                  %{kind: :tool_result, tool: t_name} ->
                    # Mark matching tool_use as done
                    marked =
                      Enum.map(existing, fn
                        %{kind: :tool_use, tool: ^t_name, status: :running} = e ->
                          %{e | status: :done}

                        e ->
                          e
                      end)

                    marked ++ [sub_event]

                  _ ->
                    existing ++ [sub_event]
                end

              %{tool | sub_events: updated}
            else
              tool
            end
          end)

        %{seg | tools: tools}
      end)
    else
      segments
    end
  end

  # ---------------------------------------------------------------------------
  # Model loading via list-models formula
  # ---------------------------------------------------------------------------

  defp load_all_models(socket) do
    lv = self()
    ctx = socket.assigns.context

    case Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
           result =
             Emissary.MCP.ToolRegistry.call(
               "execution",
               ctx,
               %{
                 "action" => "run",
                 "reference" => @list_models_ref,
                 "input" => %{},
                 "type" => "formula"
               }
             )

           send(lv, {:list_models_result, result})
         end) do
      {:ok, _pid} ->
        Process.send_after(self(), {:task_timeout, :models}, 60_000)

      {:error, reason} ->
        Logger.warning("[AgentLive] Failed to start models task: #{inspect(reason)}")
        send(lv, {:list_models_result, {:error, "Failed to start task"}})
    end

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
    if socket.assigns.editor_open do
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

  defp build_partial_history(socket) do
    existing = socket.assigns.conversation_history
    messages = socket.assigns.messages
    streaming = socket.assigns.streaming_text

    # Build conversation turns from the last user message + any partial assistant response
    last_user = messages |> Enum.reverse() |> Enum.find(&(&1.role == "user"))

    new_turns =
      if last_user do
        user_turn = [%{"role" => "user", "content" => last_user.content}]

        if streaming && streaming != "" do
          user_turn ++ [%{"role" => "assistant", "content" => streaming <> "\n\n(cancelled)"}]
        else
          user_turn
        end
      else
        []
      end

    existing ++ new_turns
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
    if opus_available?(),
      do: Opus.ExecutionEventBuffer.unsubscribe(exec_id, socket.assigns[:context])

    conv_id = socket.assigns.background_executions[exec_id]
    bg = Map.delete(socket.assigns.background_executions, exec_id)

    # Save completion to conversation file
    if conv_id do
      finalize_background_conversation(socket.assigns.context, conv_id, exec_id)
    end

    # Update conversation list status
    conversations =
      Enum.map(socket.assigns.conversations, fn conv ->
        if conv.id == conv_id, do: %{conv | status: :idle}, else: conv
      end)

    {:noreply,
     socket
     |> assign(:background_executions, bg)
     |> assign(:conversations, conversations)}
  end

  defp finalize_background_conversation(ctx, conv_id, exec_id) do
    path = @conversations_path ++ ["#{conv_id}.json"]

    Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
      with {:ok, conv_data} <- Arca.get_json(ctx, path) do
        # Try to get execution result
        result_content =
          if opus_available?() do
            case Opus.ExecutionRecord.get(ctx, exec_id) do
              {:ok, %{status: :completed, output: output}} when is_map(output) ->
                output["content"] || output[:content]

              {:ok, %{status: :failed, error: error}} ->
                "Agent error: #{error || "Unknown error"}"

              _ ->
                nil
            end
          end

        # Append result as assistant message if we got one
        messages = conv_data["messages"] || []

        messages =
          if result_content do
            messages ++
              [
                %{
                  "role" => "assistant",
                  "content" => result_content,
                  "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
                }
              ]
          else
            messages
          end

        updated =
          conv_data
          |> Map.put("messages", messages)
          |> Map.put("execution_id", nil)
          |> Map.put("running", false)
          |> Map.put("updated_at", DateTime.to_iso8601(DateTime.utc_now()))

        Arca.put_json(ctx, path, updated)

        # Update index entry to idle
        case read_index(ctx) do
          {:ok, entries} ->
            updated_entries =
              Enum.map(entries, fn entry ->
                if entry["id"] == conv_id do
                  %{entry | "status" => "idle", "updated_at" => DateTime.to_iso8601(DateTime.utc_now())}
                else
                  entry
                end
              end)

            write_index(ctx, updated_entries)

          _ ->
            :ok
        end
      end
    end)
  end

  defp handle_current_complete(socket) do
    exec_id = socket.assigns.current_execution_id

    if exec_id && opus_available?(),
      do: Opus.ExecutionEventBuffer.unsubscribe(exec_id, socket.assigns[:context])

    streaming = socket.assigns.streaming_text

    if streaming != "" do
      segments = socket.assigns.stream_segments

      duration_seconds = compute_duration(socket.assigns.started_at)
      usage = socket.assigns.token_usage

      assistant_msg = %{
        role: "assistant",
        content: streaming,
        orchestrator: socket.assigns.active_orchestrator,
        turns: socket.assigns.current_turn,
        timestamp: DateTime.utc_now(),
        duration_seconds: duration_seconds,
        token_usage: usage
      }

      assistant_msg =
        if segments != [], do: Map.put(assistant_msg, :segments, segments), else: assistant_msg

      messages = socket.assigns.messages ++ [assistant_msg]

      # No parallel executions in single-target mode
      has_parallel = false

      {:noreply,
       socket
       |> assign(:messages, messages)
       |> assign(:running, has_parallel)
       |> assign(:progress, if(has_parallel, do: socket.assigns.progress, else: nil))
       |> assign(:streaming_text, "")
       |> assign(:stream_segments, [])
       |> assign(:tool_activity, [])
       |> assign(:current_execution_id, nil)
       |> assign(:started_at, nil)
       |> persist_messages()
       |> push_event("clear_partial", %{})
       |> push_event("scroll_nudge", %{})}
    else
      {:noreply,
       socket
       |> assign(:current_execution_id, nil)}
    end
  end

  defp handle_current_error(socket, data) do
    exec_id = socket.assigns.current_execution_id

    if exec_id && opus_available?(),
      do: Opus.ExecutionEventBuffer.unsubscribe(exec_id, socket.assigns[:context])

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

  @doc false
  defp parse_orchestrator_mention(message, orchestrators) do
    if not String.contains?(message, "@") or orchestrators == [] do
      {message, nil}
    else
      names = Enum.map(orchestrators, & &1["name"])
      sorted = Enum.sort_by(names, &(-String.length(&1)))

      Enum.find_value(sorted, {message, nil}, fn name ->
        re = Regex.compile!("@#{Regex.escape(name)}(?=\\s|$)", "i")

        if Regex.match?(re, message) do
          cleaned = Regex.replace(re, message, "") |> String.trim()
          {if(cleaned == "", do: message, else: cleaned), name}
        end
      end)
    end
  end

  defp upload_error_to_string(:too_large), do: "File too large (max 20MB)"
  defp upload_error_to_string(:too_many_files), do: "Too many files (max 10)"
  defp upload_error_to_string(:not_accepted), do: "File type not accepted"
  defp upload_error_to_string(err), do: inspect(err)

  defp persist_messages(socket) do
    socket
    |> save_conversation()
    |> push_event("save_preferences", %{
      provider: socket.assigns.provider,
      model: socket.assigns.model
    })
  end

  defp build_conversation_data(socket) do
    messages = socket.assigns.messages

    first_user_msg =
      Enum.find_value(messages, "New conversation", fn
        %{role: "user", content: c} -> String.slice(c, 0..80)
        _ -> nil
      end)

    %{
      "id" => socket.assigns.conversation_id,
      "title" => first_user_msg,
      "created_at" => DateTime.to_iso8601(List.first(messages).timestamp),
      "updated_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "provider" => socket.assigns.provider,
      "model" => socket.assigns.model,
      "default_orchestrator" => socket.assigns.active_orchestrator,
      "messages" => serialize_messages(messages),
      "conversation_history" => socket.assigns.conversation_history,
      "execution_id" => socket.assigns.current_execution_id,
      "running" => socket.assigns.running,
      "setup_component_ref" => socket.assigns[:setup_component_ref],
      "pending_retry_input" => socket.assigns[:pending_retry_input]
    }
  end

  defp save_conversation(socket) do
    conv_id = socket.assigns.conversation_id
    messages = socket.assigns.messages

    if conv_id && messages != [] do
      conv_data = build_conversation_data(socket)

      ctx = socket.assigns.context
      path = @conversations_path ++ ["#{conv_id}.json"]

      # Update conversations list in-place
      first_user_msg = conv_data["title"]
      entry = %{id: conv_id, title: first_user_msg, updated_at: DateTime.utc_now(), status: :idle}
      conversations = update_conversation_entry(socket.assigns.conversations, entry)

      # Build index entry for disk upsert (read-then-upsert to avoid overwriting
      # entries added by other clients like Porta)
      index_entry = %{
        "id" => conv_id,
        "title" => first_user_msg,
        "updated_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "status" => "idle"
      }

      case Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
             Arca.put_json(ctx, path, conv_data)

             case read_index(ctx) do
               {:ok, current_entries} ->
                 write_index(ctx, upsert_index_entry(current_entries, index_entry))

               _ ->
                 write_index(ctx, [index_entry])
             end
           end) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.warning("[AgentLive] Failed to start save task: #{inspect(reason)}")
      end

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

      base = if msg[:orchestrator], do: Map.put(base, "orchestrator", msg.orchestrator), else: base

      base = if Map.has_key?(msg, :turns), do: Map.put(base, "turns", msg.turns), else: base

      base =
        if msg[:duration_seconds],
          do: Map.put(base, "duration_seconds", msg.duration_seconds),
          else: base

      base =
        if msg[:token_usage],
          do:
            Map.put(base, "token_usage", %{
              "input" => msg.token_usage.input,
              "output" => msg.token_usage.output
            }),
          else: base

      base =
        if Map.has_key?(msg, :segments) && msg.segments != [] do
          serialized_segments =
            Enum.map(msg.segments, fn seg ->
              %{
                "turn" => seg.turn,
                "text" => seg.text,
                "tools" =>
                  Enum.map(seg.tools, fn t ->
                    tool_map = %{
                      "tool" => t.tool,
                      "status" => to_string(t.status),
                      "preview" => t.preview
                    }

                    tool_map =
                      if Map.has_key?(t, :input) && t.input,
                        do: Map.put(tool_map, "input", t.input),
                        else: tool_map

                    tool_map =
                      if Map.has_key?(t, :emit_tag),
                        do: Map.put(tool_map, "emit_tag", t.emit_tag),
                        else: tool_map

                    if Map.has_key?(t, :sub_events) && t.sub_events != [] do
                      Map.put(tool_map, "sub_events", Enum.map(t.sub_events, &serialize_sub_event/1))
                    else
                      tool_map
                    end
                  end)
              }
            end)

          Map.put(base, "segments", serialized_segments)
        else
          base
        end

      if Map.has_key?(msg, :tool_activity) && msg[:tool_activity] != [] do
        activity =
          Enum.map(msg.tool_activity, fn e ->
            %{"tool" => e.tool, "status" => to_string(e.status), "preview" => e.preview}
          end)

        Map.put(base, "tool_activity", activity)
      else
        base
      end
    end)
  end

  defp deserialize_sub_event(e) when is_map(e) do
    kind =
      case e["kind"] do
        "turn_start" -> :turn_start
        "tool_use" -> :tool_use
        "tool_result" -> :tool_result
        "text_delta" -> :text_delta
        _ -> :unknown
      end

    base = %{kind: kind}

    case kind do
      :turn_start -> Map.put(base, :turn, e["turn"] || 0)
      :tool_use -> base |> Map.put(:tool, e["tool"] || "tool") |> Map.put(:status, Map.get(@known_tool_statuses, e["status"] || "done", :done))
      :tool_result -> base |> Map.put(:tool, e["tool"] || "tool") |> Map.put(:preview, e["preview"])
      :text_delta -> Map.put(base, :content, e["content"] || "")
      _ -> base
    end
  end

  defp serialize_sub_event(%{kind: kind} = event) do
    base = %{"kind" => to_string(kind)}

    case kind do
      :turn_start -> Map.put(base, "turn", event[:turn] || 0)
      :tool_use -> base |> Map.put("tool", event[:tool]) |> Map.put("status", to_string(event[:status] || :done))
      :tool_result -> base |> Map.put("tool", event[:tool]) |> Map.put("preview", event[:preview])
      :text_delta -> Map.put(base, "content", event[:content] || "")
      _ -> base
    end
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

  defp read_index(ctx) do
    case Arca.get_json(ctx, @index_path) do
      {:ok, %{"entries" => entries}} when is_list(entries) -> {:ok, entries}
      _ -> {:error, :no_index}
    end
  end

  defp write_index(ctx, entries) do
    Arca.put_json(ctx, @index_path, %{"entries" => entries})
  end

  defp conversations_to_index_entries(conversations) do
    Enum.map(conversations, fn conv ->
      %{
        "id" => conv.id,
        "title" => conv.title,
        "updated_at" => DateTime.to_iso8601(conv.updated_at),
        "status" => to_string(conv.status)
      }
    end)
  end

  defp upsert_index_entry(entries, new_entry) do
    if Enum.any?(entries, fn e -> e["id"] == new_entry["id"] end) do
      Enum.map(entries, fn e ->
        if e["id"] == new_entry["id"], do: new_entry, else: e
      end)
    else
      [new_entry | entries]
    end
  end

  defp load_conversations(socket) do
    ctx = socket.assigns.context
    bg_execs = socket.assigns.background_executions

    case read_index(ctx) do
      {:ok, index_entries} ->
        # Map index entries to in-memory structs
        conversations =
          Enum.map(index_entries, fn entry ->
            status =
              cond do
                Enum.any?(bg_execs, fn {_exec, conv} -> conv == entry["id"] end) -> :running
                entry["status"] == "running" -> :running
                true -> :idle
              end

            %{
              id: entry["id"],
              title: entry["title"] || "Untitled",
              updated_at: parse_timestamp(entry["updated_at"]),
              status: status
            }
          end)

        # Reconcile: add missing files to index + prune orphaned entries
        {conversations, index_changed} = reconcile_conversations(ctx, conversations, bg_execs)

        conversations = Enum.sort_by(conversations, & &1.updated_at, {:desc, DateTime})

        if index_changed do
          entries = conversations_to_index_entries(conversations)
          Task.Supervisor.start_child(Prism.TaskSupervisor, fn -> write_index(ctx, entries) end)
        end

        assign(socket, :conversations, conversations)

      {:error, :no_index} ->
        # Fallback: full scan, then write index async
        conversations = scan_all_conversations(ctx, bg_execs)
        conversations = Enum.sort_by(conversations, & &1.updated_at, {:desc, DateTime})

        if conversations != [] do
          entries = conversations_to_index_entries(conversations)
          Task.Supervisor.start_child(Prism.TaskSupervisor, fn -> write_index(ctx, entries) end)
        end

        assign(socket, :conversations, conversations)
    end
  end

  defp reconcile_conversations(ctx, conversations, bg_execs) do
    indexed_ids = MapSet.new(conversations, & &1.id)

    case Arca.list(ctx, @conversations_path) do
      {:ok, files} ->
        file_ids =
          files
          |> Enum.filter(&(String.ends_with?(&1, ".json") && &1 != "index.json"))
          |> Enum.map(fn f -> String.trim_trailing(f, ".json") end)

        file_id_set = MapSet.new(file_ids)
        missing_from_index = Enum.reject(file_ids, &MapSet.member?(indexed_ids, &1))

        # Prune orphaned index entries (no backing file on disk)
        original_count = length(conversations)
        conversations = Enum.filter(conversations, &MapSet.member?(file_id_set, &1.id))
        pruned = original_count != length(conversations)

        # Add files missing from the index
        added =
          Enum.flat_map(missing_from_index, fn conv_id ->
            path = @conversations_path ++ ["#{conv_id}.json"]

            case Arca.get_json(ctx, path) do
              {:ok, data} ->
                status =
                  cond do
                    Enum.any?(bg_execs, fn {_exec, conv} -> conv == data["id"] end) -> :running
                    data["running"] == true -> :running
                    true -> :idle
                  end

                [%{
                  id: data["id"],
                  title: data["title"] || "Untitled",
                  updated_at: parse_timestamp(data["updated_at"]),
                  status: status
                }]

              _ ->
                []
            end
          end)

        {conversations ++ added, pruned or added != []}

      {:error, _} ->
        {conversations, false}
    end
  end

  defp scan_all_conversations(ctx, bg_execs) do
    case Arca.list(ctx, @conversations_path) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(String.ends_with?(&1, ".json") && &1 != "index.json"))
        |> Enum.flat_map(fn filename ->
          path = @conversations_path ++ [filename]

          case Arca.get_json(ctx, path) do
            {:ok, data} ->
              status =
                cond do
                  Enum.any?(bg_execs, fn {_exec, conv} -> conv == data["id"] end) -> :running
                  data["running"] == true -> :running
                  true -> :idle
                end

              [%{
                id: data["id"],
                title: data["title"] || "Untitled",
                updated_at: parse_timestamp(data["updated_at"]),
                status: status
              }]

            _ ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp load_orchestrators(socket) do
    ctx = socket.assigns.context

    # Load orchestrator list + details via aqua MCP tool
    orchestrators =
      case Emissary.MCP.ToolRegistry.call("aqua", ctx, %{"action" => "list", "type" => "orchestrator"}) do
        {:ok, result} ->
          guides = result[:guides] || result["guides"] || []

          Enum.flat_map(guides, fn g ->
            name = g[:name] || g["name"]

            case Emissary.MCP.ToolRegistry.call("aqua", ctx, %{"action" => "get", "name" => name}) do
              {:ok, detail} ->
                [%{
                  "name" => name,
                  "title" => detail[:title] || detail["title"] || name,
                  "catalyst_ref" => detail[:catalyst_ref] || detail["catalyst_ref"],
                  "model" => detail[:model] || detail["model"]
                }]

              _ ->
                Logger.warning("[AgentLive] Failed to load orchestrator: #{name}")
                []
            end
          end)

        _ ->
          Logger.warning("[AgentLive] Failed to load orchestrators from aqua tool")
          []
      end

    default = if orchestrators != [], do: hd(orchestrators)["name"]

    socket
    |> assign(:orchestrators, orchestrators)
    |> assign(:active_orchestrator, socket.assigns.active_orchestrator || default)
  end

  defp load_conversation(socket, id) do
    ctx = socket.assigns.context
    path = @conversations_path ++ ["#{id}.json"]

    case Arca.get_json(ctx, path) do
      {:ok, data} ->
        messages = deserialize_messages(data["messages"] || [])
        # With presets, conversation history is always restored (cross-provider is OK)
        conversation_history = data["conversation_history"] || []

        socket =
          socket
          |> assign(:messages, messages)
          |> assign(:conversation_id, id)
          |> assign(:conversation_history, conversation_history)
          |> assign(:active_orchestrator, data["default_orchestrator"] || data["default_preset"])
          |> assign(:expanded_tools, MapSet.new())

        # Restore setup prompt if one was pending
        setup_ref = data["setup_component_ref"]
        pending_retry = data["pending_retry_input"]

        socket =
          if setup_ref do
            socket
            |> assign(:pending_retry_input, pending_retry)
            |> build_full_setup(setup_ref)
          else
            socket
          end

        # Check for parallel executions to reconnect
        parallel_ids = data["parallel_execution_ids"] || %{}
        was_running = data["running"] == true

        # Legacy: parallel executions no longer supported, skip reconnection
        socket = socket

        # Check for single execution to reconnect (legacy/reconnection path)
        exec_id = data["execution_id"]

        if exec_id && was_running && parallel_ids == %{} && opus_available?() do
          reconnect_to_execution(socket, exec_id)
        else
          socket
        end

      {:error, _} ->
        put_flash(socket, :error, "Failed to load conversation")
    end
  end

  defp reconnect_to_execution(socket, exec_id) do
    ctx = socket.assigns.context

    case Opus.ExecutionRecord.get(ctx, exec_id) do
      {:ok, %{status: :running}} ->
        # Still running — subscribe and replay buffered events
        Opus.ExecutionEventBuffer.subscribe(exec_id, ctx)
        buffered = Opus.ExecutionEventBuffer.since(exec_id, 0)

        # Process buffered events to rebuild streaming state
        socket =
          Enum.reduce(buffered, socket, fn event, sock ->
            event_type = event[:type] || event["type"]
            event_data = event[:data] || event["data"]

            if event_type == "emit" && event_data do
              {_, sock} = handle_emit_event(sock, event_data)
              sock
            else
              sock
            end
          end)

        socket
        |> assign(:current_execution_id, exec_id)
        |> assign(:running, true)
        |> assign(:started_at, DateTime.utc_now())
        |> assign(:progress, "Reconnected...")

      {:ok, %{status: status} = record} when status in [:completed, :failed] ->
        # Finished while away — get result and finalize
        finalize_completed_execution(socket, record)

      _ ->
        # Execution not found or error — clear running state on disk
        clear_running_state_on_disk(socket.assigns.context, socket.assigns.conversation_id)
        assign(socket, :running, false)
    end
  end

  defp finalize_completed_execution(socket, %{status: :completed, output: output}) do
    content =
      if is_map(output), do: output["content"] || output[:content] || "", else: ""

    if content != "" do
      msg = %{
        role: "assistant",
        content: content,
        timestamp: DateTime.utc_now()
      }

      socket
      |> assign(:messages, socket.assigns.messages ++ [msg])
      |> assign(:running, false)
      |> persist_messages()
    else
      socket
      |> assign(:running, false)
      |> persist_messages()
    end
  end

  defp finalize_completed_execution(socket, %{status: :failed, error: error}) do
    msg = %{
      role: "error",
      content: "Agent error: #{error || "Unknown error"}",
      timestamp: DateTime.utc_now()
    }

    socket
    |> assign(:messages, socket.assigns.messages ++ [msg])
    |> assign(:running, false)
    |> persist_messages()
  end

  defp finalize_completed_execution(socket, _record) do
    socket
    |> assign(:running, false)
    |> persist_messages()
  end

  defp clear_running_state_on_disk(ctx, conv_id) when is_binary(conv_id) do
    path = @conversations_path ++ ["#{conv_id}.json"]

    Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
      case Arca.get_json(ctx, path) do
        {:ok, conv_data} ->
          updated =
            conv_data
            |> Map.put("execution_id", nil)
            |> Map.put("running", false)

          Arca.put_json(ctx, path, updated)

          # Update index entry to idle
          case read_index(ctx) do
            {:ok, entries} ->
              updated_entries =
                Enum.map(entries, fn entry ->
                  if entry["id"] == conv_id, do: %{entry | "status" => "idle"}, else: entry
                end)

              write_index(ctx, updated_entries)

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end)
  end

  defp clear_running_state_on_disk(_, _), do: :ok

  defp deserialize_messages(raw_messages) do
    Enum.map(raw_messages, fn msg ->
      base = %{
        role: msg["role"] || "user",
        content: msg["content"] || "",
        timestamp: parse_timestamp(msg["timestamp"])
      }

      # Backward compat: read "orchestrator" or legacy "preset" field
      orch_name = msg["orchestrator"] || msg["preset"]
      base = if orch_name, do: Map.put(base, :orchestrator, orch_name), else: base

      base = if msg["turns"], do: Map.put(base, :turns, msg["turns"]), else: base

      base =
        if msg["duration_seconds"],
          do: Map.put(base, :duration_seconds, msg["duration_seconds"]),
          else: base

      base =
        if msg["token_usage"],
          do:
            Map.put(base, :token_usage, %{
              input: msg["token_usage"]["input"] || 0,
              output: msg["token_usage"]["output"] || 0
            }),
          else: base

      base =
        if is_list(msg["segments"]) && msg["segments"] != [] do
          segments =
            Enum.map(msg["segments"], fn seg ->
              %{
                turn: seg["turn"] || 0,
                text: seg["text"] || "",
                tools:
                  Enum.map(seg["tools"] || [], fn t ->
                    tool_map = %{
                      tool: t["tool"] || "tool",
                      status: Map.get(@known_tool_statuses, t["status"] || "done", :done),
                      preview: t["preview"]
                    }

                    tool_map =
                      if t["input"], do: Map.put(tool_map, :input, t["input"]), else: tool_map

                    tool_map =
                      if t["emit_tag"], do: Map.put(tool_map, :emit_tag, t["emit_tag"]), else: tool_map

                    if is_list(t["sub_events"]) && t["sub_events"] != [] do
                      Map.put(tool_map, :sub_events, Enum.map(t["sub_events"], &deserialize_sub_event/1))
                    else
                      tool_map
                    end
                  end)
              }
            end)

          Map.put(base, :segments, segments)
        else
          base
        end

      if is_list(msg["tool_activity"]) && msg["tool_activity"] != [] do
        activity =
          Enum.map(msg["tool_activity"], fn e ->
            %{
              tool: e["tool"] || "tool",
              status: Map.get(@known_tool_statuses, e["status"] || "done", :done),
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

  # ---------------------------------------------------------------------------
  # System prompt composition
  # ---------------------------------------------------------------------------

  @doc false
  def build_system_prompt(ctx, orchestrator_name \\ "aqua") do
    base = fetch_base_prompt(ctx, orchestrator_name)
    dynamic = build_dynamic_context(ctx)

    if dynamic != "",
      do: base <> "\n\n---\n\n## Runtime Context\n\n" <> dynamic,
      else: base
  end

  defp fetch_base_prompt(ctx, orchestrator_name) do
    case Prism.AgentConfig.orchestrator_config(ctx, orchestrator_name) do
      {:ok, %{content: content}} ->
        content

      _ ->
        "You are an agent inside CYFR, a secure personal foundry that forges brilliance into reality."
    end
  end

  defp build_dynamic_context(_ctx) do
    now = DateTime.utc_now()
    day_name = Calendar.strftime(now, "%A")
    date_str = Calendar.strftime(now, "%Y-%m-%d")
    time_str = Calendar.strftime(now, "%H:%M UTC")
    edition = Application.get_env(:cyfr, :edition, :core)
    "Current date: #{date_str}, #{day_name}, #{time_str}\nPlatform edition: #{edition}\nFile paths: data/ for user storage, components/ for installed components"
  end



  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="agent-container"
      class="flex flex-col h-[calc(100vh-3.25rem)]"
      phx-hook="AgentChat"
      data-orchestrators={Jason.encode!(Enum.map(@orchestrators, & &1["name"]))}
    >
      <!-- Header -->
      <div class="flex items-center justify-between mb-4">
        <div class="flex items-center gap-3">
          <h2 class="text-lg font-semibold text-white">Ask AQUA</h2>
          <span
            :if={@active_orchestrator}
            class="inline-flex items-center gap-1 rounded-md bg-indigo-500/10 px-2 py-0.5 text-xs font-medium text-indigo-400"
          >
            <svg class="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M9.813 15.904L9 18.75l-.813-2.846a4.5 4.5 0 00-3.09-3.09L2.25 12l2.846-.813a4.5 4.5 0 003.09-3.09L9 5.25l.813 2.846a4.5 4.5 0 003.09 3.09L15.75 12l-2.846.813a4.5 4.5 0 00-3.09 3.09z" />
            </svg>
            {@active_orchestrator}
          </span>
        </div>
        <div class="flex items-center gap-2">
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
              <span
                :if={running_background_count(@background_executions) > 0}
                class="ml-1 inline-block w-1.5 h-1.5 rounded-full bg-blue-400 animate-pulse"
              />
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
                      <span
                        :if={conv.status == :running}
                        class="shrink-0 w-1.5 h-1.5 rounded-full bg-blue-400 animate-pulse"
                      />
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
                    <svg
                      class="w-3.5 h-3.5"
                      viewBox="0 0 16 16"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="2"
                    >
                      <path d="M4 4l8 8M12 4l-8 8" />
                    </svg>
                  </button>
                </div>
              <% end %>
            </div>
          </div>
          <span :if={@orchestrators == []} class="text-xs text-amber-400 animate-pulse">
            No orchestrators configured
          </span>
          <button
            phx-click="toggle_editor"
            class={"px-3 py-1.5 text-xs font-medium rounded-md border #{if @editor_open, do: "bg-blue-900 text-blue-300 border-blue-700", else: "bg-gray-800 text-gray-400 border-gray-700 hover:bg-gray-700"}"}
          >
            Agents
          </button>
        </div>
      </div>

    <%!-- Agent Editor modal --%>
      <div :if={@editor_open} class="fixed inset-0 z-50 flex items-center justify-center bg-black/60" phx-click-away="toggle_editor">
        <div class="mx-4 flex w-full max-w-2xl flex-col rounded-xl border border-gray-700 bg-gray-900 shadow-2xl max-h-[85vh]">
          <%!-- Header --%>
          <div class="flex items-center justify-between border-b border-gray-800 px-4 py-3 shrink-0">
            <span class="text-sm font-medium text-gray-300">Agents</span>
            <button type="button" phx-click="toggle_editor" class="text-gray-500 hover:text-gray-300 transition-colors">
              <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>

          <%!-- Content --%>
          <div class="flex-1 overflow-y-auto p-4 space-y-4">
            <% available_tools = ~w(component build execution aqua secret policy system request_setup files storage schedule http oauth native_search) %>
            <% orchestrators = Enum.filter(@editor_agents, & &1["type"] == "orchestrator") %>

            <%= for orch <- orchestrators do %>
              <% orch_agent = Enum.find(@editor_agents, & &1["name"] == orch["name"]) %>

              <%!-- Orchestrator card --%>
              <div class="space-y-2">
                <div class="rounded-lg border p-3 bg-gray-800 border-gray-600 space-y-2">
                  <div class="flex items-center justify-between">
                    <div class="flex items-center gap-2">
                      <span class="text-[10px] font-mono px-1.5 py-0.5 rounded bg-indigo-900 text-indigo-300">orchestrator</span>
                      <span class="text-sm font-medium text-white">{orch["name"]}</span>
                      <span :if={orch["title"] && orch["title"] != orch["name"]} class="text-xs text-gray-500">{orch["title"]}</span>
                    </div>
                    <div class="flex items-center gap-1">
                      <button phx-click="editor_edit_prompt" phx-value-name={orch["name"]}
                        class="px-2 py-0.5 text-[10px] text-gray-400 hover:text-blue-400 border border-gray-700 rounded hover:border-blue-700"
                      >prompt</button>
                      <button
                        :if={orch["name"] != "aqua"}
                        phx-click="editor_delete"
                        phx-value-name={orch["name"]}
                        data-confirm={"Delete orchestrator #{orch["name"]} and all its sub-agents?"}
                        class="px-2 py-0.5 text-[10px] text-gray-500 hover:text-red-400 border border-gray-700 rounded hover:border-red-700"
                      >delete</button>
                    </div>
                  </div>

                  <div class="flex items-center gap-2">
                    <span class="text-[10px] text-gray-500">Model:</span>
                    <% orch_provider = detect_provider_from_ref(orch_agent && orch_agent["catalyst_ref"]) || List.first(@providers) %>
                    <% orch_models = Map.get(@models_by_provider, orch_provider || "", []) %>
                    <form phx-change="editor_set_model" class="flex items-center gap-1">
                      <input type="hidden" name="name" value={orch["name"]} />
                      <select name="provider" class="bg-gray-900 text-xs text-gray-300 rounded border border-gray-700 px-1.5 py-0.5">
                        <%= for p <- @providers do %>
                          <option value={p} selected={p == orch_provider}>{p}</option>
                        <% end %>
                      </select>
                      <select name="model" class="bg-gray-900 text-xs text-gray-300 rounded border border-gray-700 px-1.5 py-0.5">
                        <%= for m <- orch_models do %>
                          <option value={m} selected={m == (orch_agent && orch_agent["model"])}>{m}</option>
                        <% end %>
                      </select>
                    </form>
                  </div>

                  <div>
                    <div class="flex items-center gap-2">
                      <span class="text-[10px] text-gray-500">Visible tools:</span>
                      <span :if={!orch_agent || !orch_agent["visible_tools"]} class="text-[10px] text-gray-600 italic">all (no restriction)</span>
                    </div>
                    <% orch_tools = (orch_agent && orch_agent["visible_tools"]) || [] %>
                    <% orch_has_restriction = orch_agent && orch_agent["visible_tools"] != nil %>
                    <div class="flex flex-wrap gap-1 mt-1">
                      <%= for tool <- available_tools do %>
                        <% checked = !orch_has_restriction || tool in orch_tools %>
                        <button
                          phx-click="editor_toggle_tool"
                          phx-value-name={orch["name"]}
                          phx-value-tool={tool}
                          class={"text-[10px] px-1.5 py-0.5 rounded border transition-colors #{if checked, do: "bg-indigo-900 text-indigo-300 border-indigo-700", else: "bg-gray-800 text-gray-500 border-gray-700 hover:border-gray-500"}"}
                        >{tool}</button>
                      <% end %>
                    </div>
                    <p :if={!orch_has_restriction} class="text-[10px] text-gray-600 mt-1">Click any tool to start restricting.</p>
                  </div>
                </div>

                <%!-- Sub-agents --%>
                <% sub_agents = Enum.filter(@editor_agents, & &1["type"] == "sub-agent" && &1["parent"] == orch["name"]) %>

                <%= for agent <- sub_agents do %>
                  <div class="ml-4 rounded-lg border p-3 bg-gray-900 border-gray-700 space-y-2">
                    <div class="flex items-center justify-between">
                      <div class="flex items-center gap-2">
                        <span class="text-[10px] font-mono px-1.5 py-0.5 rounded bg-gray-700 text-gray-400">sub-agent</span>
                        <span class="text-sm font-medium text-white">{agent["name"]}</span>
                        <span :if={agent["title"] && agent["title"] != agent["name"]} class="text-xs text-gray-500">{agent["title"]}</span>
                      </div>
                      <div class="flex items-center gap-1">
                        <button phx-click="editor_edit_prompt" phx-value-name={agent["name"]}
                          class="px-2 py-0.5 text-[10px] text-gray-400 hover:text-blue-400 border border-gray-700 rounded hover:border-blue-700"
                        >prompt</button>
                        <button phx-click="editor_delete" phx-value-name={agent["name"]} data-confirm={"Delete #{agent["name"]}?"}
                          class="px-2 py-0.5 text-[10px] text-gray-500 hover:text-red-400 border border-gray-700 rounded hover:border-red-700"
                        >delete</button>
                      </div>
                    </div>

                    <div class="flex items-center gap-2">
                      <span class="text-[10px] text-gray-500">Model:</span>
                      <% sa_provider = detect_provider_from_ref(agent["catalyst_ref"]) %>
                      <% is_inherited = agent["model"] == nil && agent["catalyst_ref"] == nil %>
                      <% selected_provider = if is_inherited, do: "inherit", else: sa_provider || List.first(@providers) %>
                      <% provider_models = Map.get(@models_by_provider, selected_provider || "", []) %>
                      <form phx-change="editor_set_model" class="flex items-center gap-1">
                        <input type="hidden" name="name" value={agent["name"]} />
                        <select name="provider" class="bg-gray-900 text-xs text-gray-300 rounded border border-gray-700 px-1.5 py-0.5">
                          <option value="inherit" selected={is_inherited}>inherit</option>
                          <%= for p <- @providers do %>
                            <option value={p} selected={p == selected_provider}>{p}</option>
                          <% end %>
                        </select>
                        <%= if is_inherited do %>
                          <input type="hidden" name="model" value="inherit" />
                        <% else %>
                          <select name="model" class="bg-gray-900 text-xs text-gray-300 rounded border border-gray-700 px-1.5 py-0.5">
                            <%= for m <- provider_models do %>
                              <option value={m} selected={m == agent["model"]}>{m}</option>
                            <% end %>
                          </select>
                        <% end %>
                      </form>
                    </div>

                    <div :if={agent["description"] && agent["description"] != ""}>
                      <span class="text-[10px] text-gray-500">LLM sees:</span>
                      <span class="text-[10px] text-gray-400 ml-1">{String.slice(agent["description"] || "", 0..120)}</span>
                    </div>

                    <div>
                      <span class="text-[10px] text-gray-500">Visible tools:</span>
                      <% agent_tools = agent["visible_tools"] || [] %>
                      <% has_native = "native_search" in agent_tools %>
                      <div class="flex flex-wrap gap-1 mt-1">
                        <%= for tool <- available_tools do %>
                          <% checked = tool in agent_tools %>
                          <% disabled = has_native && tool != "native_search" %>
                          <button
                            phx-click={unless disabled, do: "editor_toggle_tool"}
                            phx-value-name={agent["name"]}
                            phx-value-tool={tool}
                            class={"text-[10px] px-1.5 py-0.5 rounded border transition-colors #{cond do
                              disabled -> "bg-gray-900 text-gray-700 border-gray-800 cursor-not-allowed"
                              checked -> "bg-blue-900 text-blue-300 border-blue-700"
                              true -> "bg-gray-800 text-gray-500 border-gray-700 hover:border-gray-500"
                            end}"}
                          >{tool}</button>
                        <% end %>
                      </div>
                      <p :if={has_native} class="text-[10px] text-amber-600 mt-1">native_search must be the only tool (Gemini constraint)</p>
                    </div>
                  </div>
                <% end %>

                <%!-- Add sub-agent --%>
                <div class="ml-4">
                  <form phx-submit="editor_create_sub_agent" class="flex items-center gap-2">
                    <input type="hidden" name="parent" value={orch["name"]} />
                    <input
                      type="text"
                      name="name"
                      placeholder={"#{orch["name"]}_new_agent"}
                      class="bg-gray-900 text-gray-300 text-xs rounded border border-gray-700 px-2 py-1 w-48 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
                    />
                    <button type="submit" class="px-2 py-1 text-[10px] text-green-400 border border-green-800 rounded hover:bg-green-900">+ Sub-Agent</button>
                  </form>
                </div>
              </div>
            <% end %>

            <%!-- Add orchestrator --%>
            <div>
              <form phx-submit="editor_create_agent" class="flex items-center gap-2">
                <input
                  type="text"
                  name="name"
                  placeholder="new_orchestrator"
                  class="bg-gray-900 text-gray-300 text-xs rounded border border-gray-700 px-2 py-1 w-48 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500"
                />
                <button type="submit" class="px-2 py-1 text-[10px] text-indigo-400 border border-indigo-800 rounded hover:bg-indigo-900">+ Orchestrator</button>
              </form>
            </div>

            <div :if={@editor_agents == []} class="text-center py-3">
              <p class="text-xs text-gray-600">No agents configured</p>
            </div>
          </div>
        </div>
      </div>

    <!-- Messages area -->
      <div id="messages" class="flex-1 overflow-y-auto space-y-4 mb-4 pr-2" phx-update="replace">
        <div :if={@messages == []} class="flex items-center justify-center h-full">
          <div class="text-center">
            <p class="text-gray-500 text-sm">Start a conversation with AQUA.</p>
            <p class="text-gray-600 text-xs mt-2">
              AQUA can read, write, and search files, invoke components, and access CYFR platform tools.
            </p>
          </div>
        </div>

        <%= for {msg, idx} <- Enum.with_index(@messages) do %>
          <div id={"msg-#{idx}"} class="space-y-1">
            <!-- Role label -->
            <div class="flex items-center gap-2">
              <img
                :if={msg.role == "assistant"}
                src={~p"/images/logo.jpg"}
                alt=""
                class="h-5 w-5 rounded-md"
              />
              <span class={role_label_class(msg.role)}>
                {role_label(msg.role)}
              </span>
              <span
                :if={msg[:orchestrator]}
                class="inline-flex items-center gap-1 rounded bg-indigo-500/15 px-1.5 py-0.5 text-[10px] font-medium text-indigo-400"
              >
                <svg class="h-2.5 w-2.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M9.813 15.904L9 18.75l-.813-2.846a4.5 4.5 0 00-3.09-3.09L2.25 12l2.846-.813a4.5 4.5 0 003.09-3.09L9 5.25l.813 2.846a4.5 4.5 0 003.09 3.09L15.75 12l-2.846.813a4.5 4.5 0 00-3.09 3.09z" />
                </svg>
                {msg.orchestrator}
              </span>
              <span
                :if={msg[:turns] || msg[:duration_seconds] || msg[:token_usage]}
                class="text-xs text-gray-600"
              >
                {format_message_stats(msg)}
              </span>
            </div>

            <%= if msg.role == "assistant" && msg[:segments] && msg[:segments] != [] do %>
              <% total_tools = Enum.sum(Enum.map(msg.segments, fn seg -> length(seg.tools) end))
                 has_tools = total_tools > 0
                 # Collect all text from segments for the main content
                 all_text = msg.segments |> Enum.map(& &1.text) |> Enum.reject(& &1 == "") |> Enum.join("\n\n") %>

              <%!-- Collapsed tool summary for finalized messages --%>
              <%= if has_tools do %>
                <details class="mt-1 rounded-lg bg-gray-900 border border-gray-800">
                  <summary class="px-3 py-1.5 text-xs text-gray-500 cursor-pointer hover:text-gray-400 select-none">
                    {total_tools} tool call(s), {length(msg.segments)} turn(s)
                  </summary>
                  <div class="px-3 pb-2">
                    <%= for {seg, si} <- Enum.with_index(msg.segments) do %>
                      <%= if seg.tools != [] do %>
                        <div class="space-y-1 pl-1 mt-1">
                          <%= for {entry, ti} <- Enum.with_index(seg.tools) do %>
                            <.tool_entry_detail entry={entry} id={"msg-#{idx}-seg-#{si}-tool-#{ti}"} />
                          <% end %>
                        </div>
                      <% end %>
                    <% end %>
                  </div>
                </details>
              <% end %>

              <%!-- Final text content --%>
              <%= if all_text != "" do %>
                <div
                  id={"msg-#{idx}-text"}
                  phx-hook="MarkdownContent"
                  phx-update="ignore"
                  data-raw-content={all_text}
                  class="text-gray-300 mt-1 prose prose-invert max-w-none"
                >
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
                      <div
                        id={"msg-#{idx}-tool-#{ti}"}
                        class="flex items-start gap-2 text-xs font-mono"
                      >
                        <%= if entry.status == :cancelled do %>
                          <span class="text-amber-500 shrink-0">&#10007;</span>
                          <span class="text-gray-500">{entry.tool}</span>
                        <% else %>
                          <span class="text-green-500 shrink-0">&#10003;</span>
                          <span class="text-gray-500">{entry.tool}</span>
                          <span :if={entry.preview} class="text-gray-600 truncate max-w-md">
                            {String.slice(entry.preview, 0..80)}
                          </span>
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
                  phx-update="ignore"
                  data-raw-content={msg.content}
                  class="text-gray-300 mt-1 prose prose-invert max-w-none"
                >
                </div>
              <% else %>
                <%!-- Attachment indicators for user messages --%>
                <div :if={msg[:attachments] && msg[:attachments] != []} class="flex flex-wrap gap-1.5 mt-1">
                  <span
                    :for={att <- msg[:attachments]}
                    class="inline-flex items-center gap-1 rounded bg-gray-800 border border-gray-700 px-2 py-0.5 text-xs text-gray-400"
                  >
                    <%= if String.starts_with?(att.media_type || "", "image/") do %>
                      <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
                        <path stroke-linecap="round" stroke-linejoin="round" d="m2.25 15.75 5.159-5.159a2.25 2.25 0 0 1 3.182 0l5.159 5.159m-1.5-1.5 1.409-1.409a2.25 2.25 0 0 1 3.182 0l2.909 2.909M3.75 21h16.5a2.25 2.25 0 0 0 2.25-2.25V5.25a2.25 2.25 0 0 0-2.25-2.25H3.75A2.25 2.25 0 0 0 1.5 5.25v13.5A2.25 2.25 0 0 0 3.75 21Z" />
                      </svg>
                    <% else %>
                      <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
                        <path stroke-linecap="round" stroke-linejoin="round" d="M19.5 14.25v-2.625a3.375 3.375 0 0 0-3.375-3.375h-1.5A1.125 1.125 0 0 1 13.5 7.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H8.25m2.25 0H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 0 0-9-9Z" />
                      </svg>
                    <% end %>
                    {att.filename}
                  </span>
                </div>
                <div class={content_class(msg.role)}>
                  <pre class="whitespace-pre-wrap break-words text-sm font-sans">{msg.content}</pre>
                </div>
              <% end %>
            <% end %>
          </div>
        <% end %>

    <!-- In-flight streaming execution -->
        <%= if @running do %>
          <div id="streaming-exec" class="space-y-1 mt-4">
            <div class="flex items-center gap-2">
              <img src={~p"/images/logo.jpg"} alt="" class="h-5 w-5 rounded-md" />
              <span class="text-xs font-medium text-blue-400">AQUA</span>
              <span
                :if={@active_orchestrator}
                class="inline-flex items-center gap-1 rounded bg-indigo-500/15 px-1.5 py-0.5 text-[10px] font-medium text-indigo-400"
              >
                <svg class="h-2.5 w-2.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M9.813 15.904L9 18.75l-.813-2.846a4.5 4.5 0 00-3.09-3.09L2.25 12l2.846-.813a4.5 4.5 0 003.09-3.09L9 5.25l.813 2.846a4.5 4.5 0 003.09 3.09L15.75 12l-2.846.813a4.5 4.5 0 00-3.09 3.09z" />
                </svg>
                {@active_orchestrator}
              </span>
              <%= if @streaming_text == "" && @stream_segments == [] do %>
                <div class="flex items-center gap-1">
                  <div class="w-1.5 h-1.5 rounded-full bg-blue-400 animate-pulse" />
                  <span class="text-xs text-gray-500">{@progress || "Thinking..."}</span>
                </div>
              <% end %>
              <%= if @token_usage.input > 0 || @token_usage.output > 0 do %>
                <span class="text-xs text-gray-600 font-mono">
                  {format_tokens(@token_usage.input)} in / {format_tokens(@token_usage.output)} out
                </span>
              <% end %>
            </div>

            <%!-- Render segments interleaved: text → tools per turn --%>
            <% last_si = length(@stream_segments) - 1 %>
            <%= for {seg, si} <- Enum.with_index(@stream_segments) do %>
              <%!-- Segment text --%>
              <%= if si < last_si do %>
                <%!-- Completed segment: static markdown --%>
                <div
                  :if={seg.text != ""}
                  id={"stream-text-#{si}"}
                  phx-hook="MarkdownContent"
                  phx-update="ignore"
                  data-raw-content={seg.text}
                  class="text-gray-300 mt-1 prose prose-invert max-w-none"
                >
                </div>
              <% else %>
                <%!-- Current segment: live streaming markdown --%>
                <div
                  :if={seg.text != ""}
                  id={"streaming-text-#{seg.turn}"}
                  phx-hook="StreamingMarkdown"
                  phx-update="ignore"
                  data-raw-content={seg.text}
                  class="text-gray-300 mt-1 prose prose-invert max-w-none"
                >
                </div>
              <% end %>

              <%!-- Segment tools --%>
              <%= if seg.tools != [] do %>
                <div class="space-y-1 pl-1">
                  <%= for {tool_entry, ti} <- Enum.with_index(seg.tools) do %>
                    <.tool_entry_detail entry={tool_entry} id={"stream-seg-#{si}-tool-#{ti}"} />
                  <% end %>
                </div>
              <% end %>
            <% end %>
          </div>
        <% end %>

      </div>

    <!-- Inline Setup Form (outside @running block so it persists after completion) -->
        <div :if={@pending_setup} class="rounded-lg border border-amber-800 bg-amber-950/50 p-4 space-y-4">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2">
              <span class="text-amber-400 text-sm font-medium">Setup Required</span>
              <span class="text-xs text-gray-500 font-mono">{@pending_setup.component_ref}</span>
            </div>
            <button phx-click="dismiss_setup" class="text-gray-500 hover:text-gray-400 text-xs">
              Dismiss
            </button>
          </div>
          <p class="text-xs text-gray-600">
            This form is handled by CYFR locally. Values are stored encrypted on your device and are never sent to the model.
          </p>

          <form phx-change="setup_form_change" phx-submit="complete_setup" class="space-y-4">
            <%!-- Secrets --%>
            <div :if={@pending_setup.secrets != []} class="space-y-3">
              <h4 class="text-xs font-semibold text-gray-400 uppercase">Secrets</h4>
              <%= for secret <- @pending_setup.secrets do %>
                <% secret_name = setup_field(secret, :name) %>
                <% already_set = setup_field(secret, :already_set) == true %>
                <% already_granted = setup_field(secret, :already_granted) == true %>
                <div>
                  <dt class="text-xs text-gray-500 uppercase flex items-center gap-2 mb-1">
                    {secret_name}
                    <span :if={setup_field(secret, :required)} class="text-red-400 normal-case text-[10px]">required</span>
                    <%= if already_set && already_granted do %>
                      <span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-green-900 text-green-300">Set & Granted</span>
                    <% else %>
                      <%= if already_set do %>
                        <span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-yellow-900 text-yellow-300">Set (not granted)</span>
                      <% else %>
                        <span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-red-900 text-red-300">Not configured</span>
                      <% end %>
                    <% end %>
                  </dt>
                  <dd>
                    <%= if already_set do %>
                      <label class="flex items-center gap-2 cursor-pointer">
                        <input type="hidden" name={"secret[#{secret_name}]"} value="false" />
                        <input
                          type="checkbox"
                          name={"secret[#{secret_name}]"}
                          value="true"
                          checked={(@pending_setup.secret_inputs[secret_name] || "") == "true"}
                          class="h-4 w-4 rounded border-gray-600 bg-gray-900 text-amber-500 focus:ring-amber-500 focus:ring-offset-0"
                        />
                        <span class="text-sm text-gray-300">Grant access</span>
                      </label>
                    <% else %>
                      <input
                        type="password"
                        name={"secret[#{secret_name}]"}
                        value={@pending_setup.secret_inputs[secret_name] || ""}
                        placeholder={setup_field(secret, :description) || "Enter value..."}
                        phx-debounce="blur"
                        autocomplete="off"
                        class="w-full rounded bg-gray-900 border border-gray-700 px-3 py-1.5 text-sm text-white placeholder-gray-600 focus:border-amber-500 focus:ring-1 focus:ring-amber-500"
                      />
                    <% end %>
                  </dd>
                </div>
              <% end %>
            </div>

            <%!-- Policy fields --%>
            <div :if={@pending_setup.policy_fields != []} class="space-y-3">
              <h4 class="text-xs font-semibold text-gray-400 uppercase">Policy</h4>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                <%= for {field, label, _type} <- @pending_setup.policy_fields do %>
                  <div>
                    <dt class="text-xs text-gray-500 uppercase mb-1">{label}</dt>
                    <dd>
                      <input
                        type="text"
                        name={"policy[#{field}]"}
                        value={@pending_setup.policy_inputs[field] || ""}
                        placeholder={setup_policy_placeholder(field)}
                        phx-debounce="blur"
                        class="w-full rounded bg-gray-900 border border-gray-700 px-3 py-1.5 text-sm text-white placeholder-gray-600 focus:border-amber-500 focus:ring-1 focus:ring-amber-500"
                      />
                    </dd>
                  </div>
                <% end %>
              </div>
            </div>

            <div class="flex items-center gap-2 pt-1">
              <button
                type="submit"
                class="px-4 py-2 text-sm font-medium rounded-lg bg-amber-600 text-white hover:bg-amber-500"
              >
                Save & Continue
              </button>
              <button
                type="button"
                phx-click="dismiss_setup"
                class="px-4 py-2 text-sm text-gray-400 hover:text-gray-300"
              >
                Skip
              </button>
              <button
                :if={@setup_component_ref}
                type="button"
                phx-click="open_setup_in_components"
                phx-value-ref={@setup_component_ref}
                class="px-3 py-2 text-xs text-blue-400 hover:text-blue-300"
              >
                Full setup
              </button>
            </div>
          </form>
        </div>

    <!-- Scroll to bottom button -->
      <div id="scroll-anchor" phx-hook="ScrollAnchor" class="relative">
        <button
          id="scroll-to-bottom"
          class="hidden absolute -top-10 left-1/2 -translate-x-1/2 z-10 rounded-full bg-gray-700 hover:bg-gray-600 text-gray-300 p-2 shadow-lg border border-gray-600 transition-opacity"
          aria-label="Scroll to bottom"
        >
          <svg class="w-4 h-4" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M8 3v10M4 9l4 4 4-4" />
          </svg>
        </button>
      </div>

    <!-- Input area -->
      <div class="border-t border-gray-800 pt-4">
        <%!-- Inline orchestrator selector --%>
        <div :if={@orchestrators != []} class="mb-2 relative" id="orchestrator-selector">
          <button
            type="button"
            phx-click="toggle_orchestrator_selector"
            disabled={@running}
            class="inline-flex items-center gap-1 rounded-md border border-gray-700 bg-gray-800 px-2 py-1 text-xs text-gray-400 hover:bg-gray-700 disabled:opacity-50"
          >
            <svg class="h-3 w-3 text-indigo-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M9.813 15.904L9 18.75l-.813-2.846a4.5 4.5 0 00-3.09-3.09L2.25 12l2.846-.813a4.5 4.5 0 003.09-3.09L9 5.25l.813 2.846a4.5 4.5 0 003.09 3.09L15.75 12l-2.846.813a4.5 4.5 0 00-3.09 3.09z" />
            </svg>
            {@active_orchestrator || "Select agent"}
            <svg class="h-3 w-3 text-gray-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M19.5 8.25l-7.5 7.5-7.5-7.5" />
            </svg>
          </button>
          <div
            :if={@orchestrator_selector_open}
            class="absolute bottom-full left-0 z-50 mb-1 min-w-[200px] rounded-lg bg-gray-800 border border-gray-700 py-1 shadow-xl"
          >
            <%= for orch <- @orchestrators do %>
              <button
                type="button"
                phx-click="select_orchestrator"
                phx-value-name={orch["name"]}
                class={"flex w-full items-center gap-2 px-3 py-1.5 text-left text-xs transition-colors hover:bg-gray-700 #{if @active_orchestrator == orch["name"], do: "text-indigo-400", else: "text-gray-400"}"}
              >
                <span class="flex-1 truncate">{orch["title"] || orch["name"]}</span>
                <span class="text-[10px] text-gray-600">{orch["model"]}</span>
              </button>
            <% end %>
          </div>
        </div>

        <form phx-submit="submit" phx-change="validate">
          <div
            class="rounded-lg bg-gray-800 border border-gray-700 focus-within:border-blue-500 focus-within:ring-1 focus-within:ring-blue-500 transition-colors"
            phx-drop-target={@uploads.attachments.ref}
          >
            <%!-- Attachment previews inside the input box --%>
            <div
              :if={@uploads.attachments.entries != []}
              class="flex flex-wrap gap-2 px-3 pt-3"
            >
              <div
                :for={entry <- @uploads.attachments.entries}
                class="flex items-center gap-1.5 rounded-lg bg-gray-700 border border-gray-600 px-2.5 py-1.5 text-xs text-gray-300"
              >
                <svg class="h-3.5 w-3.5 text-gray-400 shrink-0" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M19.5 14.25v-2.625a3.375 3.375 0 0 0-3.375-3.375h-1.5A1.125 1.125 0 0 1 13.5 7.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H8.25m2.25 0H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 0 0-9-9Z" />
                </svg>
                <span class="truncate max-w-[150px]">{entry.client_name}</span>
                <button
                  type="button"
                  phx-click="cancel-upload"
                  phx-value-ref={entry.ref}
                  class="text-gray-500 hover:text-white ml-0.5"
                  aria-label="Remove"
                >
                  &times;
                </button>
                <span :for={err <- upload_errors(@uploads.attachments, entry)} class="text-red-400">
                  {upload_error_to_string(err)}
                </span>
              </div>
            </div>

            <%!-- Textarea row --%>
            <div class="flex items-end gap-2 px-2 py-2">
              <%!-- Attach button --%>
              <label
                class={"shrink-0 inline-flex items-center justify-center rounded-lg w-8 h-8 transition-colors cursor-pointer #{if @running, do: "opacity-50 cursor-not-allowed", else: "text-gray-400 hover:text-gray-200"}"}
                aria-label="Attach file"
              >
                <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
                </svg>
                <.live_file_input upload={@uploads.attachments} class="hidden" />
              </label>

              <textarea
                name="message"
                value={@input}
                phx-change="update_input"
                placeholder={
                  if @running, do: "AQUA is working...", else: "Ask AQUA something..."
                }
                disabled={@running}
                rows="1"
                class="flex-1 bg-transparent border-0 px-1 py-1 text-sm text-white placeholder-gray-500 focus:ring-0 focus:outline-none resize-none disabled:opacity-50 overflow-hidden"
              />

              <%= if @running do %>
                <button
                  type="button"
                  phx-click="stop"
                  class="shrink-0 inline-flex items-center justify-center rounded-lg w-8 h-8 bg-red-600 text-white hover:bg-red-500 transition-colors"
                  aria-label="Stop"
                >
                  <svg class="w-4 h-4" viewBox="0 0 16 16" fill="currentColor">
                    <rect x="4" y="4" width="8" height="8" rx="1" />
                  </svg>
                </button>
              <% else %>
                <button
                  type="submit"
                  disabled={(@input == "" and @uploads.attachments.entries == []) or @orchestrators == []}
                  class="shrink-0 inline-flex items-center justify-center rounded-lg w-8 h-8 bg-blue-600 text-white hover:bg-blue-500 disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
                  aria-label="Send"
                >
                  <svg class="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M6 12L3.269 3.126A59.768 59.768 0 0121.485 12 59.77 59.77 0 013.27 20.876L5.999 12zm0 0h7.5" />
                  </svg>
                </button>
              <% end %>
            </div>
          </div>
        </form>
        <p class="text-xs text-gray-600 mt-2 px-1">
          Enter to send, Shift+Enter for new line &middot; Drop or paste files to attach &middot; @name to target agent
        </p>
      </div>
    </div>

    <%!-- Prompt editor modal overlay --%>
    <div :if={@editor_editing_prompt} class="fixed inset-0 z-50 flex items-center justify-center bg-black/60">
      <div class="w-full max-w-3xl mx-4 rounded-xl bg-gray-900 border border-blue-700 shadow-2xl" phx-click-away="editor_cancel_prompt">
        <div class="flex items-center justify-between px-4 py-3 border-b border-gray-700">
          <span class="text-sm font-medium text-blue-400">Editing prompt: {@editor_editing_prompt}</span>
          <button type="button" phx-click="editor_cancel_prompt" class="text-gray-500 hover:text-gray-300 text-lg">&times;</button>
        </div>
        <form phx-submit="editor_save_prompt" class="p-4">
          <textarea
            name="content"
            rows="20"
            class="w-full bg-gray-800 text-gray-200 text-sm rounded-lg border border-gray-700 p-3 font-mono focus:border-blue-500 focus:ring-1 focus:ring-blue-500 resize-y"
          >{@editor_prompt_content}</textarea>
          <div class="flex justify-end gap-2 mt-3">
            <button type="button" phx-click="editor_cancel_prompt" class="px-4 py-1.5 text-xs bg-gray-700 text-gray-300 rounded-lg hover:bg-gray-600">Cancel</button>
            <button type="submit" class="px-4 py-1.5 text-xs bg-blue-600 text-white rounded-lg hover:bg-blue-500">Save</button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Function components
  # ---------------------------------------------------------------------------

  defp tool_entry_detail(assigns) do
    assigns = assign(assigns, :label, tool_label(assigns.entry))

    ~H"""
    <div id={@id} class="text-xs font-mono">
      <div class="flex items-start gap-2">
        <%= case @entry.status do %>
          <% :running -> %>
            <svg
              class="w-3 h-3 mt-0.5 animate-spin text-blue-400 shrink-0"
              viewBox="0 0 24 24"
              fill="none"
            >
              <circle
                class="opacity-25"
                cx="12"
                cy="12"
                r="10"
                stroke="currentColor"
                stroke-width="4"
              />
              <path
                class="opacity-75"
                fill="currentColor"
                d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
              />
            </svg>
            <span class="text-gray-400">{@label}</span>
          <% :cancelled -> %>
            <span class="text-amber-500 shrink-0 mt-0.5">&#10007;</span>
            <span class="text-gray-500">{@label}</span>
          <% _ -> %>
            <span class="text-green-500 shrink-0 mt-0.5">&#10003;</span>
            <span class="text-gray-500">{@label}</span>
        <% end %>
      </div>
      <%= if @entry[:sub_events] && @entry[:sub_events] != [] do %>
        <details class="sub-agent-group mt-1" open={@entry.status == :running}>
          <summary class="text-xs text-indigo-400 hover:text-indigo-300 cursor-pointer select-none flex items-center gap-1.5">
            {sub_agent_summary(@entry)}
          </summary>
          <div class="mt-1 space-y-0.5">
            <%= for {sub, si} <- Enum.with_index(@entry.sub_events) do %>
              <.sub_event event={sub} id={"#{@id}-sub-#{si}"} />
            <% end %>
          </div>
        </details>
      <% else %>
        <div :if={@entry[:input] || @entry.preview} class="ml-5 mt-0.5 flex gap-3">
          <%= if @entry[:input] do %>
            <details>
              <summary class="text-gray-600 cursor-pointer hover:text-gray-500 select-none">
                input
              </summary>
              <pre class="text-gray-600 whitespace-pre-wrap break-all mt-0.5 text-[11px] max-h-40 overflow-y-auto">{format_tool_input(@entry.input)}</pre>
            </details>
          <% end %>
          <%= if @entry.preview do %>
            <details>
              <summary class="text-gray-600 cursor-pointer hover:text-gray-500 select-none">
                output
              </summary>
              <pre class="text-gray-600 whitespace-pre-wrap break-all mt-0.5 text-[11px] max-h-40 overflow-y-auto">{@entry.preview}</pre>
            </details>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp sub_event(assigns) do
    ~H"""
    <div id={@id} class="text-xs font-mono">
      <%= case @event.kind do %>
        <% :turn_start -> %>
          <span class="text-gray-700">turn {@event.turn}</span>
        <% :tool_use -> %>
          <div class="flex items-center gap-1.5">
            <%= if @event[:status] == :running do %>
              <svg class="w-2.5 h-2.5 animate-spin text-blue-400 shrink-0" viewBox="0 0 24 24" fill="none">
                <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
                <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
              </svg>
            <% else %>
              <span class="text-green-500 shrink-0">&#10003;</span>
            <% end %>
            <span class="text-gray-500">{@event.tool}</span>
          </div>
        <% :tool_result -> %>
          <div class="flex items-center gap-1.5">
            <span class="text-green-500 shrink-0">&#10003;</span>
            <span class="text-gray-500">{@event.tool}</span>
            <span :if={@event[:preview]} class="text-gray-600 truncate max-w-xs">{String.slice(@event.preview, 0..60)}</span>
          </div>
        <% :text_delta -> %>
          <div
            id={"#{@id}-md"}
            phx-hook="MarkdownContent"
            phx-update="ignore"
            data-raw-content={@event.content}
            class="text-gray-300 prose prose-invert max-w-none text-xs"
          >
          </div>
        <% _ -> %>
          <span class="text-gray-600">{inspect(@event)}</span>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Render helpers
  # ---------------------------------------------------------------------------

  # Extract provider name from versionless catalyst ref like "catalyst:moonmoon69.claude"
  defp detect_provider_from_ref(nil), do: nil
  defp detect_provider_from_ref(ref) when is_binary(ref) do
    case Regex.run(~r/catalyst:\w+\.(\w+)/, ref) do
      [_, provider] -> provider
      _ -> nil
    end
  end

  defp role_label("user"), do: "You"
  defp role_label("assistant"), do: "AQUA"
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

  @setup_policy_fields [
    {"allowed_domains", "Allowed Domains", :array},
    {"allowed_methods", "Allowed Methods", :array},
    {"allowed_paths", "Allowed Paths", :array},
    {"allowed_actions", "Allowed Actions", :array},
    {"allowed_private_ips", "Allowed Private IPs", :array},
    {"allowed_tools", "Allowed Tools", :array},
    {"rate_limit", "Rate Limit", :json},
    {"timeout", "Timeout", :string},
    {"max_memory_bytes", "Max Memory", :bytes},
    {"max_request_size", "Max Request Size", :bytes},
    {"max_response_size", "Max Response Size", :bytes},
    {"max_concurrent_tasks", "Max Concurrent Tasks", :string},
    {"batch_timeout", "Batch Timeout", :string}
  ]

  # Fetch setup_plan and build a full pending_setup with secrets + policy inputs
  defp build_full_setup(socket, component_ref) do
    ctx = socket.assigns.context

    plan =
      case Emissary.MCP.ToolRegistry.call("component", ctx, %{
             "action" => "setup_plan",
             "reference" => component_ref
           }) do
        {:ok, result} -> result
        _ -> nil
      end

    secrets = (plan_field(plan, :secrets) || [])

    secret_inputs =
      Enum.reduce(secrets, %{}, fn s, acc ->
        name = setup_field(s, :name)

        if setup_field(s, :already_set) == true do
          grant = if setup_field(s, :already_granted) == true, do: "true", else: "false"
          Map.put(acc, name, grant)
        else
          Map.put(acc, name, "")
        end
      end)

    # Build policy inputs pre-filled with recommended values
    recommended = plan_field(plan, :policy_recommended) || %{}
    current = plan_field(plan, :policy_current) || %{}
    comp_type = plan_field(plan, :type)
    configurable = plan_field(plan, :configurable_fields)

    policy_fields = setup_policy_fields_for(comp_type, configurable)

    policy_inputs =
      Enum.reduce(policy_fields, %{}, fn {field, _label, field_type}, acc ->
        value = setup_policy_value(recommended, field) || setup_policy_value(current, field)

        if value do
          Map.put(acc, field, format_setup_policy(value, field_type))
        else
          acc
        end
      end)

    pending = %{
      component_ref: component_ref,
      plan: plan,
      secrets: secrets,
      secret_inputs: secret_inputs,
      policy_fields: policy_fields,
      policy_inputs: policy_inputs
    }

    last_user_msg =
      socket.assigns.messages
      |> Enum.reverse()
      |> Enum.find_value(fn
        %{role: "user", content: c} -> c
        _ -> nil
      end)

    socket
    |> assign(:pending_setup, pending)
    |> assign(:pending_retry_input, last_user_msg)
    |> assign(:setup_component_ref, component_ref)
    |> assign(:progress, "Setup required")
  end

  defp setup_policy_fields_for(_type, configurable) when is_list(configurable) do
    Enum.filter(@setup_policy_fields, fn {f, _, _} -> f in configurable end)
  end

  defp setup_policy_fields_for(type, _) when is_binary(type) do
    case Sanctum.Policy.FieldSchema.default_configurable_fields(type) do
      {:ok, fields} -> Enum.filter(@setup_policy_fields, fn {f, _, _} -> f in fields end)
      {:error, _} -> @setup_policy_fields
    end
  end

  defp setup_policy_fields_for(_, _), do: @setup_policy_fields

  defp setup_policy_value(policy, field) when is_map(policy) do
    policy[field] || policy[String.to_existing_atom(field)]
  rescue
    ArgumentError -> policy[field]
  end

  defp setup_policy_value(_, _), do: nil

  defp format_setup_policy(value, :array) when is_list(value), do: Enum.join(value, ", ")

  defp format_setup_policy(value, :json) when is_map(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end

  defp format_setup_policy(value, _type), do: to_string(value)

  defp setup_field(c, key) when is_map(c), do: c[key] || c[to_string(key)]
  defp setup_field(_, _), do: nil

  defp plan_field(nil, _key), do: nil
  defp plan_field(plan, key), do: plan[key] || plan[to_string(key)]

  @array_setup_fields ~w(allowed_domains allowed_methods allowed_private_ips allowed_tools allowed_paths allowed_actions)
  defp setup_policy_placeholder("allowed_domains"), do: "api.example.com, api.other.com"
  defp setup_policy_placeholder("allowed_methods"), do: "GET, POST, PUT"
  defp setup_policy_placeholder("allowed_paths"), do: "data/, components/"
  defp setup_policy_placeholder("allowed_actions"), do: "read, write, list, delete"
  defp setup_policy_placeholder("allowed_private_ips"), do: "10.0.0.0/8, 172.16.0.0/12"
  defp setup_policy_placeholder("allowed_tools"), do: "tool1, tool2"
  defp setup_policy_placeholder("rate_limit"), do: ~s({"requests": 100, "window": "1m"})
  defp setup_policy_placeholder("timeout"), do: "3m"
  defp setup_policy_placeholder("max_memory_bytes"), do: "67108864"
  defp setup_policy_placeholder("max_request_size"), do: "1048576"
  defp setup_policy_placeholder("max_response_size"), do: "5242880"
  defp setup_policy_placeholder("max_concurrent_tasks"), do: "10"
  defp setup_policy_placeholder("batch_timeout"), do: "5m"
  defp setup_policy_placeholder(_), do: ""

  defp parse_setup_policy_for_save(value, field) when field in @array_setup_fields do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) ->
        Jason.encode!(list)

      _ ->
        list =
          value
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        Jason.encode!(list)
    end
  end

  defp parse_setup_policy_for_save(value, _field), do: value

  defp running_background_count(bg_executions), do: map_size(bg_executions)

  defp format_message_stats(msg) do
    parts = []
    parts = if msg[:turns], do: parts ++ ["#{msg.turns} turn(s)"], else: parts

    parts =
      if msg[:duration_seconds], do: parts ++ [format_elapsed(msg.duration_seconds)], else: parts

    parts =
      if msg[:token_usage] && (msg.token_usage.input > 0 || msg.token_usage.output > 0),
        do:
          parts ++
            [
              "#{format_tokens(msg.token_usage.input)} in / #{format_tokens(msg.token_usage.output)} out"
            ],
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

  defp sub_agent_summary(entry) do
    sub_events = Map.get(entry, :sub_events, [])
    tool_count = Enum.count(sub_events, &(&1.kind in [:tool_use, :tool_result]))
    role = String.capitalize(entry.tool)

    case entry.status do
      :running -> "#{role} working... (#{tool_count} tool calls)"
      _ -> "#{role} -- #{tool_count} tool calls"
    end
  end

  defp tool_label(entry) do
    tool = entry.tool
    action = get_in_flexible(entry[:input], "action")
    if action, do: "#{tool}(#{action})", else: tool
  end

  defp get_in_flexible(nil, _key), do: nil

  defp get_in_flexible(map, key) when is_map(map) do
    case map[key] do
      nil ->
        try do
          map[String.to_existing_atom(key)]
        rescue
          ArgumentError -> nil
        end

      val ->
        val
    end
  end

  defp get_in_flexible(_, _), do: nil

  defp format_tool_input(input) when is_map(input) or is_list(input) do
    case Jason.encode(input, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(input)
    end
  end

  defp format_tool_input(input) when is_binary(input), do: input
  defp format_tool_input(input), do: inspect(input)

  defp opus_available? do
    Code.ensure_loaded?(Opus) and Code.ensure_loaded?(Opus.ExecutionEventBuffer)
  end
end
