# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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

  alias PrismWeb.AquaLive.AgentState
  alias PrismWeb.AquaLive.View

  @compile {:no_warn_undefined, [Opus]}

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
     |> assign(:pending_approvals, %{})
     # `{tool, action}` pairs the user approved "for this conversation" — the
     # next matching `ui.request_approval` auto-resolves. Ephemeral: reset on
     # new/load conversation; gone on full reload.
     |> assign(:conversation_grants, MapSet.new())
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
     |> assign(:consent_sheet_ref, nil)
     |> assign(:restart_prompt, nil)
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
       # 20 MB — sized with EmissaryWeb.Endpoint's Plug.Parsers :length so a
       # base64-encoded attachment of this size fits through POST /mcp.
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
          if ctx, do: Opus.unsubscribe_events(exec_id, ctx)

          case Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
                 if ctx, do: Opus.cancel(ctx, exec_id)
               end) do
            {:ok, _pid} ->
              :ok

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

  def handle_event("revoke_grant", %{"tool" => tool, "action" => action}, socket) do
    grants = MapSet.delete(socket.assigns[:conversation_grants] || MapSet.new(), {tool, action})
    {:noreply, assign(socket, :conversation_grants, grants)}
  end

  def handle_event("approve_all_pending", _params, socket) do
    for id <- Map.keys(socket.assigns[:pending_approvals] || %{}),
        do: send(self(), {:approval_approve, id, :once})

    {:noreply, socket}
  end

  def handle_event("decline_all_pending", _params, socket) do
    for id <- Map.keys(socket.assigns[:pending_approvals] || %{}),
        do: send(self(), {:approval_decline, id, "", :once})

    {:noreply, socket}
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
     |> assign(:pending_approvals, %{})
     |> assign(:conversation_grants, MapSet.new())
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

    case Emissary.MCP.ToolRegistry.call_external("aqua", ctx, %{
           "action" => "create",
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

    case Emissary.MCP.ToolRegistry.call_external("aqua", ctx, %{
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

  def handle_event(
        "editor_update_field",
        %{"name" => name, "field" => field, "value" => value},
        socket
      ) do
    ctx = socket.assigns.context
    args = %{"action" => "update", "name" => name, field => value}

    case Emissary.MCP.ToolRegistry.call_external("aqua", ctx, args) do
      {:ok, _} ->
        send(self(), :editor_refresh)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{inspect(reason)}")}
    end
  end

  def handle_event("editor_delete", %{"name" => name}, socket) do
    ctx = socket.assigns.context

    case Emissary.MCP.ToolRegistry.call_external("aqua", ctx, %{
           "action" => "delete",
           "name" => name
         }) do
      {:ok, _} ->
        send(self(), :editor_refresh)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  # Add/remove a `tool.action` from an agent's allowlist. On add, the default
  # value is "auto" for reads (they never ask) and "ask" for everything else.
  def handle_event(
        "editor_toggle_capability",
        %{"name" => agent_name, "key" => key} = params,
        socket
      ) do
    agent = Enum.find(socket.assigns.editor_agents, &(&1["name"] == agent_name))
    current = (agent && agent["tool_policy"]) || %{}

    new_policy =
      if Map.has_key?(current, key) do
        Map.delete(current, key)
      else
        default = if params["kind"] == "read", do: "auto", else: "ask"
        Map.put(current, key, default)
      end

    {:noreply, update_agent_tool_policy(socket, agent_name, new_policy)}
  end

  # Toggle a write/execute capability between "ask" (request approval) and
  # "auto" (run without asking). Reads and destructive/external rows don't
  # expose this — but guard the value space anyway.
  def handle_event(
        "editor_set_capability_mode",
        %{"name" => agent_name, "key" => key, "mode" => mode},
        socket
      )
      when mode in ["ask", "auto"] do
    agent = Enum.find(socket.assigns.editor_agents, &(&1["name"] == agent_name))
    current = (agent && agent["tool_policy"]) || %{}
    {:noreply, update_agent_tool_policy(socket, agent_name, Map.put(current, key, mode))}
  end

  # Flip an agent between native-tool-only (just `native_search`) and the
  # custom-tool capability list. Native model-side tools can't coexist with
  # custom MCP tools, so this replaces the whole allowlist.
  def handle_event("editor_toggle_native", %{"name" => agent_name}, socket) do
    agent = Enum.find(socket.assigns.editor_agents, &(&1["name"] == agent_name))
    current = (agent && agent["tool_policy"]) || %{}

    new_policy =
      if Map.has_key?(current, "native_search"), do: %{}, else: %{"native_search" => "auto"}

    {:noreply, update_agent_tool_policy(socket, agent_name, new_policy)}
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

    case Emissary.MCP.ToolRegistry.call_external("aqua", ctx, %{
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

    case AgentState.decode_model_choice(value) do
      {:inherit} ->
        Emissary.MCP.ToolRegistry.call_external("aqua", ctx, %{
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

        Emissary.MCP.ToolRegistry.call_external("aqua", ctx, %{
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
        case Emissary.MCP.ToolRegistry.call_external("aqua", ctx, %{
               "action" => "get",
               "name" => name
             }) do
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
  # The consent sheet closes itself once the grant lands.
  def handle_info({:consent_granted, _ref, result}, socket) do
    socket =
      socket
      |> assign(:consent_sheet_ref, nil)
      |> restart_turn_for_consent(result)

    {:noreply, socket}
  end

  def handle_info({:consent_sheet_closed, _ref}, socket) do
    {:noreply, assign(socket, :consent_sheet_ref, nil)}
  end

  def handle_info({:active_context, ctx}, socket) do
    {:noreply, assign(socket, :active_context, ctx)}
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
    orch = socket.assigns.orchestrator || %{}

    tool_policy =
      Prism.AgentConfig.effective_tool_policy(
        socket.assigns.context,
        orch["name"] || "aqua",
        orch["tool_policy"] || %{}
      )

    %{stripped: stripped, intents: intents, drops: drops} =
      Prism.AquaActions.parse(raw, tool_policy)

    Enum.each(drops, fn drop ->
      Logger.warning("[AquaLive] dropped aqua-actions intent: #{inspect(drop)}")
    end)

    tripwires = AgentState.tripwire_messages(drops)

    {approval_intents, client_intents} =
      Enum.split_with(intents, &(&1.kind == "request_approval"))

    base_messages =
      if stripped != "" do
        socket.assigns.messages ++
          [%{role: "assistant", content: stripped, timestamp: DateTime.utc_now()}]
      else
        socket.assigns.messages
      end

    approval_msgs =
      Enum.map(approval_intents, fn intent ->
        %{
          role: "approval",
          id: intent.id,
          payload: intent,
          status: :pending,
          decided_at: nil,
          reason: nil,
          result_summary: nil,
          scope: nil,
          timestamp: DateTime.utc_now()
        }
      end)

    pending_approvals =
      Enum.reduce(approval_intents, socket.assigns[:pending_approvals] || %{}, fn intent, acc ->
        Map.put(acc, intent.id, intent)
      end)

    if socket.assigns.current_execution_id do
      Opus.unsubscribe_events(
        socket.assigns.current_execution_id,
        socket.assigns.context
      )
    end

    socket =
      socket
      |> assign(:messages, base_messages ++ approval_msgs ++ tripwires)
      |> assign(:pending_approvals, pending_approvals)
      |> assign(:streaming_text, "")
      |> assign(:running, false)
      |> assign(:current_execution_id, nil)
      |> save_conversation()
      |> push_intents(client_intents)

    # Conversation-grant fast-path: any proposal the user already chose to
    # auto-approve "for this chat" runs immediately (its card resolves at once).
    grants = socket.assigns[:conversation_grants] || MapSet.new()

    Enum.each(approval_intents, fn intent ->
      if AgentState.proposal_granted?(intent, grants) do
        send(self(), {:approval_approve, intent.id, :conversation})
      end
    end)

    {:noreply, socket}
  end

  def handle_info({:execution_event, %{type: "error", data: data}}, socket) do
    err = data["message"] || data[:message] || inspect(data)

    messages =
      socket.assigns.messages ++
        [%{role: "error", content: err, timestamp: DateTime.utc_now()}]

    if socket.assigns.current_execution_id do
      Opus.unsubscribe_events(
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
      |> Map.new(fn {provider, value} -> {provider, View.normalize_provider_models(value)} end)

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
          Opus.subscribe_events(exec_id, socket.assigns.context)
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

  # Async conversation index load result (kicked off in mount/3).
  def handle_info({:aqua_conversations_loaded, {:ok, entries}}, socket) do
    conversations =
      entries
      |> Enum.map(fn e ->
        %{
          id: e["id"],
          title: e["title"] || "Untitled",
          updated_at: View.parse_ts(e["updated_at"])
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

  # ---------------------------------------------------------------------------
  # Approval card → harness execution
  # ---------------------------------------------------------------------------

  def handle_info({:approval_approve, id, scope}, socket) do
    pending = socket.assigns[:pending_approvals] || %{}

    case Map.get(pending, id) do
      nil ->
        Logger.warning("[AquaLive] approve for unknown approval id: #{id}")
        {:noreply, socket}

      intent ->
        run_approval(socket, id, intent, scope)
    end
  end

  def handle_info({:approval_decline, id, reason, scope}, socket) do
    pending = socket.assigns[:pending_approvals] || %{}

    case Map.get(pending, id) do
      nil ->
        Logger.warning("[AquaLive] decline for unknown approval id: #{id}")
        {:noreply, socket}

      intent ->
        socket =
          if scope == :never, do: remove_capability(socket, intent[:proposal]), else: socket

        complete_approval(
          socket,
          id,
          :declined,
          %{reason: reason},
          Map.put(intent, :scope, scope)
        )
    end
  end

  def handle_info({:approval_result, id, outcome, payload}, socket) do
    pending = socket.assigns[:pending_approvals] || %{}

    case Map.get(pending, id) do
      nil -> {:noreply, socket}
      intent -> complete_approval(socket, id, outcome, payload, intent)
    end
  end

  def handle_info(msg, socket) do
    Logger.debug("[AquaLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # The human decision unblocks the call; it never supplies authority.
  #
  # An approved `execution.run`/`run_stream` is a deliberate app launch: the
  # target roots its OWN consented authority (`run_root` re-resolves the ref
  # and profile), and the operator identity supplies only ingress. It runs on
  # the external plane — routing it in-chain under the agent's authority would
  # leave every app the agent has no edge to inert. Guest-supplied lineage keys
  # are dropped, exactly as the in-chain path would.
  defp run_approved_call(%{tool: "execution", action: action}, ctx, args)
       when action in ["run", "run_stream"] do
    launch_args = Map.drop(args, ["parent_execution_id", "root_execution_id"])
    Emissary.MCP.ToolRegistry.call_external("execution", ctx, launch_args)
  end

  # Every other approved tool runs under the agent formula's consented
  # authority through the in-chain chokepoint, guest-planed so it cannot reach
  # the operator's external-plane powers. If that authority is unavailable (no
  # profile, revoked, or re-consent required) we FAIL CLOSED — never fall back
  # to the operator's context.
  defp run_approved_call(proposal, ctx, args) do
    case Opus.authority_for(ctx, nil, @agent_ref) do
      {:ok, authority} ->
        Emissary.MCP.ToolRegistry.call_in_chain(
          proposal.tool,
          Sanctum.Context.enter_guest(ctx),
          args,
          authority
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Spawn a Task that calls the proposal's MCP tool. On reply, send
  # {:approval_result, id, :approved | :error, payload} back to this LiveView.
  # `scope` (:once | :conversation | :always) governs whether the same
  # `tool.action` is remembered (for this chat, or persisted to the agent's
  # allowlist as "auto").
  defp run_approval(socket, id, %{proposal: nil} = intent, _scope) do
    # Pure-confirmation card — nothing to execute; record the acknowledgement.
    complete_approval(
      socket,
      id,
      :approved,
      %{result: %{status: "ok"}},
      Map.put(intent, :scope, :once)
    )
  end

  defp run_approval(socket, id, intent, scope) do
    proposal = intent.proposal
    ctx = socket.assigns.context
    lv = self()

    socket = apply_approval_scope(socket, proposal, scope)

    Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
      args = Map.put(proposal.args || %{}, "action", proposal.action)

      case run_approved_call(proposal, ctx, args) do
        {:ok, result} ->
          send(lv, {:approval_result, id, :approved, %{result: result}})

        {:error, reason} ->
          send(lv, {:approval_result, id, :error, %{reason: reason}})
      end
    end)

    # Remember the scope so complete_approval/emit_approval_telemetry can read it.
    pending =
      Map.update(
        socket.assigns[:pending_approvals] || %{},
        id,
        intent,
        &Map.put(&1, :scope, scope)
      )

    # Optimistically mark "running" so the UI shows in-flight state.
    messages =
      Enum.map(socket.assigns.messages, fn
        %{role: "approval", id: ^id} = m -> %{m | status: :running, scope: scope, decided_at: nil}
        m -> m
      end)

    {:noreply, socket |> assign(:messages, messages) |> assign(:pending_approvals, pending)}
  end

  # Side effects of an approve scope. No-op for `:once` and for pure-confirmation
  # cards (no proposal). `:conversation` records the {tool, action} pair so the
  # rest of this chat auto-approves it; `:always` also writes `"auto"` for it
  # into the orchestrator's `tool_policy` allowlist (persisted to agent.json).
  defp apply_approval_scope(socket, %{tool: tool, action: action}, scope)
       when is_binary(tool) and is_binary(action) and scope in [:conversation, :always] do
    grants = MapSet.put(socket.assigns[:conversation_grants] || MapSet.new(), {tool, action})
    socket = assign(socket, :conversation_grants, grants)

    if scope == :always do
      persist_always_grant(socket, tool, action)
    else
      socket
    end
  end

  defp apply_approval_scope(socket, _proposal, _scope), do: socket

  defp persist_always_grant(socket, tool, action) do
    orch = socket.assigns[:orchestrator]
    name = orch && orch["name"]
    ctx = socket.assigns.context
    key = "#{tool}.#{action}"

    # A personal preference, not an agent-definition change: the grant is
    # written to the caller's tenant-scoped overlay, never into the shared
    # agent.json every other user's agent runs under.
    if name && ctx do
      case Prism.AgentConfig.put_user_tool_grant(ctx, name, key, "auto") do
        :ok ->
          send(self(), :editor_refresh)
          put_flash(socket, :info, "#{key} won't ask again — manage in Agents.")

        {:error, reason} ->
          put_flash(socket, :error, "Couldn't save 'always' for #{key}: #{inspect(reason)}")
      end
    else
      socket
    end
  end

  # Decline "never": drop the proposed `tool.action` from the orchestrator's
  # allowlist so the agent can no longer perform it. No-op for pure-confirmation
  # cards (no proposal) and for actions reached only via a `tool.*` glob.
  defp remove_capability(socket, %{tool: tool, action: action})
       when is_binary(tool) and is_binary(action) do
    orch = socket.assigns[:orchestrator]
    name = orch && orch["name"]
    ctx = socket.assigns.context
    key = "#{tool}.#{action}"

    # Same shape as "always": a per-user deny overlay filtered out of the
    # effective policy at run time, so one user's "never" cannot strip a
    # capability from every other user's agent.
    if name && ctx do
      case Prism.AgentConfig.put_user_tool_grant(ctx, name, key, "deny") do
        :ok ->
          send(self(), :editor_refresh)
          put_flash(socket, :info, "Removed #{key} from #{name}'s capabilities for you.")

        {:error, reason} ->
          put_flash(socket, :error, "Couldn't remove #{key}: #{inspect(reason)}")
      end
    else
      socket
    end
  end

  defp remove_capability(socket, _proposal), do: socket

  # Mark the message as resolved, append a synthetic system turn into the
  # conversation history so the agent sees the outcome, drop from pending.
  defp complete_approval(socket, id, outcome, payload, intent) do
    now = DateTime.utc_now()
    title = intent.title
    proposal = intent.proposal
    scope = intent[:scope] || :once

    {result_summary, system_text} =
      AgentState.build_outcome_summary(outcome, payload, title, proposal)

    emit_approval_telemetry(socket, id, outcome, intent, payload)

    messages =
      Enum.map(socket.assigns.messages, fn
        %{role: "approval", id: ^id} = m ->
          %{
            m
            | status: outcome,
              decided_at: now,
              reason: payload[:reason],
              result_summary: result_summary,
              scope: scope
          }

        m ->
          m
      end)

    pending = Map.delete(socket.assigns[:pending_approvals] || %{}, id)

    new_history =
      socket.assigns.conversation_history ++
        [%{"role" => "user", "content" => system_text}]

    {:noreply,
     socket
     |> assign(:messages, messages)
     |> assign(:pending_approvals, pending)
     |> assign(:conversation_history, new_history)
     |> save_conversation()}
  end

  defp emit_approval_telemetry(socket, id, outcome, intent, payload) do
    ctx = socket.assigns.context
    proposal = intent.proposal || %{tool: nil, action: nil}

    metadata = %{
      id: id,
      decision: outcome,
      scope: intent[:scope] || :once,
      tool: proposal[:tool],
      action: proposal[:action],
      kind: intent[:action_kind],
      conversation_id: socket.assigns[:conversation_id],
      user_id: ctx && ctx.user_id,
      org_id: ctx && ctx.org_id,
      project_id: ctx && ctx.project_id,
      orchestrator: socket.assigns[:orchestrator] && socket.assigns.orchestrator["name"],
      reason: payload[:reason]
    }

    :telemetry.execute([:prism, :aqua, :approval], %{count: 1}, metadata)
  rescue
    _ -> :ok
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

    assign(
      socket,
      :tool_activity,
      View.mark_tool_done(socket.assigns.tool_activity, tool, preview)
    )
  end

  # Whatever the component still needs, the consent walk is the one
  # place it gets granted — open the sheet on the asking ref.
  defp handle_emit(socket, kind, data) when kind in ["setup_required", "request_setup"] do
    case data["component_ref"] || data[:component_ref] || "" do
      "" -> socket
      ref -> assign(socket, :consent_sheet_ref, ref)
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

  defp handle_emit(socket, _kind, _data), do: socket

  # §4.4: a delta consent applies to future roots. The turn already
  # running may have taken side effects under the authority it started
  # with, so it is terminated carrying restart_required rather than
  # re-bound, and the operator re-sends. A chat turn IS a root execution,
  # so "re-run" here means "send that message again" — the prior input
  # is kept ready so it is one click.
  defp restart_turn_for_consent(socket, result) do
    if socket.assigns.running && socket.assigns.current_execution_id do
      exec_id = socket.assigns.current_execution_id
      ctx = socket.assigns[:context]

      payload = %{
        profile_id: Map.get(result, :profile_id),
        new_revision: Map.get(result, :revision),
        missing: %{chain: [], edge: nil, activation: nil}
      }

      if ctx && opus_available?() do
        Opus.unsubscribe_events(exec_id, ctx)

        Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
          Opus.cancel_for_restart(ctx, exec_id, payload)
        end)
      end

      socket
      |> assign(:running, false)
      |> assign(:streaming_text, "")
      |> assign(:tool_activity, [])
      |> assign(:current_execution_id, nil)
      |> assign(:restart_prompt, last_user_message(socket))
      |> put_flash(:info, "Approved — re-run to continue.")
    else
      socket
    end
  end

  defp last_user_message(socket) do
    socket.assigns
    |> Map.get(:messages, [])
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: "user", content: content} when is_binary(content) -> content
      _ -> nil
    end)
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
      AgentState.parse_orchestrator_mention(message, socket.assigns.orchestrators)

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

    # Shared manifest policy overlaid with the caller's personal always/never
    # grants — the merge happens here, per run, never in the stored manifest.
    tool_policy =
      Prism.AgentConfig.effective_tool_policy(
        ctx,
        orchestrator_name,
        orchestrator["tool_policy"] || %{}
      )

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
        Prism.AquaActions.system_prelude(tool_policy)

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
      |> Prism.AgentConfig.put_formula_tool_surface(tool_policy)
      |> View.maybe_put_active_context(socket.assigns.active_context)
      |> View.maybe_put_attachments(attachments)
      |> View.maybe_put_messages(socket.assigns.conversation_history)

    lv = self()

    Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
      result =
        Emissary.MCP.ToolRegistry.call_external("execution", ctx, %{
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
  # Editor helpers — orchestrator + sub-agent CRUD
  # ---------------------------------------------------------------------------

  defp update_agent_tool_policy(socket, agent_name, new_policy) do
    case Emissary.MCP.ToolRegistry.call_external("aqua", socket.assigns.context, %{
           "action" => "update",
           "name" => agent_name,
           "tool_policy" => new_policy
         }) do
      {:ok, _} ->
        send(self(), :editor_refresh)
        socket

      {:error, reason} ->
        put_flash(socket, :error, "Update failed: #{inspect(reason)}")
    end
  end

  defp load_editor_agents(socket) do
    ctx = socket.assigns[:context]

    agents =
      case ctx && Emissary.MCP.ToolRegistry.call_external("aqua", ctx, %{"action" => "list"}) do
        {:ok, result} ->
          guides = result[:guides] || result["guides"] || []

          Enum.flat_map(guides, fn g ->
            name = g[:name] || g["name"]
            type = g[:type] || g["type"]

            if type in ["orchestrator", "sub-agent"] do
              case Emissary.MCP.ToolRegistry.call_external("aqua", ctx, %{
                     "action" => "get",
                     "name" => name
                   }) do
                {:ok, detail} ->
                  [
                    %{
                      "name" => name,
                      "title" => detail[:title] || detail["title"] || name,
                      "type" => type,
                      "parent" => detail[:parent] || detail["parent"],
                      "description" => detail[:description] || detail["description"] || "",
                      "model" => detail[:model] || detail["model"],
                      "catalyst_ref" => detail[:catalyst_ref] || detail["catalyst_ref"],
                      "tool_policy" => detail[:tool_policy] || detail["tool_policy"] || %{},
                      "content" => detail[:content] || detail["content"] || ""
                    }
                  ]

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

    socket
    |> assign(:editor_agents, agents)
    |> ensure_tool_actions_loaded()
  end

  # Enumerate `(tool, [actions...])` from the live MCP registry — populated
  # once per editor open, so the matrix UI can render real (tool, action)
  # pairs the user can toggle. native_search is included as a bare key
  # (no actions enum) since the formula treats it specially.
  defp ensure_tool_actions_loaded(socket) do
    if socket.assigns[:tool_actions] do
      socket
    else
      tool_actions = AgentState.enumerate_tool_actions()
      assign(socket, :tool_actions, tool_actions)
    end
  end

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
          Emissary.MCP.ToolRegistry.call_external("execution", ctx, %{
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
    title = View.first_user_title(messages)
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
      "messages" => Enum.map(messages, &View.serialize_message/1),
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

        Prism.AquaConversations.write_index(ctx, View.upsert_entry(existing, index_entry))
      end
    end)

    in_memory =
      %{id: id, title: title, updated_at: DateTime.utc_now()}
      |> View.upsert_in_memory(socket.assigns.conversations)

    assign(socket, :conversations, in_memory)
  end

  defp do_load_conversation(socket, id) do
    case socket.assigns[:context] do
      %Sanctum.Context{} = ctx ->
        case Prism.AquaConversations.read_conversation(ctx, id) do
          {:ok, %{"messages" => messages} = data} when is_list(messages) ->
            deserialized = Enum.map(messages, &View.deserialize_message/1)
            history = data["conversation_history"] || []

            socket
            |> assign(:conversation_id, id)
            |> assign(:messages, deserialized)
            |> assign(:conversation_history, history)
            |> assign(:streaming_text, "")
            |> assign(:tool_activity, [])
            |> assign(:token_usage, %{input: 0, output: 0})
            |> assign(:pending_approvals, %{})
            |> assign(:conversation_grants, MapSet.new())
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

  defp load_orchestrator(socket) do
    ctx = socket.assigns[:context]

    if ctx == nil do
      assign(socket, :orchestrators_loaded, true)
    else
      list_result =
        Emissary.MCP.ToolRegistry.call_external("aqua", ctx, %{
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
    case Emissary.MCP.ToolRegistry.call_external("aqua", ctx, %{"action" => "get", "name" => name}) do
      {:ok, detail} ->
        %{
          "name" => name,
          "title" => detail[:title] || detail["title"] || name,
          "catalyst_ref" => detail[:catalyst_ref] || detail["catalyst_ref"],
          "model" => detail[:model] || detail["model"],
          "tool_policy" => detail[:tool_policy] || detail["tool_policy"] || %{}
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
      >
      </div>

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
            <span
              :if={!@orchestrator && @orchestrators_loaded && @orchestrators == []}
              class="text-xs text-amber-400"
            >
              No orchestrator configured
            </span>
            <span
              :if={@orchestrator && native_mode?(@orchestrator["tool_policy"])}
              class="shrink-0 inline-flex items-center rounded bg-amber-900/50 px-1.5 py-0.5 text-[10px] text-amber-200"
              title="Native model-side tools only"
            >
              native
            </span>
            <span
              :if={MapSet.size(@conversation_grants) > 0}
              class="shrink-0 inline-flex items-center rounded bg-gray-800 px-1.5 py-0.5 text-[10px] text-gray-300"
              title="Actions you've auto-approved for this conversation"
            >
              +{MapSet.size(@conversation_grants)} this chat
            </span>
            <select
              :if={
                @sheet_state in ["half", "full"] and @models_loaded and
                  flatten_models(@models_by_provider) != []
              }
              phx-change="select_model"
              name="model"
              class="bg-transparent text-[10px] text-gray-600 hover:text-gray-300 border-none focus:ring-0 focus:outline-none cursor-pointer max-w-[14rem] truncate font-mono"
              title="Override model"
            >
              <option value="" selected={is_nil(@model_override)}>
                {(@orchestrator && @orchestrator["model"]) || "default"}
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
            <span
              :if={
                (!(@sheet_state in ["half", "full"] and @models_loaded and
                     flatten_models(@models_by_provider) != []) and @orchestrator) &&
                  @orchestrator["model"]
              }
              class="text-[10px] text-gray-600 font-mono truncate"
            >
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
              :if={@running and @sheet_state in ["half", "full"] and @view_mode == "chat"}
              type="button"
              phx-click="stop"
              class="rounded px-2 py-1 text-[11px] uppercase tracking-wider bg-red-900/60 text-red-200 hover:bg-red-800/80"
              title="Halt the agent (⌘.)"
            >
              ◼ Stop
            </button>
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
            <span
              :if={@sheet_state in ["half", "full"] and @view_mode == "chat"}
              class="mx-1 h-4 w-px bg-gray-800"
            />
            <.sheet_toggle current={@sheet_state} value="half" label="Half" />
            <.sheet_toggle current={@sheet_state} value="full" label="Full" />
            <button
              phx-click="set_state"
              phx-value-state="closed"
              class="ml-1 rounded p-1 text-gray-500 hover:bg-gray-800 hover:text-gray-300"
              title="Close (Esc)"
            >
              <svg
                class="h-4 w-4"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="2"
              >
                <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
        </header>

        <div
          :if={@sheet_state in ["half", "full"] and @view_mode == "chat"}
          class="flex-1 flex overflow-hidden min-h-0"
        >
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
            <div
              :if={@messages == [] and @streaming_text == ""}
              class="flex items-center justify-center h-full text-sm text-gray-500"
            >
              Ask anything — I know what page you're on.
            </div>

            <div
              :if={MapSet.size(@conversation_grants) > 0}
              class="flex flex-wrap items-center gap-1.5 text-[10px] text-gray-500"
            >
              <span>auto-approving this chat:</span>
              <span
                :for={{tool, action} <- @conversation_grants}
                class="inline-flex items-center gap-1 rounded bg-gray-800 px-1.5 py-0.5 text-gray-300 font-mono"
              >
                {tool}.{action}
                <button
                  type="button"
                  phx-click="revoke_grant"
                  phx-value-tool={tool}
                  phx-value-action={action}
                  class="text-gray-500 hover:text-gray-200"
                  title="stop auto-approving in this chat"
                >
                  ×
                </button>
              </span>
            </div>

            <div
              :if={map_size(@pending_approvals) > 1}
              class="sticky top-0 z-10 flex items-center gap-2 rounded bg-amber-900/30 border border-amber-800/50 px-2.5 py-1 text-[11px] text-amber-200"
            >
              <span>{map_size(@pending_approvals)} pending approvals</span>
              <button
                type="button"
                phx-click="approve_all_pending"
                class="ml-auto rounded bg-amber-700 px-2 py-0.5 text-white hover:bg-amber-600"
              >
                Approve all
              </button>
              <button
                type="button"
                phx-click="decline_all_pending"
                class="rounded bg-gray-800 px-2 py-0.5 text-gray-300 hover:bg-gray-700"
              >
                Decline all
              </button>
            </div>

            <%= for msg <- @messages do %>
              <%= if msg.role == "approval" do %>
                <.live_component
                  module={PrismWeb.AquaApprovalCard}
                  id={msg.id}
                  payload={msg.payload}
                  status={msg.status}
                  decided_at={msg.decided_at}
                  reason={msg.reason}
                  result_summary={msg.result_summary}
                  scope={Map.get(msg, :scope)}
                  agent_label={@orchestrator && @orchestrator["title"]}
                />
              <% else %>
                <.message_bubble role={msg.role} content={msg.content} />
              <% end %>
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

            <div
              :if={@running and @streaming_text == "" and @tool_activity == []}
              class="flex items-center gap-2 text-xs text-gray-500"
            >
              <span class="inline-block h-2 w-2 animate-pulse rounded-full bg-blue-400" />
              <span>Thinking…</span>
            </div>
          </div>
        </div>
        
    <!-- Agents view — orchestrator + sub-agent CRUD. Shown only in :full. -->
        <div
          :if={@sheet_state == "full" and @view_mode == "agents"}
          class="flex-1 overflow-y-auto px-6 py-4 space-y-6"
        >
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
              <button
                type="submit"
                class="rounded bg-blue-600 hover:bg-blue-500 px-3 py-1 text-xs font-medium text-white"
              >
                + New orchestrator
              </button>
            </form>
          </div>

          <.live_loading
            :if={@editor_agents == [] and not @models_loaded}
            message="Loading agents…"
          />

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
              tool_actions={@tool_actions || []}
              is_orchestrator={true}
            />
            <div :if={sub_agents != []} class="ml-6 space-y-3 border-l border-gray-800 pl-4">
              <.agent_card
                :for={sub <- sub_agents}
                agent={sub}
                models_by_provider={@models_by_provider}
                tool_actions={@tool_actions || []}
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
                <button
                  type="submit"
                  class="rounded bg-blue-600 hover:bg-blue-500 px-2 py-1 text-[11px] text-white"
                >
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
          :if={@consent_sheet_ref && @sheet_state in ["half", "full"]}
          class="border-t border-emerald-800/60 bg-emerald-900/10 px-3 py-3 max-h-[50vh] overflow-y-auto"
        >
          <.live_component
            module={PrismWeb.ConsentSheetComponent}
            id={"consent-#{@consent_sheet_ref}"}
            ref={@consent_sheet_ref}
            context={@context}
          />
        </div>

        <form
          :if={@view_mode == "chat"}
          phx-submit="submit"
          phx-change="validate_upload"
          class="border-t border-gray-800 p-3 space-y-2"
        >
          <div
            :if={@uploads.attachments.entries != [] and @sheet_state in ["half", "full"]}
            class="flex flex-wrap gap-1"
          >
            <div
              :for={entry <- @uploads.attachments.entries}
              class="flex items-center gap-1 rounded bg-gray-800 px-2 py-0.5 text-[11px]"
            >
              <span class="text-gray-300 truncate max-w-[12rem]">{entry.client_name}</span>
              <span :if={entry.progress > 0 and entry.progress < 100} class="text-gray-500">
                {entry.progress}%
              </span>
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
              📎 <.live_file_input upload={@uploads.attachments} class="hidden" />
            </label>
            <textarea
              id="aqua-textarea"
              phx-hook="AquaChat"
              name="message"
              phx-change="update_input"
              rows="1"
              placeholder="Ask AQUA…  (Enter to send · Shift+Enter for newline)"
              class="flex-1 resize-none rounded-md border border-gray-700 bg-gray-950 px-3 py-1.5 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:outline-none max-h-40 overflow-y-auto"
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
  attr :tool_actions, :list, required: true
  attr :is_orchestrator, :boolean, default: false

  defp agent_card(assigns) do
    assigns =
      assigns
      |> assign(:current_provider, agent_provider_for_select(assigns.agent))
      |> assign(:tool_policy, assigns.agent["tool_policy"] || %{})

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
              if(@is_orchestrator,
                do: "bg-purple-900/40 text-purple-300",
                else: "bg-blue-900/40 text-blue-300"
              )
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

      <form phx-change="editor_set_model">
        <input type="hidden" name="name" value={@agent["name"]} />
        <label class="block text-[10px] uppercase tracking-wider text-gray-500 mb-1">Model</label>
        <select
          name="value"
          class="w-full md:w-1/2 rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 focus:border-blue-500 focus:outline-none"
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
        <div class="flex items-center justify-between mb-1">
          <label class="block text-[10px] uppercase tracking-wider text-gray-500">
            Capabilities
            <span class="normal-case text-gray-600">
              — reads run without asking; everything else asks unless you mark it "auto"
            </span>
          </label>
          <% auto_count = count_auto(@tool_policy, @tool_actions) %>
          <span :if={auto_count > 0} class="text-[10px] text-gray-600">{auto_count} won't ask</span>
        </div>

        <%= if native_mode?(@tool_policy) do %>
          <div class="border border-amber-800/60 bg-amber-900/10 rounded p-3 text-xs space-y-2">
            <label class="flex items-center gap-2 text-amber-200 cursor-pointer">
              <input
                type="checkbox"
                checked
                phx-click="editor_toggle_native"
                phx-value-name={@agent["name"]}
                class="rounded bg-gray-900 border-gray-600"
              /> Native search (model-side web grounding)
            </label>
            <p class="text-[11px] text-amber-300/70">
              Native tools can't be combined with custom MCP tools — this agent gets only native search. Uncheck to switch to the custom-tool capability list.
            </p>
          </div>
        <% else %>
          <div class="border border-gray-800 rounded divide-y divide-gray-800/60 max-h-[28rem] overflow-y-auto">
            <%= for {kind, kind_label, kind_chip, kind_strip} <- kind_sections() do %>
              <% rows = rows_for_kind(@tool_actions, kind) %>
              <%= if rows != [] do %>
                <details class="group" open={kind == :write}>
                  <summary class={[
                    "flex items-center gap-2 px-2 py-1.5 text-xs cursor-pointer hover:bg-gray-800/40",
                    kind_strip
                  ]}>
                    <span class={[
                      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium uppercase tracking-wider",
                      kind_chip
                    ]}>
                      {kind_label}
                    </span>
                    <span class="text-[10px] text-gray-600">{kind_hint(kind)}</span>
                    <span class="ml-auto text-[10px] text-gray-600">
                      {count_in_list(@tool_policy, rows)}/{length(rows)}
                    </span>
                  </summary>

                  <%= for {tool, action} <- rows do %>
                    <% key = "#{tool}.#{action}" %>
                    <% val = @tool_policy[key] %>
                    <div class="px-3 py-1 flex items-center gap-2 bg-gray-950/40">
                      <label class="flex items-center gap-1.5 flex-1 cursor-pointer">
                        <input
                          type="checkbox"
                          checked={val != nil}
                          phx-click="editor_toggle_capability"
                          phx-value-name={@agent["name"]}
                          phx-value-key={key}
                          phx-value-kind={Atom.to_string(kind)}
                          class="rounded bg-gray-900 border-gray-600"
                        />
                        <span class="text-[11px] font-mono text-gray-400">
                          <span class="text-gray-500">{tool}.</span>{action}
                        </span>
                      </label>
                      <%= cond do %>
                        <% is_nil(val) -> %>
                          <span></span>
                        <% kind == :read -> %>
                          <span class="text-[10px] text-emerald-400/70">runs without asking</span>
                        <% kind in [:destructive, :external] -> %>
                          <span class="text-[10px] text-gray-500">always asks</span>
                        <% true -> %>
                          <.auto_ask_toggle agent={@agent["name"]} key={key} value={val} />
                      <% end %>
                    </div>
                  <% end %>
                </details>
              <% end %>
            <% end %>
          </div>
          <label class="flex items-center gap-2 mt-2 text-[11px] text-amber-300/80 cursor-pointer">
            <input
              type="checkbox"
              phx-click="editor_toggle_native"
              phx-value-name={@agent["name"]}
              class="rounded bg-gray-900 border-gray-600"
            /> Use native search instead (replaces every capability above)
          </label>
        <% end %>
      </div>
    </div>
    """
  end

  attr :agent, :string, required: true
  attr :key, :string, required: true
  attr :value, :string, required: true

  # Two-state ask/auto toggle for a write- or execute-kind capability.
  defp auto_ask_toggle(assigns) do
    ~H"""
    <div class="flex items-center gap-0.5">
      <button
        :for={{label, mode} <- [{"ask", "ask"}, {"auto", "auto"}]}
        type="button"
        phx-click="editor_set_capability_mode"
        phx-value-name={@agent}
        phx-value-key={@key}
        phx-value-mode={mode}
        class={[
          "px-1.5 py-0.5 text-[10px] rounded font-medium",
          if(@value == mode,
            do:
              if(mode == "auto", do: "bg-slate-600 text-white", else: "bg-amber-800 text-amber-100"),
            else: "bg-gray-900 text-gray-500 hover:bg-gray-800 hover:text-gray-300"
          )
        ]}
      >
        {label}
      </button>
    </div>
    """
  end

  defp native_mode?(tool_policy),
    do: is_map(tool_policy) and Map.has_key?(tool_policy, "native_search")

  # Count of capabilities the agent runs without asking that *aren't* reads —
  # i.e. the write/execute actions the user has blanket-approved ("auto").
  defp count_auto(tool_policy, tool_actions) when is_map(tool_policy) do
    kinds = kind_index(tool_actions)

    Enum.count(tool_policy, fn {key, val} ->
      val == "auto" and Map.get(kinds, key) not in [nil, :read]
    end)
  end

  defp count_auto(_, _), do: 0

  defp count_in_list(tool_policy, rows) when is_map(tool_policy) do
    Enum.count(rows, fn {t, a} -> Map.has_key?(tool_policy, "#{t}.#{a}") end)
  end

  defp count_in_list(_, _), do: 0

  # `%{"tool.action" => kind}` lookup built from the enumerated tool catalog.
  defp kind_index(tool_actions) do
    for {tool, actions} <- tool_actions, {action, kind} <- actions, into: %{} do
      {"#{tool}.#{action}", kind}
    end
  end

  defp kind_hint(:read), do: "available, never asks"
  defp kind_hint(:write), do: "asks unless marked auto"
  defp kind_hint(:execute), do: "asks unless marked auto"
  defp kind_hint(:destructive), do: "always asks — can't be automated"
  defp kind_hint(:external), do: "always asks — can't be automated"
  defp kind_hint(_), do: ""

  # Kind sections in fixed display order, with their visual treatment (matches
  # the approval-card colour ramp: read = calm green, write = near-neutral
  # slate, execute = amber, destructive = red, external = amber + ring).
  # Tuple: {atom_kind, label, pill-classes, summary-strip-classes}.
  defp kind_sections do
    [
      {:read, "Read", "bg-emerald-900/60 text-emerald-200", "bg-emerald-900/10"},
      {:write, "Write", "bg-slate-700/70 text-slate-200", "bg-slate-800/20"},
      {:execute, "Execute", "bg-amber-900/60 text-amber-200", "bg-amber-900/10"},
      {:destructive, "Destructive", "bg-red-900/60 text-red-200", "bg-red-900/10"},
      {:external, "External", "bg-amber-900/60 text-amber-200 ring-1 ring-amber-500/40",
       "bg-amber-900/10"}
    ]
  end

  # Flatten `[{tool, [{action, kind}]}]` to `[{tool, action}]` for a given kind.
  defp rows_for_kind(tool_actions, target_kind) do
    Enum.flat_map(tool_actions, fn {tool, actions} ->
      actions
      |> Enum.flat_map(fn
        {action, ^target_kind} -> [{tool, action}]
        _ -> []
      end)
    end)
    |> Enum.sort()
  end

  attr :role, :string, required: true
  attr :content, :string, required: true

  defp message_bubble(assigns) do
    # Strip aqua-actions blocks for display, then trim — `whitespace-pre-wrap`
    # makes leading/trailing newlines visible as blank lines, so the model's
    # stray surrounding whitespace would inflate the bubble. (Covers committed
    # messages, loaded conversations, and live mid-stream text.)
    display = assigns.content |> Prism.AquaActions.strip_blocks() |> String.trim()
    assigns = assign(assigns, :display_content, display)

    ~H"""
    <div class={["flex", role_align(@role)]}>
      <div class={[
        "max-w-[85%] rounded-lg px-3 py-1.5 text-sm whitespace-pre-wrap break-words",
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
