defmodule PrismWeb.AquaLive do
  @moduledoc """
  AQUA — the agent overlay surface.

  A first-class LiveView mounted in the app layout's portal slot. The
  primary entrance is the floating action button (FAB) at the bottom-right;
  Cmd+K is a power-user shortcut.

  ## Sheet states

  - `closed` — overlay hidden, FAB visible
  - `half` — conversation + composer (~55vh)
  - `full` — near-fullscreen (~100vh - 2.5rem)

  Persisted to localStorage by the `Aqua` JS hook so the user's preferred
  size survives reloads.

  ## Active context

  Subscribes to `PrismWeb.ActiveContext.topic(session_id)` on mount and
  receives `{:active_context, ctx}` updates whenever the user navigates.
  The latest context is included in the formula input map under the
  `"active_context"` key so AQUA always knows where the user is.
  """

  use PrismWeb, :live_view

  require Logger

  @compile {:no_warn_undefined, [Opus, Opus.ExecutionEventBuffer]}

  @agent_ref "formula:local.aqua"
  @list_models_ref "formula:local.list-models"

  # Conversation persistence routes through `catalyst:local.files` (see
  # `Prism.AquaConversations`). On-disk shape matches Porta's
  # `apps/porta/src-ui/src/state/conversation-store.ts` so a conversation
  # written from Porta is loadable here, and vice versa.

  @impl true
  def mount(_params, session, socket) do
    socket =
      case PrismWeb.AuthHelpers.authenticate_session(session["session_token"]) do
        {:ok, ctx} ->
          sid = PrismWeb.ActiveContext.session_id(session)

          if connected?(socket) and sid do
            Phoenix.PubSub.subscribe(Emissary.PubSub, PrismWeb.ActiveContext.topic(sid))
            Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.PubSub.topic("prism:setup_complete", ctx))
          end

          socket
          |> assign(:context, ctx)
          |> assign(:aqua_session_id, sid)
          |> assign(:authenticated, true)

        _ ->
          socket
          |> assign(:aqua_session_id, nil)
          |> assign(:authenticated, false)
      end

    {:ok,
     socket
     |> assign(:sheet_state, "closed")
     |> assign(:active_context, nil)
     |> assign(:messages, [])
     # Formula-shape conversation history (string-key maps with provider-canonical
     # content blocks) — separate from :messages (atom-key UI display). Populated
     # by the formula's "conversation_complete" emit; forwarded back as the
     # "messages" input field on subsequent turns for multi-turn memory.
     |> assign(:conversation_history, [])
     |> assign(:input, "")
     |> assign(:running, false)
     |> assign(:streaming_text, "")
     |> assign(:current_execution_id, nil)
     |> assign(:cancel_requested, false)
     |> assign(:orchestrator, nil)
     |> assign(:orchestrators, [])
     |> assign(:orchestrators_loaded, false)
     |> assign(:tool_activity, [])
     |> assign(:token_usage, %{input: 0, output: 0})
     |> assign(:pending_setup, nil)
     |> assign(:conversation_id, Emissary.UUID7.generate_id("conv"))
     |> assign(:conversations, [])
     |> assign(:history_open, false)
     |> assign(:models_by_provider, %{})
     |> assign(:catalyst_refs, %{})
     |> assign(:models_loaded, false)
     |> assign(:model_override, nil)
     |> assign(:view_mode, "chat")
     |> assign(:editor_agents, [])
     |> assign(:editor_editing_prompt, nil)
     |> assign(:editor_prompt_content, "")
     |> assign(:editor_creating_sub_for, nil)
     |> schedule_load_conversations()
     |> allow_upload(:attachments,
       accept: :any,
       max_entries: 10,
       max_file_size: 20_000_000,
       auto_upload: true
     ), layout: false}
  end

  # ============================================================================
  # Events
  # ============================================================================

  @impl true
  def handle_event("set_state", %{"state" => state}, socket)
      when state in ~w(closed half full) do
    socket = if state != "closed", do: ensure_loaded(socket), else: socket
    {:noreply, set_sheet_state(socket, state)}
  end

  def handle_event("toggle", _params, socket) do
    next =
      case socket.assigns.sheet_state do
        "closed" -> "half"
        _ -> "closed"
      end

    socket = if next != "closed", do: ensure_loaded(socket), else: socket
    {:noreply, set_sheet_state(socket, next)}
  end

  def handle_event("update_input", %{"message" => value}, socket) do
    {:noreply, assign(socket, :input, value)}
  end

  # Cancel an in-flight stream. Two cases:
  # 1. exec_id known → unsubscribe + Opus.cancel + preserve partial history.
  # 2. running but exec_id not yet arrived → flag :cancel_requested; the
  #    {:stream_started, ...} handler short-circuits when it sees the flag.
  def handle_event("stop", _params, socket) do
    cond do
      socket.assigns.running && socket.assigns.current_execution_id ->
        exec_id = socket.assigns.current_execution_id
        ctx = socket.assigns[:context]

        if opus_available?() do
          if ctx, do: Opus.ExecutionEventBuffer.unsubscribe(exec_id, ctx)

          case Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
                 if ctx, do: Opus.cancel(ctx, exec_id)
               end) do
            {:ok, _pid} -> :ok
            {:error, reason} ->
              Logger.warning("[AquaLive] Failed to start cancel task: #{inspect(reason)}")
          end
        else
          Logger.warning("[AquaLive] Opus not available, cannot cancel execution #{exec_id}")
        end

        socket =
          socket
          |> maybe_save_partial_as_message()
          |> assign(:conversation_history, build_partial_history(socket))

        {:noreply,
         socket
         |> assign(:running, false)
         |> assign(:streaming_text, "")
         |> assign(:tool_activity, [])
         |> assign(:current_execution_id, nil)
         |> assign(:cancel_requested, false)
         |> save_conversation()}

      socket.assigns.running ->
        {:noreply, assign(socket, :cancel_requested, true)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("submit", params, socket) do
    raw = params["message"] || ""
    message = String.trim(raw)
    has_uploads = socket.assigns.uploads.attachments.entries != []

    cond do
      not socket.assigns[:authenticated] ->
        {:noreply, socket}

      message == "" and not has_uploads ->
        {:noreply, socket}

      socket.assigns.running ->
        {:noreply, socket}

      socket.assigns.orchestrator == nil ->
        {:noreply, put_flash(socket, :error, "No orchestrators configured.")}

      true ->
        attachments = consume_attachments(socket)
        invoke_agent(socket, message, attachments)
    end
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  def handle_event("dismiss_setup", _params, socket) do
    {:noreply, assign(socket, :pending_setup, nil)}
  end

  # Mirror form changes back into pending_setup so the inputs stay sticky
  # if the user toggles other UI before submitting.
  def handle_event("setup_form_change", params, socket) do
    case socket.assigns.pending_setup do
      nil ->
        {:noreply, socket}

      setup ->
        secret_inputs = Map.merge(setup.secret_inputs, params["secret"] || %{})
        policy_inputs = Map.merge(setup.policy_inputs, params["policy"] || %{})

        {:noreply,
         assign(socket, :pending_setup, %{
           setup
           | secret_inputs: secret_inputs,
             policy_inputs: policy_inputs
         })}
    end
  end

  def handle_event("complete_setup", params, socket) do
    setup = socket.assigns.pending_setup
    ctx = socket.assigns.context

    if setup == nil or ctx == nil do
      {:noreply, socket}
    else
      do_complete_setup(socket, setup, ctx, params)
    end
  end

  def handle_event("toggle_history", _params, socket) do
    {:noreply, assign(socket, :history_open, !socket.assigns.history_open)}
  end

  def handle_event("new_conversation", _params, socket) do
    {:noreply,
     socket
     |> assign(:messages, [])
     |> assign(:conversation_history, [])
     |> assign(:streaming_text, "")
     |> assign(:tool_activity, [])
     |> assign(:token_usage, %{input: 0, output: 0})
     |> assign(:pending_setup, nil)
     |> assign(:current_execution_id, nil)
     |> assign(:running, false)
     |> assign(:conversation_id, Emissary.UUID7.generate_id("conv"))}
  end

  def handle_event("load_conversation", %{"id" => id}, socket) do
    {:noreply, do_load_conversation(socket, id)}
  end

  def handle_event("delete_conversation", %{"id" => id}, socket) do
    {:noreply, do_delete_conversation(socket, id)}
  end

  def handle_event("select_model", %{"model" => model}, socket) do
    next = if model == "", do: nil, else: model
    {:noreply, assign(socket, :model_override, next)}
  end

  def handle_event("set_view", %{"view" => view}, socket) when view in ~w(chat agents) do
    # Auto-expand to :full when switching to agents — chat composer is hidden
    # in that view, so half doesn't leave room.
    next_state =
      cond do
        view == "agents" and socket.assigns.sheet_state == "half" -> "full"
        true -> socket.assigns.sheet_state
      end

    socket =
      socket
      |> assign(:view_mode, view)
      |> set_sheet_state(next_state)

    socket = if view == "agents", do: load_editor_agents(socket), else: socket
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Editor — orchestrator + sub-agent CRUD
  # ---------------------------------------------------------------------------

  def handle_event("editor_create_orchestrator", %{"name" => name}, socket) when name != "" do
    ctx = socket.assigns.context

    case Emissary.MCP.ToolRegistry.call("aqua", ctx, %{
           "action" => "create_agent",
           "name" => name,
           "title" => name,
           "content" => "# #{name}\n\nYou are #{name}."
         }) do
      {:ok, _} ->
        send(self(), :editor_refresh)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  def handle_event("editor_create_orchestrator", _params, socket), do: {:noreply, socket}

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
        send(self(), :editor_refresh)
        {:noreply, assign(socket, :editor_creating_sub_for, nil)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  def handle_event("editor_create_sub_agent", _params, socket), do: {:noreply, socket}

  def handle_event("editor_toggle_sub_form", %{"parent" => parent}, socket) do
    next = if socket.assigns.editor_creating_sub_for == parent, do: nil, else: parent
    {:noreply, assign(socket, :editor_creating_sub_for, next)}
  end

  def handle_event("editor_update_field", %{"name" => name, "field" => field, "value" => value}, socket) do
    ctx = socket.assigns.context
    args = %{"action" => "update", "name" => name, field => value}

    case Emissary.MCP.ToolRegistry.call("aqua", ctx, args) do
      {:ok, _} ->
        send(self(), :editor_refresh)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{inspect(reason)}")}
    end
  end

  def handle_event("editor_delete", %{"name" => name}, socket) do
    ctx = socket.assigns.context

    case Emissary.MCP.ToolRegistry.call("aqua", ctx, %{"action" => "delete", "name" => name}) do
      {:ok, _} ->
        send(self(), :editor_refresh)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("editor_toggle_tool", %{"name" => agent_name, "tool" => tool}, socket) do
    ctx = socket.assigns.context
    agent = Enum.find(socket.assigns.editor_agents, &(&1["name"] == agent_name))
    current = agent && agent["visible_tools"]
    new_tools = compute_visible_tools(current, tool)

    case Emissary.MCP.ToolRegistry.call("aqua", ctx, %{
           "action" => "update",
           "name" => agent_name,
           "visible_tools" => new_tools
         }) do
      {:ok, _} ->
        send(self(), :editor_refresh)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{inspect(reason)}")}
    end
  end

  def handle_event("editor_edit_prompt", %{"name" => name}, socket) do
    agent = Enum.find(socket.assigns.editor_agents, &(&1["name"] == name))
    content = if agent, do: agent["content"] || "", else: ""

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
        send(self(), :editor_refresh)
        {:noreply, assign(socket, :editor_editing_prompt, nil)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("editor_set_model", %{"name" => agent_name, "value" => value}, socket) do
    ctx = socket.assigns.context

    case decode_model_choice(value, socket) do
      {:inherit} ->
        Emissary.MCP.ToolRegistry.call("aqua", ctx, %{
          "action" => "update",
          "name" => agent_name,
          "model" => nil,
          "catalyst_ref" => nil
        })

      {:model, provider, model} ->
        catalyst_ref =
          case socket.assigns[:catalyst_refs][provider] do
            nil -> "catalyst:moonmoon69.#{provider}"
            ref -> Regex.replace(~r/:\d+\.\d+\.\d+$/, ref, "")
          end

        Emissary.MCP.ToolRegistry.call("aqua", ctx, %{
          "action" => "update",
          "name" => agent_name,
          "model" => model,
          "catalyst_ref" => catalyst_ref
        })

      :noop ->
        :ok
    end

    send(self(), :editor_refresh)
    {:noreply, socket}
  end

  def handle_event("select_orchestrator", %{"name" => name}, socket) do
    if name == "" do
      {:noreply, socket}
    else
      ctx = socket.assigns[:context]

      orchestrator =
        case Emissary.MCP.ToolRegistry.call("aqua", ctx, %{"action" => "get", "name" => name}) do
          {:ok, detail} ->
            %{
              "name" => name,
              "title" => detail[:title] || detail["title"] || name,
              "catalyst_ref" => detail[:catalyst_ref] || detail["catalyst_ref"],
              "model" => detail[:model] || detail["model"]
            }

          _ ->
            socket.assigns.orchestrator
        end

      # Reset model override when switching orchestrator — different orchestrator
      # implies a different default catalyst/model.
      {:noreply,
       socket
       |> assign(:orchestrator, orchestrator)
       |> assign(:model_override, nil)}
    end
  end

  # ============================================================================
  # PubSub fan-in
  # ============================================================================

  @impl true
  def handle_info({:active_context, ctx}, socket) do
    {:noreply, assign(socket, :active_context, ctx)}
  end

  # Seeded prompt from a cockpit page (e.g. "Ask AQUA about this row" buttons).
  # Open overlay to half if it was closed, lazy-load orchestrators, prefill input.
  def handle_info({:aqua_seed, prompt}, socket) when is_binary(prompt) do
    socket =
      if socket.assigns.orchestrators_loaded, do: socket, else: load_orchestrator(socket)

    next_state =
      case socket.assigns.sheet_state do
        "closed" -> "half"
        s -> s
      end

    {:noreply,
     socket
     |> set_sheet_state(next_state)
     |> assign(:input, prompt)}
  end

  # Editor reloads agents + the chat-side orchestrator picker after any
  # mutation. Cheap — single MCP call per agent.
  def handle_info(:editor_refresh, socket) do
    {:noreply,
     socket
     |> load_editor_agents()
     |> assign(:orchestrators_loaded, false)
     |> load_orchestrator()}
  end

  # Multi-tab safety — pick up sheet-state changes from another tab on the
  # same session. Skip if this tab originated the change (matched value).
  def handle_info({:aqua_state, state}, socket) when state in ~w(closed half full) do
    if state == socket.assigns.sheet_state do
      {:noreply, socket}
    else
      socket = if state != "closed", do: ensure_loaded(socket), else: socket
      {:noreply, assign(socket, :sheet_state, state)}
    end
  end

  def handle_info({:execution_event, %{type: "emit", data: data}}, socket) do
    {:noreply, handle_emit(socket, data["kind"] || data[:kind], data)}
  end

  def handle_info({:execution_event, %{type: "complete"}}, socket) do
    raw = String.trim(socket.assigns.streaming_text)
    %{stripped: stripped, intents: intents, drops: drops} = Prism.AquaActions.parse(raw)

    Enum.each(drops, fn drop ->
      Logger.warning("[AquaLive] dropped aqua-actions intent: #{inspect(drop)}")
    end)

    messages =
      if stripped != "" do
        socket.assigns.messages ++
          [%{role: "assistant", content: stripped, timestamp: DateTime.utc_now()}]
      else
        socket.assigns.messages
      end

    if socket.assigns.current_execution_id do
      Opus.ExecutionEventBuffer.unsubscribe(
        socket.assigns.current_execution_id,
        socket.assigns.context
      )
    end

    socket =
      socket
      |> assign(:messages, messages)
      |> assign(:streaming_text, "")
      |> assign(:running, false)
      |> assign(:current_execution_id, nil)
      |> save_conversation()
      |> push_intents(intents)

    {:noreply, socket}
  end

  def handle_info({:execution_event, %{type: "error", data: data}}, socket) do
    err = data["message"] || data[:message] || inspect(data)

    messages =
      socket.assigns.messages ++
        [%{role: "error", content: err, timestamp: DateTime.utc_now()}]

    if socket.assigns.current_execution_id do
      Opus.ExecutionEventBuffer.unsubscribe(
        socket.assigns.current_execution_id,
        socket.assigns.context
      )
    end

    {:noreply,
     socket
     |> assign(:messages, messages)
     |> assign(:streaming_text, "")
     |> assign(:running, false)
     |> assign(:current_execution_id, nil)}
  end

  # list-models async result. Shape: %{"models" => %{provider => [ids]}, "refs" => %{...}}.
  def handle_info({:list_models_result, {:ok, result}}, socket) do
    raw = result[:result] || result["result"] || result

    decoded =
      cond do
        is_binary(raw) ->
          case Jason.decode(raw) do
            {:ok, m} -> m
            _ -> %{}
          end

        is_map(raw) ->
          raw

        true ->
          %{}
      end

    models_by_provider =
      (decoded["models"] || %{})
      |> Map.new(fn {provider, value} -> {provider, normalize_provider_models(value)} end)

    catalyst_refs = decoded["refs"] || %{}

    {:noreply,
     socket
     |> assign(:models_by_provider, models_by_provider)
     |> assign(:catalyst_refs, catalyst_refs)
     |> assign(:models_loaded, true)}
  end

  def handle_info({:list_models_result, {:error, _reason}}, socket) do
    {:noreply, assign(socket, :models_loaded, true)}
  end

  def handle_info({:stream_started, exec_id}, socket) do
    cond do
      # User hit Stop before exec_id arrived — cancel immediately.
      socket.assigns.cancel_requested ->
        ctx = socket.assigns[:context]

        if opus_available?() and ctx do
          Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
            Opus.cancel(ctx, exec_id)
          end)
        end

        socket =
          socket
          |> maybe_save_partial_as_message()
          |> assign(:conversation_history, build_partial_history(socket))

        {:noreply,
         socket
         |> assign(:running, false)
         |> assign(:streaming_text, "")
         |> assign(:tool_activity, [])
         |> assign(:current_execution_id, nil)
         |> assign(:cancel_requested, false)
         |> save_conversation()}

      true ->
        if opus_available?() do
          Opus.ExecutionEventBuffer.subscribe(exec_id, socket.assigns.context)
        end

        {:noreply, assign(socket, :current_execution_id, exec_id)}
    end
  end

  def handle_info({:stream_error, reason}, socket) do
    err = "Execution failed: #{inspect(reason)}"

    messages =
      socket.assigns.messages ++
        [%{role: "error", content: err, timestamp: DateTime.utc_now()}]

    {:noreply,
     socket
     |> assign(:messages, messages)
     |> assign(:running, false)}
  end

  # External setup completion (e.g., user filled the setup form in /components).
  # Clear the pending banner so the user can retry from AQUA without the
  # stale "setup required" warning.
  def handle_info({:setup_complete, _component_ref}, socket) do
    {:noreply, assign(socket, :pending_setup, nil)}
  end

  # Async conversation index load result (kicked off in mount/3).
  def handle_info({:aqua_conversations_loaded, {:ok, entries}}, socket) do
    conversations =
      entries
      |> Enum.map(fn e ->
        %{
          id: e["id"],
          title: e["title"] || "Untitled",
          updated_at: parse_ts(e["updated_at"])
        }
      end)
      |> Enum.reject(fn c -> is_nil(c.id) end)
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

    {:noreply, assign(socket, :conversations, conversations)}
  end

  def handle_info({:aqua_conversations_loaded, {:error, reason}}, socket) do
    Logger.warning("[AquaLive] Failed to load conversations: #{inspect(reason)}")
    {:noreply, socket}
  end

  # Stale guard for the list-models async call. Idempotent vs. the result
  # message — whichever arrives first flips :models_loaded.
  def handle_info({:task_timeout, :models}, socket) do
    if socket.assigns.models_loaded do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :models_loaded, true)}
    end
  end

  def handle_info(msg, socket) do
    Logger.debug("[AquaLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ============================================================================
  # Agent invocation
  # ============================================================================

  # ---------------------------------------------------------------------------
  # Emit dispatch — simplified port from PrismWeb.AgentLive.handle_parent_event
  #
  # Captures the user-visible signals (text deltas, tool chips, token totals)
  # without the segment/sub-agent complexity AgentLive maintains. A follow-up
  # slice can extend this to per-turn segments and @-mention sub-agent
  # routing once the overlay's render real estate justifies the depth.
  # ---------------------------------------------------------------------------

  defp handle_emit(socket, "text_delta", data) do
    content = data["content"] || data[:content] || ""
    assign(socket, :streaming_text, socket.assigns.streaming_text <> content)
  end

  defp handle_emit(socket, "tool_use", data) do
    tool = data["tool"] || data[:tool] || "tool"
    entry = %{tool: tool, status: :running, preview: nil}
    assign(socket, :tool_activity, socket.assigns.tool_activity ++ [entry])
  end

  defp handle_emit(socket, "tool_result", data) do
    tool = data["tool"] || data[:tool] || "tool"
    preview = data["preview"] || data[:preview]
    assign(socket, :tool_activity, mark_tool_done(socket.assigns.tool_activity, tool, preview))
  end

  defp handle_emit(socket, kind, data) when kind in ["setup_required", "request_setup"] do
    ref = data["component_ref"] || data[:component_ref] || ""

    if ref == "" do
      socket
    else
      build_full_setup(socket, ref)
    end
  end

  defp handle_emit(socket, "usage", data) do
    input = data["input_tokens"] || data[:input_tokens] || 0
    output = data["output_tokens"] || data[:output_tokens] || 0
    current = socket.assigns.token_usage

    assign(socket, :token_usage, %{
      input: current.input + input,
      output: current.output + output
    })
  end

  # Formula's full conversation history (provider-canonical shape). Stash for
  # forwarding on the next turn so the agent has multi-turn memory.
  defp handle_emit(socket, "conversation_complete", data) do
    messages = data["messages"] || data[:messages] || []
    assign(socket, :conversation_history, messages)
  end

  # Backward-compat shim: pre-`kind` emit events delivered text directly
  # under the `text` key. Treat that as a text_delta so existing flows
  # continue to render while richer events become wired up.
  defp handle_emit(socket, _kind, %{} = data) when is_map_key(data, "text") do
    chunk = data["text"] || ""
    assign(socket, :streaming_text, socket.assigns.streaming_text <> chunk)
  end

  defp handle_emit(socket, _kind, _data), do: socket

  defp mark_tool_done(activity, tool, preview) do
    target =
      activity
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find(fn {e, _i} -> e.tool == tool and e.status == :running end)

    case target do
      {_entry, idx} ->
        List.update_at(activity, idx, fn e -> %{e | status: :done, preview: preview} end)

      nil ->
        activity ++ [%{tool: tool, status: :done, preview: preview}]
    end
  end

  defp consume_attachments(socket) do
    consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
      # arca:bypass-ok=D — Plug-managed upload tmp file (same as AgentLive).
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
      require Logger
      Logger.warning("[AquaLive] consume uploads failed: #{inspect(e)}")
      []
  end

  defp invoke_agent(socket, message, attachments) do
    ctx = socket.assigns.context

    # @-mention routing: an explicit `@name` in the message switches the
    # orchestrator for this turn (and going forward) without a separate UI step.
    {message, mentioned} =
      parse_orchestrator_mention(message, socket.assigns.orchestrators)

    socket =
      if mentioned do
        case Enum.find(socket.assigns.orchestrators, &(&1["name"] == mentioned)) do
          %{"name" => name} ->
            assign(socket, :orchestrator, load_orchestrator_detail(ctx, name))

          _ ->
            socket
        end
      else
        socket
      end

    orchestrator = socket.assigns.orchestrator
    orchestrator_name = orchestrator["name"]

    user_msg = %{
      role: "user",
      content: message,
      timestamp: DateTime.utc_now()
    }

    # Append the aqua-actions text-intent protocol only at the orchestrator
    # call-site. Sub-agents (Builder, Artisan, Arcade, Explorer, Planner, Web)
    # are scoped task-runners — they should never emit UI intents.
    system_prompt =
      Prism.AgentConfig.build_system_prompt(ctx, orchestrator_name) <>
        Prism.AquaActions.system_prelude()

    resolved_catalyst =
      case Prism.AgentConfig.resolve_catalyst(ctx, orchestrator["catalyst_ref"]) do
        {:ok, ref} -> ref
        _ -> orchestrator["catalyst_ref"]
      end

    sub_agents =
      Prism.AgentConfig.sub_agent_definitions(
        ctx,
        orchestrator_name,
        resolved_catalyst,
        orchestrator["model"]
      )

    effective_model = socket.assigns.model_override || orchestrator["model"]

    input =
      %{
        "task" => message,
        "system" => system_prompt,
        "sub_agents" => sub_agents,
        "catalyst_ref" => resolved_catalyst,
        "model" => effective_model
      }
      |> maybe_put_active_context(socket.assigns.active_context)
      |> maybe_put_attachments(attachments)
      |> maybe_put_messages(socket.assigns.conversation_history)

    lv = self()

    Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
      result =
        Emissary.MCP.ToolRegistry.call("execution", ctx, %{
          "action" => "run_stream",
          "reference" => @agent_ref,
          "input" => input
        })

      case result do
        {:ok, %{execution_id: eid}} -> send(lv, {:stream_started, eid})
        {:ok, %{"execution_id" => eid}} -> send(lv, {:stream_started, eid})
        {:error, reason} -> send(lv, {:stream_error, reason})
      end
    end)

    {:noreply,
     socket
     |> assign(:messages, socket.assigns.messages ++ [user_msg])
     |> assign(:input, "")
     |> assign(:running, true)
     |> assign(:streaming_text, "")
     |> assign(:tool_activity, [])
     |> assign(:token_usage, %{input: 0, output: 0})}
  end

  defp maybe_put_active_context(input, nil), do: input
  defp maybe_put_active_context(input, ctx), do: Map.put(input, "active_context", ctx)

  defp maybe_put_attachments(input, []), do: input
  defp maybe_put_attachments(input, attachments), do: Map.put(input, "attachments", attachments)

  defp maybe_put_messages(input, []), do: input

  defp maybe_put_messages(input, history) when is_list(history) do
    cleaned = Enum.map(history, &strip_actions_in_message/1)
    Map.put(input, "messages", Prism.ConversationCompactor.compact(cleaned))
  end

  defp maybe_put_messages(input, _), do: input

  # Strip aqua-actions blocks from any assistant text blocks before
  # forwarding history back to the formula. Otherwise the model re-encounters
  # its own block on the next turn and may copy-paste the literal JSON
  # instead of treating it as already-executed.
  defp strip_actions_in_message(%{"role" => "assistant", "content" => content} = msg)
       when is_binary(content) do
    %{msg | "content" => Prism.AquaActions.strip_blocks(content)}
  end

  defp strip_actions_in_message(%{"role" => "assistant", "content" => parts} = msg)
       when is_list(parts) do
    %{msg | "content" => Enum.map(parts, &strip_actions_in_part/1)}
  end

  defp strip_actions_in_message(msg), do: msg

  defp strip_actions_in_part(%{"type" => "text", "text" => text} = part) when is_binary(text) do
    %{part | "text" => Prism.AquaActions.strip_blocks(text)}
  end

  defp strip_actions_in_part(part), do: part

  defp push_intents(socket, []), do: socket

  defp push_intents(socket, intents) do
    push_event(socket, "aqua:intents", %{intents: intents})
  end

  # ---------------------------------------------------------------------------
  # Stop / cancel helpers
  # ---------------------------------------------------------------------------

  defp maybe_save_partial_as_message(socket) do
    streaming = socket.assigns.streaming_text

    if streaming != "" do
      msg = %{
        role: "assistant",
        content: streaming <> "\n\n_(cancelled)_",
        timestamp: DateTime.utc_now()
      }

      assign(socket, :messages, socket.assigns.messages ++ [msg])
    else
      socket
    end
  end

  # Build a partial conversation history when we cancel mid-stream. The formula
  # only emits "conversation_complete" on a clean finish; on cancel we
  # synthesise the user turn + the truncated assistant turn so the next
  # message keeps context.
  defp build_partial_history(socket) do
    existing = socket.assigns.conversation_history
    messages = socket.assigns.messages
    streaming = socket.assigns.streaming_text

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

  defp opus_available?, do: Code.ensure_loaded?(Opus.ExecutionEventBuffer)

  # Set sheet state and broadcast to other tabs on the same session.
  # Last-write-wins is fine — the browser-local localStorage cache via the
  # JS hook keeps each tab's preference sticky across reloads.
  defp set_sheet_state(socket, state) do
    if state != socket.assigns.sheet_state do
      case socket.assigns[:aqua_session_id] do
        sid when is_binary(sid) ->
          Phoenix.PubSub.broadcast(
            Emissary.PubSub,
            PrismWeb.ActiveContext.topic(sid),
            {:aqua_state, state}
          )

        _ ->
          :ok
      end
    end

    assign(socket, :sheet_state, state)
  end

  # ---------------------------------------------------------------------------
  # Setup interception — port from AgentLive's build_full_setup + complete_setup.
  # The form is rendered inline above the composer when @pending_setup is set;
  # auto-retry of the prior user input is omitted vs AgentLive (the user can
  # resend the prompt themselves once setup completes).
  # ---------------------------------------------------------------------------

  @setup_policy_fields [
    {"allowed_domains", "Allowed Domains", :array},
    {"allowed_methods", "Allowed Methods", :array},
    {"allowed_paths", "Allowed Paths", :array},
    {"allowed_actions", "Allowed Actions", :array},
    {"allowed_tools", "Allowed Tools", :array},
    {"allowed_private_ips", "Allowed Private IPs", :array},
    {"rate_limit", "Rate Limit", :json},
    {"timeout", "Timeout", :string},
    {"max_memory_bytes", "Max Memory", :bytes},
    {"max_request_size", "Max Request Size", :bytes},
    {"max_response_size", "Max Response Size", :bytes},
    {"max_concurrent_tasks", "Max Concurrent Tasks", :string},
    {"batch_timeout", "Batch Timeout", :string}
  ]

  @array_setup_fields ~w(allowed_domains allowed_methods allowed_private_ips allowed_tools allowed_paths allowed_actions)

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

    secrets = plan_field(plan, :secrets) || []

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

    recommended = plan_field(plan, :policy_recommended) || %{}
    current = plan_field(plan, :policy_current) || %{}
    comp_type = plan_field(plan, :type)
    configurable = plan_field(plan, :configurable_fields)
    policy_fields = setup_policy_fields_for(comp_type, configurable)

    policy_inputs =
      Enum.reduce(policy_fields, %{}, fn {field, _label, field_type}, acc ->
        value = setup_policy_value(recommended, field) || setup_policy_value(current, field)
        if value, do: Map.put(acc, field, format_setup_policy(value, field_type)), else: acc
      end)

    pending = %{
      component_ref: component_ref,
      plan: plan,
      secrets: secrets,
      secret_inputs: secret_inputs,
      policy_fields: policy_fields,
      policy_inputs: policy_inputs
    }

    assign(socket, :pending_setup, pending)
  end

  defp do_complete_setup(socket, setup, ctx, params) do
    ref = setup.component_ref
    secrets_map = params["secret"] || %{}
    policy_map = params["policy"] || %{}

    secret_errors =
      Enum.reduce(secrets_map, [], fn {name, value}, errors ->
        secret_status = Enum.find(setup.secrets || [], fn s -> setup_field(s, :name) == name end)
        already_set? = secret_status && setup_field(secret_status, :already_set) == true

        cond do
          already_set? and value == "true" ->
            apply_secret_action(ctx, "grant", %{"name" => name, "component_ref" => ref}, name, errors)

          already_set? ->
            errors

          String.trim(value) != "" ->
            case Emissary.MCP.ToolRegistry.call("secret", ctx, %{
                   "action" => "set",
                   "name" => name,
                   "value" => value
                 }) do
              {:ok, _} ->
                apply_secret_action(
                  ctx,
                  "grant",
                  %{"name" => name, "component_ref" => ref},
                  name,
                  errors
                )

              {:error, reason} ->
                ["#{name}: #{inspect(reason)}" | errors]
            end

          true ->
            errors
        end
      end)

    policy_errors =
      Enum.reduce(policy_map, [], fn {field, value}, errors ->
        if String.trim(value) != "" do
          encoded = parse_setup_policy_for_save(value, field)

          case Emissary.MCP.ToolRegistry.call("policy", ctx, %{
                 "action" => "update_field",
                 "component_ref" => ref,
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

    confirm =
      if all_errors == [],
        do: "Setup complete for #{ref}.",
        else: "Setup partially complete for #{ref}. Errors: #{Enum.join(all_errors, "; ")}"

    {:noreply,
     socket
     |> assign(
       :messages,
       socket.assigns.messages ++
         [%{role: "assistant", content: confirm, timestamp: DateTime.utc_now()}]
     )
     |> assign(:pending_setup, nil)}
  end

  defp apply_secret_action(ctx, action, args, name, errors) do
    case Emissary.MCP.ToolRegistry.call("secret", ctx, Map.put(args, "action", action)) do
      {:ok, _} -> errors
      {:error, reason} -> ["#{name} #{action}: #{inspect(reason)}" | errors]
    end
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
      _ -> inspect(value)
    end
  end

  defp format_setup_policy(value, _type), do: to_string(value)

  defp setup_field(c, key) when is_map(c), do: c[key] || c[to_string(key)]
  defp setup_field(_, _), do: nil

  defp plan_field(nil, _key), do: nil
  defp plan_field(plan, key), do: plan[key] || plan[to_string(key)]

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

  # ---------------------------------------------------------------------------
  # Editor helpers — orchestrator + sub-agent CRUD
  # ---------------------------------------------------------------------------

  @available_tools ~w(component build execution aqua secret policy system request_setup files storage schedule http oauth native_search)

  def available_tools, do: @available_tools

  defp load_editor_agents(socket) do
    ctx = socket.assigns[:context]

    agents =
      case ctx && Emissary.MCP.ToolRegistry.call("aqua", ctx, %{"action" => "list"}) do
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

    assign(socket, :editor_agents, agents)
  end

  # Compute new visible_tools list for an agent. nil = unrestricted (all tools).
  # native_search is exclusive: when on, it's the only tool; toggling off
  # other tools clears native_search if set.
  defp compute_visible_tools(current, "native_search") do
    cond do
      current == nil -> ["native_search"]
      "native_search" in current -> []
      true -> ["native_search"]
    end
  end

  defp compute_visible_tools(nil, tool), do: @available_tools -- [tool]

  defp compute_visible_tools(current, tool) when is_list(current) do
    cond do
      tool in current -> List.delete(current, tool) -- ["native_search"]
      true -> (current -- ["native_search"]) ++ [tool]
    end
  end

  # Decode the model dropdown's combined "provider::model" value back into a
  # provider+model pair. "" = inherit from parent. Anything else = noop.
  defp decode_model_choice("", _socket), do: {:inherit}

  defp decode_model_choice(value, _socket) when is_binary(value) do
    case String.split(value, "::", parts: 2) do
      [provider, model] when provider != "" and model != "" -> {:model, provider, model}
      _ -> :noop
    end
  end

  defp decode_model_choice(_, _), do: :noop

  # The Edit-prompt textarea stores its draft client-side via phx-change so
  # cancel/save round-trips don't lose unsaved keystrokes.
  defp agent_provider_for_select(agent) do
    detect_provider_from_ref(agent["catalyst_ref"])
  end

  defp detect_provider_from_ref(nil), do: nil
  defp detect_provider_from_ref(""), do: nil

  defp detect_provider_from_ref(ref) when is_binary(ref) do
    # ref shape: "catalyst:moonmoon69.claude" or with version suffix
    case Regex.run(~r/catalyst:[^.]+\.([^:]+)/, ref) do
      [_, provider] -> provider
      _ -> nil
    end
  end

  defp tool_label(tool), do: tool

  # Lazy-load orchestrators + models on first open. Both are async-safe
  # against subsequent re-opens via the `*_loaded` assigns.
  defp ensure_loaded(socket) do
    socket
    |> maybe_load_orchestrators()
    |> maybe_load_models()
  end

  defp maybe_load_orchestrators(socket) do
    if socket.assigns.orchestrators_loaded, do: socket, else: load_orchestrator(socket)
  end

  defp maybe_load_models(socket) do
    if socket.assigns.models_loaded or socket.assigns[:context] == nil do
      socket
    else
      lv = self()
      ctx = socket.assigns.context

      Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
        result =
          Emissary.MCP.ToolRegistry.call("execution", ctx, %{
            "action" => "run",
            "reference" => @list_models_ref,
            "input" => %{},
            "type" => "formula"
          })

        send(lv, {:list_models_result, result})
      end)

      # Guard rail — if list-models hangs we still flip models_loaded so the UI
      # falls back to the orchestrator's default model instead of an empty picker.
      Process.send_after(self(), {:task_timeout, :models}, 60_000)

      socket
    end
  end

  defp flatten_models(models_by_provider) when is_map(models_by_provider) do
    Enum.flat_map(models_by_provider, fn
      {_p, models} when is_list(models) ->
        Enum.map(models, fn
          m when is_binary(m) -> m
          %{"id" => id} -> id
          %{id: id} -> id
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end)
  end

  defp flatten_models(_), do: []

  # Catalysts return their list-models response verbatim — typically a list
  # of `%{"id" => ...}` objects, sometimes wrapped in a `{"data": [...]}`
  # envelope (Anthropic/OpenAI shape). Reduce to a plain list of model ids
  # so the templates can iterate without sniffing shape.
  defp normalize_provider_models(value) do
    cond do
      is_list(value) -> Enum.map(value, &model_id/1) |> Enum.reject(&is_nil/1)
      is_map(value) and is_list(value["data"]) -> normalize_provider_models(value["data"])
      true -> []
    end
  end

  defp model_id(m) when is_binary(m), do: m
  defp model_id(%{"id" => id}) when is_binary(id), do: id
  defp model_id(%{id: id}) when is_binary(id), do: id
  defp model_id(_), do: nil

  # Detect an explicit `@name` token in the user message and pull it out so
  # the agent can route to the named orchestrator. Mirrors AgentLive's parser.
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

  # ---------------------------------------------------------------------------
  # Conversation persistence — routed through `catalyst:local.files`.
  #
  # On-disk shape matches Porta (data/agent_conversations/<id>.json plus
  # data/agent_conversations/index.json with %{"entries" => [...]}). Both
  # surfaces share files and the index, so a conversation written by one is
  # loadable by the other. Going through the files catalyst (rather than
  # direct Arca calls) puts every read/write through Opus' policy
  # enforcement and surfaces them in /executions, matching what Porta does
  # in apps/porta/src-ui/src/state/conversation-store.ts.
  # ---------------------------------------------------------------------------

  # Async first-load — kicked off after mount so we don't block the
  # initial render. The catalyst call goes through Opus.run which can
  # take a few hundred ms.
  defp schedule_load_conversations(socket) do
    case socket.assigns[:context] do
      %Sanctum.Context{} = ctx ->
        lv = self()

        Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
          result = Prism.AquaConversations.read_index_or_rebuild(ctx)
          send(lv, {:aqua_conversations_loaded, result})
        end)

        socket

      _ ->
        socket
    end
  end

  defp save_conversation(socket) do
    ctx = socket.assigns[:context]
    id = socket.assigns.conversation_id
    messages = socket.assigns.messages

    cond do
      ctx == nil -> socket
      id == nil -> socket
      messages == [] -> socket
      true -> do_save_conversation(socket, ctx, id, messages)
    end
  end

  defp do_save_conversation(socket, ctx, id, messages) do
    title = first_user_title(messages)
    now_iso = DateTime.to_iso8601(DateTime.utc_now())

    conv_data = %{
      "id" => id,
      "title" => title,
      "created_at" =>
        case List.first(messages) do
          %{timestamp: ts} -> DateTime.to_iso8601(ts)
          _ -> now_iso
        end,
      "updated_at" => now_iso,
      "messages" => Enum.map(messages, &serialize_message/1),
      "conversation_history" => socket.assigns.conversation_history,
      "running" => socket.assigns.running,
      "execution_id" => socket.assigns.current_execution_id,
      "default_orchestrator" =>
        case socket.assigns.orchestrator do
          %{"name" => n} -> n
          _ -> nil
        end
    }

    index_entry = %{"id" => id, "title" => title, "updated_at" => now_iso, "status" => "idle"}

    Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
      with :ok <- Prism.AquaConversations.write_conversation(ctx, id, conv_data) do
        existing =
          case Prism.AquaConversations.read_index(ctx) do
            {:ok, entries} -> entries
            _ -> []
          end

        Prism.AquaConversations.write_index(ctx, upsert_entry(existing, index_entry))
      end
    end)

    in_memory =
      %{id: id, title: title, updated_at: DateTime.utc_now()}
      |> upsert_in_memory(socket.assigns.conversations)

    assign(socket, :conversations, in_memory)
  end

  defp do_load_conversation(socket, id) do
    case socket.assigns[:context] do
      %Sanctum.Context{} = ctx ->
        case Prism.AquaConversations.read_conversation(ctx, id) do
          {:ok, %{"messages" => messages} = data} when is_list(messages) ->
            deserialized = Enum.map(messages, &deserialize_message/1)
            history = data["conversation_history"] || []

            socket
            |> assign(:conversation_id, id)
            |> assign(:messages, deserialized)
            |> assign(:conversation_history, history)
            |> assign(:streaming_text, "")
            |> assign(:tool_activity, [])
            |> assign(:token_usage, %{input: 0, output: 0})
            |> assign(:pending_setup, nil)
            |> assign(:current_execution_id, nil)
            |> assign(:running, false)

          _ ->
            socket
        end

      _ ->
        socket
    end
  end

  defp do_delete_conversation(socket, id) do
    ctx = socket.assigns[:context]

    if ctx do
      Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
        Prism.AquaConversations.delete_conversation(ctx, id)

        existing =
          case Prism.AquaConversations.read_index(ctx) do
            {:ok, entries} -> entries
            _ -> []
          end

        kept = Enum.reject(existing, fn e -> e["id"] == id end)
        Prism.AquaConversations.write_index(ctx, kept)
      end)
    end

    socket =
      assign(
        socket,
        :conversations,
        Enum.reject(socket.assigns.conversations, fn c -> c.id == id end)
      )

    if socket.assigns.conversation_id == id do
      socket
      |> assign(:messages, [])
      |> assign(:streaming_text, "")
      |> assign(:tool_activity, [])
      |> assign(:token_usage, %{input: 0, output: 0})
      |> assign(:conversation_id, Emissary.UUID7.generate_id("conv"))
    else
      socket
    end
  end

  defp first_user_title(messages) do
    Enum.find_value(messages, "New conversation", fn
      %{role: "user", content: c} when is_binary(c) -> String.slice(c, 0..80)
      _ -> nil
    end)
  end

  defp serialize_message(%{} = msg) do
    %{
      "role" => msg.role,
      "content" => msg.content,
      "timestamp" => DateTime.to_iso8601(msg.timestamp)
    }
  end

  defp deserialize_message(%{"role" => role, "content" => content} = m) do
    %{
      role: role,
      content: content,
      timestamp: parse_ts(m["timestamp"])
    }
  end

  defp deserialize_message(_), do: %{role: "assistant", content: "", timestamp: DateTime.utc_now()}

  defp parse_ts(nil), do: DateTime.utc_now()

  defp parse_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_ts(_), do: DateTime.utc_now()

  defp upsert_entry(entries, %{"id" => id} = new_entry) do
    if Enum.any?(entries, fn e -> e["id"] == id end) do
      Enum.map(entries, fn e -> if e["id"] == id, do: new_entry, else: e end)
    else
      [new_entry | entries]
    end
  end

  defp upsert_in_memory(%{id: id} = new_entry, conversations) do
    if Enum.any?(conversations, fn c -> c.id == id end) do
      Enum.map(conversations, fn c -> if c.id == id, do: new_entry, else: c end)
    else
      [new_entry | conversations]
    end
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
  end

  defp load_orchestrator(socket) do
    ctx = socket.assigns[:context]

    if ctx == nil do
      assign(socket, :orchestrators_loaded, true)
    else
      list_result =
        Emissary.MCP.ToolRegistry.call("aqua", ctx, %{
          "action" => "list",
          "type" => "orchestrator"
        })

      orchestrators =
        case list_result do
          {:ok, result} ->
            (result[:guides] || result["guides"] || [])
            |> Enum.map(fn g ->
              %{
                "name" => g[:name] || g["name"],
                "title" => g[:title] || g["title"] || g[:name] || g["name"]
              }
            end)
            |> Enum.reject(fn g -> is_nil(g["name"]) end)

          _ ->
            []
        end

      orchestrator =
        case orchestrators do
          [%{"name" => first_name} | _] -> load_orchestrator_detail(ctx, first_name)
          _ -> nil
        end

      socket
      |> assign(:orchestrator, orchestrator)
      |> assign(:orchestrators, orchestrators)
      |> assign(:orchestrators_loaded, true)
    end
  end

  defp load_orchestrator_detail(ctx, name) do
    case Emissary.MCP.ToolRegistry.call("aqua", ctx, %{"action" => "get", "name" => name}) do
      {:ok, detail} ->
        %{
          "name" => name,
          "title" => detail[:title] || detail["title"] || name,
          "catalyst_ref" => detail[:catalyst_ref] || detail["catalyst_ref"],
          "model" => detail[:model] || detail["model"]
        }

      _ ->
        nil
    end
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="aqua-root"
      phx-hook="Aqua"
      data-state={@sheet_state}
    >
      <!-- FAB — primary entrance. Hidden when overlay is open. The data-aqua
           attribute is the seam for future animation states (idle, thinking,
           pending-consent, error) that can flip without a re-mount. -->
      <button
        :if={@sheet_state == "closed"}
        type="button"
        phx-click="toggle"
        data-aqua="idle"
        title="Open AQUA  ⌘K"
        aria-label="Open AQUA"
        class="fixed bottom-6 right-6 z-30 flex h-14 w-14 items-center justify-center rounded-full border border-gray-700 bg-gray-900 shadow-lg ring-1 ring-black/40 transition-transform hover:scale-105 hover:border-blue-500/60 focus:outline-none focus:ring-2 focus:ring-blue-500/60"
      >
        <img src={~p"/images/logo.png"} alt="" class="h-9 w-9 rounded-full" />
      </button>

      <div
        :if={@sheet_state != "closed"}
        class="fixed inset-0 z-40 bg-black/40"
        phx-click="set_state"
        phx-value-state="closed"
      ></div>

      <section
        :if={@sheet_state != "closed"}
        class={[
          "fixed inset-x-0 bottom-0 z-40 flex flex-col",
          "border-t border-gray-700 bg-gray-900 shadow-2xl rounded-t-xl",
          "transition-all duration-200",
          sheet_class(@sheet_state)
        ]}
      >
        <header class="flex items-center justify-between border-b border-gray-800 px-4 py-2">
          <div class="flex items-center gap-2 min-w-0">
            <span class="text-sm font-medium text-gray-200 shrink-0">A.Q.U.A.</span>
            <select
              :if={@orchestrators != []}
              phx-change="select_orchestrator"
              name="name"
              class="bg-transparent text-xs text-gray-400 hover:text-gray-200 border-none focus:ring-0 focus:outline-none cursor-pointer max-w-[14rem] truncate"
              title="Switch orchestrator"
            >
              <option
                :for={o <- @orchestrators}
                value={o["name"]}
                selected={@orchestrator && @orchestrator["name"] == o["name"]}
              >
                {o["title"]}
              </option>
            </select>
            <span :if={!@orchestrator && @orchestrators_loaded && @orchestrators == []} class="text-xs text-amber-400">
              No orchestrator configured
            </span>
            <select
              :if={@sheet_state in ["half", "full"] and @models_loaded and flatten_models(@models_by_provider) != []}
              phx-change="select_model"
              name="model"
              class="bg-transparent text-[10px] text-gray-600 hover:text-gray-300 border-none focus:ring-0 focus:outline-none cursor-pointer max-w-[14rem] truncate font-mono"
              title="Override model"
            >
              <option value="" selected={is_nil(@model_override)}>
                {@orchestrator && @orchestrator["model"] || "default"}
              </option>
              <%= for {provider, models} <- @models_by_provider, models != [] do %>
                <optgroup label={provider}>
                  <option
                    :for={m <- models}
                    value={m}
                    selected={@model_override == m}
                  >
                    {m}
                  </option>
                </optgroup>
              <% end %>
            </select>
            <span :if={!(@sheet_state in ["half", "full"] and @models_loaded and flatten_models(@models_by_provider) != []) and @orchestrator && @orchestrator["model"]} class="text-[10px] text-gray-600 font-mono truncate">
              {@orchestrator["model"]}
            </span>
          </div>
          <div class="flex items-center gap-1">
            <div :if={@sheet_state == "full"} class="flex items-center mr-2">
              <button
                type="button"
                phx-click="set_view"
                phx-value-view="chat"
                class={[
                  "rounded-l px-2 py-1 text-[11px] uppercase tracking-wider border border-r-0 border-gray-700",
                  if(@view_mode == "chat",
                    do: "bg-blue-900/40 text-blue-200 border-blue-700",
                    else: "text-gray-500 hover:bg-gray-800 hover:text-gray-300"
                  )
                ]}
              >
                Chat
              </button>
              <button
                type="button"
                phx-click="set_view"
                phx-value-view="agents"
                class={[
                  "rounded-r px-2 py-1 text-[11px] uppercase tracking-wider border border-gray-700",
                  if(@view_mode == "agents",
                    do: "bg-blue-900/40 text-blue-200 border-blue-700",
                    else: "text-gray-500 hover:bg-gray-800 hover:text-gray-300"
                  )
                ]}
              >
                Agents
              </button>
            </div>
            <button
              :if={@sheet_state in ["half", "full"] and @view_mode == "chat"}
              type="button"
              phx-click="toggle_history"
              class={[
                "rounded px-2 py-1 text-[11px] uppercase tracking-wider",
                if(@history_open,
                  do: "bg-gray-800 text-gray-200",
                  else: "text-gray-500 hover:bg-gray-800 hover:text-gray-300"
                )
              ]}
              title="Toggle conversation history"
            >
              History
            </button>
            <button
              :if={@sheet_state in ["half", "full"] and @view_mode == "chat"}
              type="button"
              phx-click="new_conversation"
              class="rounded px-2 py-1 text-[11px] uppercase tracking-wider text-gray-500 hover:bg-gray-800 hover:text-gray-300"
              title="Start a new conversation"
            >
              New
            </button>
            <span :if={@sheet_state in ["half", "full"] and @view_mode == "chat"} class="mx-1 h-4 w-px bg-gray-800" />
            <.sheet_toggle current={@sheet_state} value="half" label="Half" />
            <.sheet_toggle current={@sheet_state} value="full" label="Full" />
            <button
              phx-click="set_state"
              phx-value-state="closed"
              class="ml-1 rounded p-1 text-gray-500 hover:bg-gray-800 hover:text-gray-300"
              title="Close (Esc)"
            >
              <svg class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
        </header>

        <div :if={@sheet_state in ["half", "full"] and @view_mode == "chat"} class="flex-1 flex overflow-hidden min-h-0">
          <aside
            :if={@history_open}
            class="w-72 shrink-0 border-r border-gray-800 overflow-y-auto"
          >
            <div :if={@conversations == []} class="px-3 py-4 text-xs text-gray-500">
              No saved conversations yet.
            </div>
            <ul class="divide-y divide-gray-800/60">
              <li
                :for={conv <- @conversations}
                class={[
                  "group flex items-start gap-2 px-3 py-2 text-xs cursor-pointer hover:bg-gray-800/50",
                  if(conv.id == @conversation_id, do: "bg-gray-800/80", else: "")
                ]}
                phx-click="load_conversation"
                phx-value-id={conv.id}
              >
                <div class="flex-1 min-w-0">
                  <p class="text-gray-200 truncate">{conv.title}</p>
                  <p class="text-[10px] text-gray-600 mt-0.5">
                    {Calendar.strftime(conv.updated_at, "%b %d %H:%M")}
                  </p>
                </div>
                <button
                  type="button"
                  phx-click="delete_conversation"
                  phx-value-id={conv.id}
                  class="opacity-0 group-hover:opacity-100 text-gray-500 hover:text-red-400 shrink-0"
                  data-confirm="Delete this conversation?"
                  aria-label="Delete"
                >
                  ×
                </button>
              </li>
            </ul>
          </aside>

          <div class="flex-1 overflow-y-auto px-4 py-3 space-y-3">
          <div :if={@messages == [] and @streaming_text == ""} class="flex items-center justify-center h-full text-sm text-gray-500">
            Ask anything — I know what page you're on.
          </div>

          <%= for msg <- @messages do %>
            <.message_bubble role={msg.role} content={msg.content} />
          <% end %>

          <ul :if={@tool_activity != []} class="space-y-1">
            <li :for={entry <- @tool_activity} class="flex items-center gap-2 text-[11px]">
              <span class="inline-flex items-center px-2 py-0.5 rounded bg-gray-800 text-gray-300 font-mono shrink-0">
                {entry.tool}
              </span>
              <.status_indicator status={if entry.status == :done, do: "completed", else: "running"} />
              <span :if={entry.preview} class="text-gray-500 truncate">{entry.preview}</span>
            </li>
          </ul>

          <.message_bubble :if={@streaming_text != ""} role="assistant" content={@streaming_text} />

          <div :if={@running and @streaming_text == "" and @tool_activity == []} class="flex items-center gap-2 text-xs text-gray-500">
            <span class="inline-block h-2 w-2 animate-pulse rounded-full bg-blue-400" />
            <span>Thinking…</span>
          </div>
          </div>
        </div>

        <!-- Agents view — orchestrator + sub-agent CRUD. Shown only in :full. -->
        <div :if={@sheet_state == "full" and @view_mode == "agents"} class="flex-1 overflow-y-auto px-6 py-4 space-y-6">
          <div class="flex items-center justify-between">
            <div>
              <h3 class="text-sm font-medium text-gray-200">Agents</h3>
              <p class="text-[11px] text-gray-500 mt-0.5">
                Orchestrators are top-level guides. Sub-agents inherit context from their parent and are spawned on demand.
              </p>
            </div>
            <form phx-submit="editor_create_orchestrator" class="flex items-center gap-2">
              <input
                type="text"
                name="name"
                placeholder="new-orchestrator"
                pattern="[a-z0-9_-]+"
                required
                class="rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-white placeholder-gray-600 focus:border-blue-500 w-44 font-mono"
              />
              <button type="submit" class="rounded bg-blue-600 hover:bg-blue-500 px-3 py-1 text-xs font-medium text-white">
                + New orchestrator
              </button>
            </form>
          </div>

          <.live_loading :if={@editor_agents == [] and not @models_loaded} message="Loading agents…" />

          <div
            :if={@editor_agents == [] and @models_loaded}
            class="text-xs text-gray-500 py-8 text-center border border-dashed border-gray-800 rounded"
          >
            No agents configured. Create your first orchestrator above.
          </div>

          <%= for orch <- Enum.filter(@editor_agents, &(&1["type"] == "orchestrator")) do %>
            <% sub_agents = Enum.filter(@editor_agents, &(&1["parent"] == orch["name"])) %>
            <.agent_card
              agent={orch}
              models_by_provider={@models_by_provider}
              available_tools={available_tools()}
              is_orchestrator={true}
            />
            <div :if={sub_agents != []} class="ml-6 space-y-3 border-l border-gray-800 pl-4">
              <.agent_card
                :for={sub <- sub_agents}
                agent={sub}
                models_by_provider={@models_by_provider}
                available_tools={available_tools()}
                is_orchestrator={false}
              />
            </div>

            <div class="ml-6 pl-4">
              <button
                :if={@editor_creating_sub_for != orch["name"]}
                type="button"
                phx-click="editor_toggle_sub_form"
                phx-value-parent={orch["name"]}
                class="text-[11px] text-blue-400 hover:text-blue-300"
              >
                + Add sub-agent
              </button>
              <form
                :if={@editor_creating_sub_for == orch["name"]}
                phx-submit="editor_create_sub_agent"
                class="flex items-center gap-2"
              >
                <input type="hidden" name="parent" value={orch["name"]} />
                <input
                  type="text"
                  name="name"
                  placeholder="sub-agent-name"
                  pattern="[a-z0-9_-]+"
                  required
                  autofocus
                  class="rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-white placeholder-gray-600 font-mono w-48"
                />
                <button type="submit" class="rounded bg-blue-600 hover:bg-blue-500 px-2 py-1 text-[11px] text-white">
                  Create
                </button>
                <button
                  type="button"
                  phx-click="editor_toggle_sub_form"
                  phx-value-parent={orch["name"]}
                  class="text-[11px] text-gray-500 hover:text-gray-300"
                >
                  Cancel
                </button>
              </form>
            </div>
          <% end %>
        </div>

        <!-- Prompt editor modal — shared by orchestrators and sub-agents -->
        <div
          :if={@editor_editing_prompt}
          class="fixed inset-0 z-50 flex items-center justify-center bg-black/70"
          phx-click="editor_cancel_prompt"
        >
          <div
            class="w-full max-w-2xl max-h-[80vh] flex flex-col rounded-lg bg-gray-900 border border-gray-800 shadow-2xl"
            phx-click-away="editor_cancel_prompt"
          >
            <div class="flex items-center justify-between border-b border-gray-800 px-4 py-3">
              <h3 class="text-sm font-medium text-gray-200">
                Edit prompt — <code class="font-mono text-blue-400">{@editor_editing_prompt}</code>
              </h3>
              <button
                type="button"
                phx-click="editor_cancel_prompt"
                class="text-gray-500 hover:text-gray-300"
                aria-label="Close"
              >
                ×
              </button>
            </div>
            <form phx-submit="editor_save_prompt" class="flex-1 flex flex-col p-4 gap-3">
              <textarea
                name="content"
                class="flex-1 rounded bg-gray-950 border border-gray-700 px-3 py-2 text-sm text-gray-200 font-mono resize-none focus:border-blue-500 focus:outline-none"
                rows="20"
              >{@editor_prompt_content}</textarea>
              <div class="flex items-center justify-end gap-2">
                <button
                  type="button"
                  phx-click="editor_cancel_prompt"
                  class="rounded px-3 py-1.5 text-xs text-gray-300 hover:bg-gray-800"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  class="rounded bg-blue-600 hover:bg-blue-500 px-3 py-1.5 text-xs font-medium text-white"
                >
                  Save
                </button>
              </div>
            </form>
          </div>
        </div>

        <div
          :if={@pending_setup && @sheet_state in ["half", "full"]}
          class="border-t border-amber-800/60 bg-amber-900/10 px-3 py-3 max-h-[40vh] overflow-y-auto"
        >
          <div class="flex items-center justify-between mb-2">
            <div class="flex items-center gap-2 text-xs">
              <span class="text-amber-300 font-medium">Setup required</span>
              <code class="font-mono text-gray-400 truncate">{@pending_setup.component_ref}</code>
            </div>
            <button
              type="button"
              phx-click="dismiss_setup"
              class="text-gray-500 hover:text-gray-300 text-xs"
              aria-label="Dismiss"
            >
              Dismiss
            </button>
          </div>
          <p class="text-[11px] text-gray-500 mb-3">
            Stored encrypted on this device. Values never leave the host.
          </p>

          <form phx-change="setup_form_change" phx-submit="complete_setup" class="space-y-3">
            <div :if={@pending_setup.secrets != []} class="space-y-2">
              <h4 class="text-[10px] font-semibold text-gray-500 uppercase tracking-wider">Secrets</h4>
              <%= for secret <- @pending_setup.secrets do %>
                <% secret_name = setup_field(secret, :name) %>
                <% already_set = setup_field(secret, :already_set) == true %>
                <div class="text-xs">
                  <label class="block text-gray-400 mb-1 font-mono">
                    {secret_name}
                    <span :if={setup_field(secret, :required)} class="text-red-400 ml-1">*</span>
                  </label>
                  <%= if already_set do %>
                    <label class="flex items-center gap-2 cursor-pointer">
                      <input type="hidden" name={"secret[#{secret_name}]"} value="false" />
                      <input
                        type="checkbox"
                        name={"secret[#{secret_name}]"}
                        value="true"
                        checked={(@pending_setup.secret_inputs[secret_name] || "") == "true"}
                        class="h-3.5 w-3.5 rounded border-gray-700 bg-gray-900 text-amber-500"
                      />
                      <span class="text-gray-300">Grant access</span>
                    </label>
                  <% else %>
                    <input
                      type="password"
                      name={"secret[#{secret_name}]"}
                      value={@pending_setup.secret_inputs[secret_name] || ""}
                      placeholder={setup_field(secret, :description) || "Enter value…"}
                      autocomplete="off"
                      class="w-full rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-white placeholder-gray-600 focus:border-amber-500 focus:ring-1 focus:ring-amber-500"
                    />
                  <% end %>
                </div>
              <% end %>
            </div>

            <div :if={@pending_setup.policy_fields != []} class="space-y-2">
              <h4 class="text-[10px] font-semibold text-gray-500 uppercase tracking-wider">Policy</h4>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-2">
                <%= for {field, label, _type} <- @pending_setup.policy_fields do %>
                  <div class="text-xs">
                    <label class="block text-gray-400 mb-1">{label}</label>
                    <input
                      type="text"
                      name={"policy[#{field}]"}
                      value={@pending_setup.policy_inputs[field] || ""}
                      placeholder={setup_policy_placeholder(field)}
                      class="w-full rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-white placeholder-gray-600 focus:border-amber-500 focus:ring-1 focus:ring-amber-500"
                    />
                  </div>
                <% end %>
              </div>
            </div>

            <div class="flex items-center gap-2 pt-1">
              <button
                type="submit"
                class="px-3 py-1 text-xs font-medium rounded bg-amber-600 text-white hover:bg-amber-500"
              >
                Save & continue
              </button>
            </div>
          </form>
        </div>

        <form
          :if={@view_mode == "chat"}
          phx-submit="submit"
          phx-change="validate_upload"
          class="border-t border-gray-800 p-3 space-y-2"
        >
          <div :if={@uploads.attachments.entries != [] and @sheet_state in ["half", "full"]} class="flex flex-wrap gap-1">
            <div
              :for={entry <- @uploads.attachments.entries}
              class="flex items-center gap-1 rounded bg-gray-800 px-2 py-0.5 text-[11px]"
            >
              <span class="text-gray-300 truncate max-w-[12rem]">{entry.client_name}</span>
              <span :if={entry.progress > 0 and entry.progress < 100} class="text-gray-500">{entry.progress}%</span>
              <button
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                class="text-gray-500 hover:text-red-400"
                aria-label="Remove"
              >
                ×
              </button>
            </div>
          </div>

          <div class="flex gap-2 items-end">
            <label
              :if={@sheet_state in ["half", "full"]}
              class="self-end rounded-md border border-gray-700 bg-gray-800 px-2 py-2 text-sm text-gray-400 hover:bg-gray-700 cursor-pointer"
              title="Attach files"
            >
              📎
              <.live_file_input upload={@uploads.attachments} class="hidden" />
            </label>
            <textarea
              id="aqua-textarea"
              phx-hook="AquaChat"
              name="message"
              phx-change="update_input"
              rows="2"
              placeholder="Ask AQUA…"
              class="flex-1 resize-none rounded-md border border-gray-700 bg-gray-950 px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:outline-none"
              autofocus
              disabled={@running or !@orchestrator}
            >{@input}</textarea>
            <button
              :if={!@running}
              type="submit"
              disabled={!@orchestrator or (@input == "" and @uploads.attachments.entries == [])}
              class="self-end rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-500 disabled:opacity-40 disabled:cursor-not-allowed"
            >
              Send
            </button>
            <button
              :if={@running}
              type="button"
              phx-click="stop"
              title="Stop the running agent"
              class="self-end rounded-md bg-red-600 px-4 py-2 text-sm font-medium text-white hover:bg-red-500"
            >
              {if @cancel_requested, do: "Cancelling…", else: "Stop"}
            </button>
          </div>
        </form>

        <div class="border-t border-gray-800 px-3 py-1.5 text-[11px] text-gray-500 flex items-center justify-between gap-3">
          <span :if={@active_context && @active_context.route} class="truncate">
            Context: {@active_context.route}<span :if={focus_label(@active_context)}> — {focus_label(@active_context)}</span>
          </span>
          <span :if={!@active_context || !@active_context.route} class="text-gray-600">
            No active context
          </span>
          <span :if={@token_usage.input > 0 or @token_usage.output > 0} class="font-mono shrink-0">
            {@token_usage.input} in / {@token_usage.output} out
          </span>
        </div>
      </section>
    </div>
    """
  end

  attr :agent, :map, required: true
  attr :models_by_provider, :map, required: true
  attr :available_tools, :list, required: true
  attr :is_orchestrator, :boolean, default: false

  defp agent_card(assigns) do
    assigns =
      assigns
      |> assign(:current_provider, agent_provider_for_select(assigns.agent))
      |> assign(:visible_tools, assigns.agent["visible_tools"])

    ~H"""
    <div class="rounded-lg border border-gray-800 bg-gray-900/60 p-4 space-y-3">
      <div class="flex items-start justify-between gap-3">
        <div class="flex-1 min-w-0">
          <form phx-change="editor_update_field" class="space-y-1">
            <input type="hidden" name="name" value={@agent["name"]} />
            <input type="hidden" name="field" value="title" />
            <input
              type="text"
              name="value"
              value={@agent["title"]}
              phx-debounce="500"
              class="w-full bg-transparent border-none text-sm font-medium text-gray-100 focus:ring-1 focus:ring-blue-500 rounded px-1 -ml-1"
            />
          </form>
          <div class="flex items-center gap-2 mt-0.5">
            <span class={[
              "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium",
              if(@is_orchestrator, do: "bg-purple-900/40 text-purple-300", else: "bg-blue-900/40 text-blue-300")
            ]}>
              {if @is_orchestrator, do: "orchestrator", else: "sub-agent"}
            </span>
            <code class="text-[11px] text-gray-500 font-mono">{@agent["name"]}</code>
            <code :if={@agent["parent"]} class="text-[11px] text-gray-600 font-mono">
              ↳ parent: {@agent["parent"]}
            </code>
          </div>
        </div>
        <div class="flex items-center gap-1 shrink-0">
          <button
            type="button"
            phx-click="editor_edit_prompt"
            phx-value-name={@agent["name"]}
            class="rounded px-2 py-1 text-[11px] text-blue-400 hover:bg-gray-800 hover:text-blue-300"
          >
            Edit prompt
          </button>
          <button
            type="button"
            phx-click="editor_delete"
            phx-value-name={@agent["name"]}
            data-confirm={"Delete agent '#{@agent["name"]}'?"}
            class="rounded px-2 py-1 text-[11px] text-gray-500 hover:bg-red-900/40 hover:text-red-300"
          >
            Delete
          </button>
        </div>
      </div>

      <form :if={!@is_orchestrator} phx-change="editor_update_field" class="space-y-1">
        <input type="hidden" name="name" value={@agent["name"]} />
        <input type="hidden" name="field" value="description" />
        <label class="block text-[10px] uppercase tracking-wider text-gray-500">Description</label>
        <input
          type="text"
          name="value"
          value={@agent["description"]}
          phx-debounce="500"
          placeholder="One-line description shown to the orchestrator…"
          class="w-full rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 placeholder-gray-600 focus:border-blue-500 focus:outline-none"
        />
      </form>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
        <form phx-change="editor_set_model">
          <input type="hidden" name="name" value={@agent["name"]} />
          <label class="block text-[10px] uppercase tracking-wider text-gray-500 mb-1">Model</label>
          <select
            name="value"
            class="w-full rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 focus:border-blue-500 focus:outline-none"
          >
            <option value="" selected={is_nil(@agent["model"])}>
              Inherit from parent
            </option>
            <%= for {provider, models} <- @models_by_provider, models != [] do %>
              <optgroup label={provider}>
                <option
                  :for={m <- models}
                  value={"#{provider}::#{m}"}
                  selected={@agent["model"] == m and @current_provider == provider}
                >
                  {m}
                </option>
              </optgroup>
            <% end %>
          </select>
        </form>

        <div>
          <label class="block text-[10px] uppercase tracking-wider text-gray-500 mb-1">
            Visible tools
            <span :if={is_nil(@visible_tools)} class="text-gray-600 normal-case ml-1">
              (all — unrestricted)
            </span>
          </label>
          <div class="flex flex-wrap gap-1">
            <button
              :for={tool <- @available_tools}
              type="button"
              phx-click="editor_toggle_tool"
              phx-value-name={@agent["name"]}
              phx-value-tool={tool}
              class={[
                "px-1.5 py-0.5 rounded text-[10px] font-mono border",
                tool_button_class(@visible_tools, tool)
              ]}
            >
              {tool_label(tool)}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp tool_button_class(nil, _tool),
    do: "bg-blue-900/40 text-blue-300 border-blue-800 hover:bg-blue-900/60"

  defp tool_button_class(visible_tools, "native_search") when is_list(visible_tools) do
    if "native_search" in visible_tools do
      "bg-amber-900/40 text-amber-300 border-amber-800"
    else
      "bg-gray-900 text-gray-500 border-gray-800 hover:bg-gray-800 hover:text-gray-300"
    end
  end

  defp tool_button_class(visible_tools, tool) when is_list(visible_tools) do
    if tool in visible_tools do
      "bg-blue-900/40 text-blue-300 border-blue-800 hover:bg-blue-900/60"
    else
      "bg-gray-900 text-gray-500 border-gray-800 hover:bg-gray-800 hover:text-gray-300"
    end
  end

  attr :role, :string, required: true
  attr :content, :string, required: true

  defp message_bubble(assigns) do
    # Strip aqua-actions blocks for display. Covers BOTH committed messages
    # (loaded conversations from before the protocol existed may contain
    # raw blocks) and the live streaming text (handles partial mid-stream
    # blocks via the render-time regex so JSON never flashes).
    assigns = assign(assigns, :display_content, Prism.AquaActions.strip_blocks(assigns.content))

    ~H"""
    <div class={[
      "flex",
      role_align(@role)
    ]}>
      <div class={[
        "max-w-[85%] rounded-lg px-3 py-2 text-sm whitespace-pre-wrap break-words",
        role_class(@role)
      ]}>
        {@display_content}
      </div>
    </div>
    """
  end

  attr :current, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true

  defp sheet_toggle(assigns) do
    ~H"""
    <button
      phx-click="set_state"
      phx-value-state={@value}
      class={[
        "rounded px-2 py-1 text-[11px] uppercase tracking-wider",
        if(@current == @value,
          do: "bg-blue-900/50 text-blue-300",
          else: "text-gray-500 hover:bg-gray-800 hover:text-gray-300"
        )
      ]}
    >
      {@label}
    </button>
    """
  end

  defp sheet_class("half"), do: "h-[55vh]"
  defp sheet_class("full"), do: "h-[calc(100vh-2.5rem)]"
  defp sheet_class(_), do: "h-0"

  defp role_align("user"), do: "justify-end"
  defp role_align(_), do: "justify-start"

  defp role_class("user"), do: "bg-indigo-600 text-white"
  defp role_class("error"), do: "bg-red-900/40 text-red-300 border border-red-800"
  defp role_class(_), do: "bg-gray-800 text-gray-200"

  defp focus_label(%{focused_resource: {kind, id}}) when is_atom(kind) and is_binary(id) do
    "#{kind}: #{short(id)}"
  end

  defp focus_label(_), do: nil

  defp short(s) when is_binary(s) and byte_size(s) > 20, do: String.slice(s, 0, 20) <> "…"
  defp short(s), do: s
end
