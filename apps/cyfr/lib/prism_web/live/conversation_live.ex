# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ConversationLive do
  @moduledoc """
  The athanor's chat — where `/a/<athanor>` lands.

  A window onto `Prism.ConversationRunner`: the thread is the conversation's
  rows plus whatever the runner is streaming right now, and every action
  (send, stop, approve, decline) is a call into the runner with this
  member's context. Two members with the same conversation open see the
  same stream; a card one of them decides resolves on both screens.

  `?c=<conversation_id>` selects the conversation; without it the most
  recent one opens, or a fresh one is started on the first message.
  """

  use PrismWeb, :live_view

  require Logger

  alias Arca.ConversationStorage, as: Conversations
  alias Phoenix.LiveView.JS
  alias Prism.ConversationRunner

  @list_models_ref "formula:local.list-models"

  @impl true
  def mount(_params, _session, socket) do
    ctx = socket.assigns[:context]

    socket =
      socket
      |> assign(:page_title, "Chat")
      |> assign(:active_nav, "chat")
      |> assign(:conversations, [])
      |> assign(:conversation, nil)
      |> assign(:messages, [])
      |> assign(:input, "")
      |> assign(:running, false)
      |> assign(:turn_user, nil)
      |> assign(:streaming_text, "")
      |> assign(:tool_activity, [])
      |> assign(:token_usage, %{input: 0, output: 0})
      |> assign(:grants, MapSet.new())
      |> assign(:orchestrators, [])
      |> assign(:orchestrator, nil)
      |> assign(:model_ready, :unknown)
      |> assign(:models_by_provider, %{})
      |> assign(:models_loaded, false)
      |> assign(:model_override, nil)
      |> assign(:consent_sheet_ref, nil)
      |> assign(:restart_prompt, nil)
      |> assign(:cancel_requested, false)
      |> assign(:members, %{})
      |> assign(:queued, 0)
      |> assign(:answer_mode, answer_mode(socket))
      |> allow_upload(:attachments,
        accept: :any,
        max_entries: Prism.Attachments.limits().max_files,
        # 20 MB — sized with EmissaryWeb.Endpoint's Plug.Parsers :length so a
        # base64-encoded attachment of this size fits through POST /mcp.
        max_file_size: Prism.Attachments.limits().max_file_bytes,
        auto_upload: true
      )

    socket =
      if connected?(socket) and ctx do
        Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Notify.topic(ctx.athanor_id))

        orchestrators = Prism.AquaTurn.orchestrators(ctx)

        socket
        |> assign(:orchestrators, orchestrators)
        |> assign(:model_ready, model_ready(ctx, orchestrators))
        |> assign(:members, member_labels(ctx))
        |> load_models()
      else
        socket
      end

    {:ok, socket}
  end

  # A group's answer mode is on the athanor row; the runner reads the same.
  defp answer_mode(%{assigns: %{athanor: %Arca.Schemas.Athanor{} = athanor}}),
    do: Sanctum.Tenancy.Athanors.answer_mode(athanor)

  defp answer_mode(_socket), do: "mentioned"

  # The athanor row as it is now — after a settings change or a provisioning retry.
  defp reload_athanor(socket) do
    case Sanctum.Tenancy.Athanors.get(socket.assigns.context.athanor_id) do
      {:ok, athanor} ->
        socket
        |> assign(:athanor, athanor)
        |> assign(:answer_mode, Sanctum.Tenancy.Athanors.answer_mode(athanor))

      _ ->
        socket
    end
  end

  defp provisioning_error(athanor) do
    case Sanctum.Tenancy.Athanors.settings(athanor)["provisioning_error"] do
      %{} = error -> error
      _ -> nil
    end
  end

  # `detail` is `inspect/1` of whatever failed — a list of refs, a reason —
  # shown short; the log has the whole of it.
  defp provisioning_detail(athanor) do
    case provisioning_error(athanor) do
      %{"detail" => detail} when is_binary(detail) ->
        if String.length(detail) > 120, do: String.slice(detail, 0, 120) <> "…", else: detail

      _ ->
        ""
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if connected?(socket) do
      ctx = socket.assigns.context
      conversations = Conversations.list(ctx)

      target =
        case params["c"] do
          id when is_binary(id) and id != "" -> Enum.find(conversations, &(&1.id == id))
          _ -> List.first(conversations)
        end

      {:noreply,
       socket
       |> assign(:conversations, conversations)
       |> open(target)}
    else
      {:noreply, socket}
    end
  end

  # Open a conversation: rows, the runner's live state, and its topic. A
  # `nil` is the blank slate — the first message creates the row.
  defp open(socket, nil) do
    socket
    |> unsubscribe_current()
    |> assign(:conversation, nil)
    |> assign(:messages, [])
    |> reset_live()
  end

  defp open(socket, conv) do
    ctx = socket.assigns.context

    socket = unsubscribe_current(socket)
    ConversationRunner.subscribe(conv.id, conv.athanor_id)
    live = ConversationRunner.state(conv.id, conv.athanor_id)

    socket
    |> assign(:conversation, conv)
    |> assign(:messages, Conversations.messages(ctx, conv.id))
    |> reset_live()
    |> apply_live(live)
  end

  defp unsubscribe_current(
         %{assigns: %{conversation: %{id: id, athanor_id: athanor_id}}} = socket
       ) do
    Phoenix.PubSub.unsubscribe(Emissary.PubSub, ConversationRunner.topic(id, athanor_id))
    socket
  end

  defp unsubscribe_current(socket), do: socket

  defp reset_live(socket) do
    socket
    |> assign(:running, false)
    |> assign(:queued, 0)
    |> assign(:turn_user, nil)
    |> assign(:streaming_text, "")
    |> assign(:tool_activity, [])
    |> assign(:token_usage, %{input: 0, output: 0})
    |> assign(:grants, MapSet.new())
    |> assign(:consent_sheet_ref, nil)
    |> assign(:restart_prompt, nil)
    |> assign(:cancel_requested, false)
  end

  defp apply_live(socket, %{} = live) do
    socket
    |> assign(:running, live.running)
    |> assign(:queued, Map.get(live, :queued, 0))
    |> assign(:turn_user, live.turn_user)
    |> assign(:streaming_text, live.streaming_text)
    |> assign(:tool_activity, live.tool_activity)
    |> assign(:token_usage, live.usage)
    |> assign(:grants, live.grants)
    |> assign(:orchestrator, live.orchestrator || socket.assigns.orchestrator)
  end

  defp apply_live(socket, _), do: socket

  # ============================================================================
  # Events
  # ============================================================================

  @impl true
  def handle_event("update_input", %{"message" => value}, socket) do
    {:noreply, assign(socket, :input, value)}
  end

  def handle_event("submit", params, socket) do
    message = String.trim(params["message"] || "")
    has_uploads = socket.assigns.uploads.attachments.entries != []

    if message == "" and not has_uploads,
      do: {:noreply, socket},
      else: send_message(socket, message, consume_attachments(socket))
  end

  # A seeding that failed is retried by any member; the row says how it went.
  def handle_event("provision", _params, socket) do
    case call_tool(socket, "athanor/provision", %{}) do
      {:ok, _} ->
        {:noreply, socket |> reload_athanor() |> put_flash(:info, "Set up — AQUA is ready.")}

      {:error, reason} ->
        {:noreply, socket |> reload_athanor() |> put_flash(:error, "Still not set up: #{reason}")}
    end
  end

  # A group setting: does AQUA answer everything, or only when @-mentioned?
  def handle_event("answer_mode", %{"answer_mode" => mode}, socket) do
    if mode in Sanctum.Tenancy.Athanors.answer_modes() do
      case call_tool(socket, "athanor/settings", %{
             "settings" => %{"aqua" => %{"answer_mode" => mode}}
           }) do
        {:ok, _} -> {:noreply, assign(socket, :answer_mode, mode)}
        {:error, reason} -> {:noreply, put_flash(socket, :error, "Could not save: #{reason}")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("restart_send", _params, %{assigns: %{restart_prompt: text}} = socket)
      when is_binary(text) do
    send_message(assign(socket, :restart_prompt, nil), text, [])
  end

  def handle_event("restart_send", _params, socket), do: {:noreply, socket}

  def handle_event("dismiss_restart", _params, socket),
    do: {:noreply, assign(socket, :restart_prompt, nil)}

  def handle_event("stop", _params, socket) do
    case socket.assigns.conversation do
      nil ->
        {:noreply, socket}

      conv ->
        {:noreply,
         run(socket, &ConversationRunner.stop_turn(&1, conv.id), cancel_requested: true)}
    end
  end

  def handle_event("new_conversation", _params, socket) do
    {:noreply, push_patch(socket, to: chat_path(socket, nil))}
  end

  def handle_event("open_conversation", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: chat_path(socket, id))}
  end

  def handle_event("delete_conversation", %{"id" => id}, socket) do
    ctx = socket.assigns.context

    # The turn may be running in a thread this tab is not looking at: the
    # runner is the fact, not what this socket happens to be rendering.
    if Prism.ConversationRunner.turn_running?(id) do
      {:noreply, put_flash(socket, :error, "Stop the running turn before deleting.")}
    else
      Conversations.delete(ctx, id)
      current = socket.assigns.conversation && socket.assigns.conversation.id

      if current == id do
        {:noreply, push_patch(socket, to: chat_path(socket, nil))}
      else
        {:noreply, assign(socket, :conversations, Conversations.list(ctx))}
      end
    end
  end

  def handle_event("select_orchestrator", %{"name" => name}, socket) do
    ctx = socket.assigns.context
    {:noreply, assign(socket, :orchestrator, Prism.AquaTurn.orchestrator(ctx, name))}
  end

  def handle_event("select_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, :model_override, if(model == "", do: nil, else: model))}
  end

  def handle_event("revoke_grant", %{"tool" => tool, "action" => action}, socket) do
    case socket.assigns.conversation do
      nil -> {:noreply, socket}
      conv -> {:noreply, run(socket, &ConversationRunner.revoke_grant(&1, conv.id, tool, action))}
    end
  end

  def handle_event("approve_all_pending", _params, socket) do
    for msg <- pending_in(socket.assigns.messages),
        do: send(self(), {:approval_approve, msg.id, :once})

    {:noreply, socket}
  end

  def handle_event("decline_all_pending", _params, socket) do
    for msg <- pending_in(socket.assigns.messages),
        do: send(self(), {:approval_decline, msg.id, "", :once})

    {:noreply, socket}
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  # ============================================================================
  # PubSub fan-in
  # ============================================================================

  @impl true
  def handle_info({:conversation, id, event}, %{assigns: %{conversation: %{id: id}}} = socket) do
    {:noreply, handle_conversation_event(socket, event)}
  end

  def handle_info({:conversation, _other, _event}, socket), do: {:noreply, socket}

  # Approval cards dispatch the decision to their parent; the runner runs it.
  def handle_info({:approval_approve, id, scope}, socket) do
    with %{id: conv_id} <- socket.assigns.conversation do
      case ConversationRunner.approve(socket.assigns.context, conv_id, id, scope) do
        :ok ->
          :ok

        {:error, :already_resolved} ->
          :ok

        {:error, reason} ->
          Logger.warning("[ConversationLive] approve failed: #{inspect(reason)}")
      end
    end

    {:noreply, socket}
  end

  def handle_info({:approval_decline, id, reason, scope}, socket) do
    with %{id: conv_id} <- socket.assigns.conversation do
      case ConversationRunner.decline(socket.assigns.context, conv_id, id, reason, scope) do
        :ok -> :ok
        {:error, :already_resolved} -> :ok
        {:error, why} -> Logger.warning("[ConversationLive] decline failed: #{inspect(why)}")
      end
    end

    {:noreply, socket}
  end

  # The consent sheet closes itself once the grant lands; the running turn
  # is cut for the delta and the sender re-sends.
  def handle_info({:consent_granted, _ref, result}, socket) do
    socket = assign(socket, :consent_sheet_ref, nil)

    case socket.assigns.conversation do
      nil ->
        {:noreply, socket}

      conv ->
        {:noreply, run(socket, &ConversationRunner.restart_for_consent(&1, conv.id, result))}
    end
  end

  def handle_info({:consent_sheet_closed, _ref}, socket) do
    {:noreply, assign(socket, :consent_sheet_ref, nil)}
  end

  def handle_info({:list_models_result, {:ok, result}}, socket) do
    raw = result[:result] || result["result"] || result

    decoded =
      cond do
        is_binary(raw) -> Jason.decode(raw) |> elem_or_empty()
        is_map(raw) -> raw
        true -> %{}
      end

    models_by_provider =
      (decoded["models"] || %{})
      |> Map.new(fn {provider, value} ->
        {provider, PrismWeb.AgentsLive.Catalog.normalize_provider_models(value)}
      end)

    {:noreply,
     socket
     |> assign(:models_by_provider, models_by_provider)
     |> assign(:models_loaded, true)}
  end

  def handle_info({:list_models_result, {:error, _}}, socket) do
    {:noreply, assign(socket, :models_loaded, true)}
  end

  def handle_info({:task_timeout, :models}, socket) do
    {:noreply, assign(socket, :models_loaded, true)}
  end

  # A rename or a settings change re-reads the row; an archive closes the
  # page — the runner behind it has already stopped.
  def handle_info({:notify, _athanor_id, :athanor_changed, _payload}, socket) do
    socket = reload_athanor(socket)

    case socket.assigns.athanor do
      %{status: "archived"} ->
        {:noreply,
         socket
         |> put_flash(:error, "This athanor has been archived.")
         |> redirect(to: "/")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Runner events
  # ---------------------------------------------------------------------------

  defp handle_conversation_event(socket, {:message, row}) do
    socket
    |> assign(:messages, upsert_row(socket.assigns.messages, row))
    |> refresh_list()
  end

  defp handle_conversation_event(socket, {:message_updated, row}) do
    assign(socket, :messages, upsert_row(socket.assigns.messages, row))
  end

  # A turn may start for a message queued earlier — the sender's draft of
  # a newer message stays where it is (`send_message/3` clears on send).
  defp handle_conversation_event(socket, {:turn_starting, user_id}) do
    socket
    |> assign(:running, true)
    |> assign(:turn_user, user_id)
    |> assign(:streaming_text, "")
    |> assign(:tool_activity, [])
    |> assign(:token_usage, %{input: 0, output: 0})
  end

  defp handle_conversation_event(socket, {:queued, n}), do: assign(socket, :queued, n)

  defp handle_conversation_event(socket, {:turn_started, _eid}),
    do: assign(socket, :running, true)

  defp handle_conversation_event(socket, {:turn_finished}) do
    socket
    |> assign(:running, false)
    |> assign(:turn_user, nil)
    |> assign(:streaming_text, "")
    |> assign(:tool_activity, [])
    |> assign(:cancel_requested, false)
  end

  defp handle_conversation_event(socket, {:delta, chunk}) do
    assign(socket, :streaming_text, socket.assigns.streaming_text <> chunk)
  end

  defp handle_conversation_event(socket, {:tool_activity, list}),
    do: assign(socket, :tool_activity, list)

  defp handle_conversation_event(socket, {:usage, usage}), do: assign(socket, :token_usage, usage)
  defp handle_conversation_event(socket, {:grants, grants}), do: assign(socket, :grants, grants)

  # Client intents and the consent sheet are the sender's alone: another
  # member's browser must not navigate because this one asked.
  defp handle_conversation_event(socket, {:intents, intents, user_id}) do
    if user_id == socket.assigns.context.user_id, do: push_intents(socket, intents), else: socket
  end

  defp handle_conversation_event(socket, {:consent_required, ref, user_id}) do
    if user_id == socket.assigns.context.user_id,
      do: assign(socket, :consent_sheet_ref, ref),
      else: socket
  end

  defp handle_conversation_event(socket, {:restart_prompt, text, user_id}) do
    if user_id == socket.assigns.context.user_id do
      socket
      |> assign(:restart_prompt, text)
      |> put_flash(:info, "Approved — re-send to continue.")
    else
      socket
    end
  end

  defp handle_conversation_event(socket, {:error, text}), do: put_flash(socket, :error, text)
  defp handle_conversation_event(socket, _), do: socket

  defp upsert_row(rows, row) do
    if Enum.any?(rows, &(&1.id == row.id)),
      do: Enum.map(rows, &if(&1.id == row.id, do: row, else: &1)),
      else: rows ++ [row]
  end

  defp refresh_list(socket) do
    assign(socket, :conversations, Conversations.list(socket.assigns.context))
  end

  # ---------------------------------------------------------------------------
  # Sending
  # ---------------------------------------------------------------------------

  # The message id is minted here so the attachment bytes can be written
  # under it — by this member, in this process — before the runner sees
  # the message; the runner then only records the refs.
  defp send_message(socket, message, files) do
    ctx = socket.assigns.context
    message_id = Emissary.UUID7.generate_id("msg")

    with {:ok, conv} <- current_or_new(socket),
         {:ok, refs} <- Prism.Attachments.store(ctx, conv.id, message_id, files),
         :ok <-
           ConversationRunner.send_message(ctx, conv.id, message,
             id: message_id,
             attachments: refs,
             model: socket.assigns.model_override,
             orchestrator: socket.assigns.orchestrator && socket.assigns.orchestrator["name"]
           ) do
      socket = assign(socket, :input, "")

      if socket.assigns.conversation && socket.assigns.conversation.id == conv.id do
        {:noreply, socket}
      else
        {:noreply, push_patch(socket, to: chat_path(socket, conv.id))}
      end
    else
      {:error, :busy} ->
        {:noreply,
         put_flash(socket, :error, "Too many turns are already waiting — let one finish first.")}

      {:error, :not_member} ->
        {:noreply, put_flash(socket, :error, "You are no longer a member here.")}

      {:error, :archived} ->
        {:noreply,
         socket
         |> put_flash(:error, "This athanor has been archived.")
         |> redirect(to: "/")}

      {:error, :no_orchestrator} ->
        {:noreply, put_flash(socket, :error, "No orchestrator configured — see Agents.")}

      {:error, :storage_full} ->
        {:noreply, put_flash(socket, :error, "This athanor's storage is full.")}

      {:error, :too_many_attachments} ->
        {:noreply, put_flash(socket, :error, "Too many attachments for one message.")}

      {:error, :attachment_too_large} ->
        {:noreply, put_flash(socket, :error, "An attachment is too large.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not send: #{inspect(reason)}")}
    end
  end

  defp current_or_new(%{assigns: %{conversation: %{} = conv}}), do: {:ok, conv}
  defp current_or_new(socket), do: Conversations.create(socket.assigns.context)

  # A runner call for the current member; `assigns` are applied on `:ok`.
  defp run(socket, fun, assigns \\ []) do
    case fun.(socket.assigns.context) do
      :ok -> assign(socket, assigns)
      {:error, reason} -> put_flash(socket, :error, "Could not do that: #{inspect(reason)}")
    end
  end

  defp consume_attachments(socket) do
    consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
      # arca:bypass-ok=D — Plug-managed upload tmp file.
      {:ok,
       %{
         "filename" => entry.client_name,
         "media_type" => entry.client_type,
         "bytes" => File.read!(path)
       }}
    end)
  rescue
    e ->
      Logger.warning("[ConversationLive] consume uploads failed: #{inspect(e)}")
      []
  end

  defp pending_in(messages) do
    Enum.filter(messages, &(&1.kind == "approval" and &1.status == "pending"))
  end

  # Whether this athanor's AQUA can answer at all: an orchestrator, and a
  # model with a key behind it. A fresh furnace has neither, and the chat is
  # where someone finds that out — not the drawer.
  defp model_ready(ctx, orchestrators) do
    case Prism.AgentConfig.model_status(ctx, orchestrators) do
      empty when map_size(empty) == 0 -> :no_model
      statuses -> if Enum.any?(statuses, &match?({_, {:ready, _}}, &1)), do: :ready, else: :no_key
    end
  end

  # What to call the athanor in its own chat: a person's is theirs, a group
  # goes by name.
  defp athanor_label(%{kind: "person"}), do: "your AQUA"
  defp athanor_label(%{name: name}), do: name
  defp athanor_label(_), do: "this athanor"

  # What a message would address, and what to call it: the orchestrator in
  # focus, or the shipped default when the athanor has none yet.
  defp orchestrator_handle(%{"name" => name} = o) when is_binary(name) and name != "",
    do: {name, o["title"] || name}

  defp orchestrator_handle(_), do: {"aqua", "AQUA"}

  # A group's orchestrator can be renamed or replaced from Agents, so the
  # incantation the placeholder teaches has to be the one that works here.
  defp composer_placeholder(%{kind: "group"}, "mentioned", {handle, label}),
    do:
      "Talk to the group · @#{handle} to ask #{label}" <>
        "  (Enter to send · Shift+Enter for newline)"

  defp composer_placeholder(_athanor, _mode, {_handle, label}),
    do: "Ask #{label}…  (Enter to send · Shift+Enter for newline)"

  # The route a second device reads an attachment's bytes from.
  defp attachment_path(athanor_route, message_id, filename) do
    PrismWeb.Focus.path(
      athanor_route,
      "/attachments/#{URI.encode(message_id)}/#{URI.encode(filename)}"
    )
  end

  defp chat_path(socket, nil), do: PrismWeb.Focus.path(socket.assigns.athanor_route, "")

  defp chat_path(socket, id),
    do: PrismWeb.Focus.path(socket.assigns.athanor_route, "?c=" <> URI.encode_www_form(id))

  # Navigate intents are page paths (`/activities`); the athanor in focus is
  # added here, so the agent never addresses another athanor's pages.
  defp push_intents(socket, []), do: socket

  defp push_intents(socket, intents) do
    route = socket.assigns.athanor_route

    intents =
      Enum.map(intents, fn
        %{kind: "navigate", to: to} = intent -> %{intent | to: PrismWeb.Focus.path(route, to)}
        intent -> intent
      end)

    push_event(socket, "aqua:intents", %{intents: intents})
  end

  # ---------------------------------------------------------------------------
  # Models (async, best-effort)
  # ---------------------------------------------------------------------------

  defp load_models(socket) do
    ctx = socket.assigns.context
    lv = self()

    if Cyfr.Execution.available?() do
      Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
        result =
          Emissary.MCP.ToolRegistry.call_external("execution", ctx, %{
            "action" => "run",
            "reference" => @list_models_ref,
            "input" => %{}
          })

        send(lv, {:list_models_result, result})
      end)

      Process.send_after(lv, {:task_timeout, :models}, 15_000)
      socket
    else
      assign(socket, :models_loaded, true)
    end
  end

  defp elem_or_empty({:ok, %{} = m}), do: m
  defp elem_or_empty(_), do: %{}

  defp member_labels(ctx) do
    Sanctum.Tenancy.Members.list_by_athanor(ctx.athanor_id)
    |> Enum.reduce(%{}, fn m, acc ->
      case m.user_id do
        nil -> acc
        id -> Map.put(acc, id, m.display_name || m.email || id)
      end
    end)
  rescue
    _ -> %{}
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div id="conversation-root" phx-hook="Conversation" class="flex h-full min-h-0">
      <!-- The athanor's threads: a column beside the chat, a panel over it on a phone -->
      <aside
        id="conversation-list"
        class="flex w-64 shrink-0 flex-col border-r border-gray-800 bg-gray-900/40 max-md:fixed max-md:inset-y-12 max-md:bottom-0 max-md:left-0 max-md:z-30 max-md:hidden max-md:bg-gray-900 max-md:shadow-xl md:flex"
      >
        <div class="flex items-center justify-between px-3 py-2 border-b border-gray-800">
          <span class="text-xs font-semibold uppercase tracking-wider text-gray-500">Chats</span>
          <div class="flex items-center gap-1">
            <button
              type="button"
              phx-click="new_conversation"
              class="rounded px-2 py-1 text-[11px] uppercase tracking-wider text-gray-400 hover:bg-gray-800 hover:text-gray-200"
              title="Start a new conversation"
            >
              + New
            </button>
            <button
              type="button"
              phx-click={JS.add_class("max-md:hidden", to: "#conversation-list")}
              class="md:hidden rounded px-2 py-1 text-gray-400 hover:bg-gray-800 hover:text-gray-200"
              aria-label="Close the list"
            >
              ×
            </button>
          </div>
        </div>
        <div :if={@conversations == []} class="px-3 py-4 text-xs text-gray-500">
          No conversations yet.
        </div>
        <ul class="flex-1 overflow-y-auto divide-y divide-gray-800/60">
          <li
            :for={conv <- @conversations}
            id={"conv-" <> conv.id}
            class={[
              "group flex items-start gap-2 px-3 py-2 text-xs cursor-pointer hover:bg-gray-800/50",
              if(@conversation && conv.id == @conversation.id, do: "bg-gray-800/80", else: "")
            ]}
            phx-click={
              JS.push("open_conversation", value: %{id: conv.id})
              |> JS.add_class("max-md:hidden", to: "#conversation-list")
            }
          >
            <div class="flex-1 min-w-0">
              <p class="text-gray-200 truncate">{conv.title}</p>
              <p class="text-[10px] text-gray-600 mt-0.5">
                {Calendar.strftime(conv.last_message_at || conv.inserted_at, "%b %d %H:%M")}
                <span :if={conv.execution_id} class="ml-1 text-blue-400">● running</span>
              </p>
            </div>
            <button
              type="button"
              phx-click="delete_conversation"
              phx-value-id={conv.id}
              class="opacity-0 group-hover:opacity-100 text-gray-500 hover:text-red-400 shrink-0"
              data-confirm="Delete this conversation for everyone?"
              aria-label="Delete"
            >
              ×
            </button>
          </li>
        </ul>
      </aside>

      <section class="flex flex-1 min-w-0 flex-col">
        <header class="flex items-center justify-between gap-2 border-b border-gray-800 px-4 py-2">
          <div class="flex items-center gap-2 min-w-0">
            <button
              type="button"
              phx-click={JS.toggle_class("max-md:hidden", to: "#conversation-list")}
              class="md:hidden rounded px-1.5 py-1 text-[11px] uppercase tracking-wider text-gray-400 hover:bg-gray-800 hover:text-gray-200"
              title="Chats"
            >
              Chats
            </button>
            <span class="text-sm font-medium text-gray-200 shrink-0">A.Q.U.A.</span>
            <!-- Which furnace this chat is: a key bound here is bound here. -->
            <span class="text-xs text-gray-500 shrink-0 truncate max-w-[10rem]">
              in {athanor_label(@athanor)}
            </span>
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
            <span :if={@orchestrators == []} class="text-xs text-amber-400">
              No orchestrator configured
            </span>
            <select
              :if={@athanor.kind == "group"}
              phx-change="answer_mode"
              name="answer_mode"
              class="bg-transparent text-[10px] text-gray-500 hover:text-gray-300 border-none focus:ring-0 focus:outline-none cursor-pointer"
              title="When AQUA answers in this group"
            >
              <option value="mentioned" selected={@answer_mode == "mentioned"}>
                answers when @mentioned
              </option>
              <option value="all" selected={@answer_mode == "all"}>answers everything</option>
            </select>
            <span
              :if={@queued > 0}
              class="shrink-0 inline-flex items-center rounded bg-gray-800 px-1.5 py-0.5 text-[10px] text-gray-300"
              title="Messages waiting for AQUA"
            >
              {@queued} queued
            </span>
            <span
              :if={MapSet.size(@grants) > 0}
              class="shrink-0 inline-flex items-center rounded bg-gray-800 px-1.5 py-0.5 text-[10px] text-gray-300"
              title="Actions auto-approved for this conversation"
            >
              +{MapSet.size(@grants)} this chat
            </span>
            <select
              :if={@models_loaded and @models_by_provider != %{}}
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
                  <option :for={m <- models} value={m} selected={@model_override == m}>{m}</option>
                </optgroup>
              <% end %>
            </select>
          </div>
          <div class="flex items-center gap-1">
            <span
              :if={@running and @turn_user}
              class="text-[11px] text-gray-500 truncate max-w-[12rem]"
            >
              {label_for(@members, @turn_user, @context)} is asking…
            </span>
            <button
              :if={@running}
              type="button"
              phx-click="stop"
              class="rounded px-2 py-1 text-[11px] uppercase tracking-wider bg-red-900/60 text-red-200 hover:bg-red-800/80"
              title="Halt the agent (⌘.)"
            >
              ◼ {if @cancel_requested, do: "Cancelling…", else: "Stop"}
            </button>
            <.link
              navigate={PrismWeb.Focus.path(@athanor_route, "/agents")}
              class="rounded px-2 py-1 text-[11px] uppercase tracking-wider text-gray-500 hover:bg-gray-800 hover:text-gray-300"
            >
              Agents
            </.link>
          </div>
        </header>

        <div
          :if={is_nil(@athanor.provisioned_at)}
          class="flex items-center justify-between gap-3 border-b border-amber-900/60 bg-amber-950/40 px-4 py-2 text-xs text-amber-200"
        >
          <span class="min-w-0 truncate">
            This athanor is still being set up
            <span :if={provisioning_error(@athanor)} class="text-amber-300/80">
              — last attempt failed at {provisioning_error(@athanor)["step"]}: {provisioning_detail(
                @athanor
              )}
            </span>
          </span>
          <button
            type="button"
            phx-click="provision"
            class="shrink-0 rounded px-2 py-1 text-[11px] uppercase tracking-wider bg-amber-800/60 text-amber-100 hover:bg-amber-700/80"
          >
            Retry
          </button>
        </div>

        <div
          id="conversation-thread"
          phx-hook="ScrollBottom"
          class="flex-1 overflow-y-auto px-4 py-3 space-y-3"
        >
          <div
            :if={@messages == [] and @streaming_text == ""}
            class="flex flex-col items-center justify-center h-full gap-2 text-sm text-gray-500"
          >
            <%= if @model_ready in [:no_model, :no_key] do %>
              <span>{athanor_label(@athanor)} has no model yet.</span>
              <.link
                navigate={PrismWeb.Focus.path(@athanor_route, "/agents")}
                class="text-blue-400 hover:text-blue-300"
              >
                Connect a model
              </.link>
            <% else %>
              <span>Ask {elem(orchestrator_handle(@orchestrator), 1)} anything.</span>
            <% end %>
          </div>

          <div
            :if={MapSet.size(@grants) > 0}
            class="flex flex-wrap items-center gap-1.5 text-[10px] text-gray-500"
          >
            <span>auto-approving this chat:</span>
            <span
              :for={{tool, action} <- @grants}
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

          <% pending = pending_in(@messages) %>
          <div
            :if={length(pending) > 1}
            class="sticky top-0 z-10 flex items-center gap-2 rounded bg-amber-900/30 border border-amber-800/50 px-2.5 py-1 text-[11px] text-amber-200"
          >
            <span>{length(pending)} pending approvals</span>
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
            <%= if msg.kind == "approval" do %>
              <% intent = Conversations.payload(msg)["intent"] || %{} %>
              <% resolution = Conversations.resolution(msg) %>
              <.live_component
                module={PrismWeb.AquaApprovalCard}
                id={msg.id}
                payload={intent}
                status={msg.status}
                decided_at={msg.resolved_at}
                reason={resolution["reason"]}
                result_summary={resolution["summary"]}
                scope={scope_atom(resolution["scope"])}
                resolved_by={msg.resolved_by && label_for(@members, msg.resolved_by, @context)}
                agent_label={@orchestrator && @orchestrator["title"]}
                shared_with={@athanor.kind == "group" && @athanor.name}
              />
            <% else %>
              <.message_bubble
                id={"msg-" <> msg.id}
                role={role_of(msg)}
                content={msg.content}
                author={author_label(msg, @members, @context)}
                attachments={Conversations.payload(msg)["attachments"] || []}
                attachment_href={&attachment_path(@athanor_route, msg.id, &1)}
              />
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

          <.message_bubble
            :if={@streaming_text != ""}
            id="msg-streaming"
            role="assistant"
            content={@streaming_text}
          />

          <div
            :if={@running and @streaming_text == "" and @tool_activity == []}
            class="flex items-center gap-2 text-xs text-gray-500"
          >
            <span class="inline-block h-2 w-2 animate-pulse rounded-full bg-blue-400" />
            <span>Thinking…</span>
          </div>
        </div>

        <div
          :if={@consent_sheet_ref}
          class="border-t border-emerald-800/60 bg-emerald-900/10 px-3 py-3 max-h-[50vh] overflow-y-auto"
        >
          <.live_component
            module={PrismWeb.ConsentSheetComponent}
            id={"consent-#{@consent_sheet_ref}"}
            ref={@consent_sheet_ref}
            context={@context}
            athanor_route={@athanor_route}
            athanor_name={@athanor && @athanor.name}
          />
        </div>

        <div
          :if={@restart_prompt}
          class="flex items-center gap-2 border-t border-blue-900/60 bg-blue-900/10 px-3 py-2 text-xs text-blue-200"
        >
          <span class="truncate">The turn was cut for the new consent — send it again?</span>
          <button
            type="button"
            phx-click="restart_send"
            class="ml-auto rounded bg-blue-700 px-2 py-0.5 text-white hover:bg-blue-600"
          >
            Re-send
          </button>
          <button
            type="button"
            phx-click="dismiss_restart"
            class="rounded px-2 py-0.5 text-gray-400 hover:text-gray-200"
          >
            Dismiss
          </button>
        </div>

        <form
          phx-submit="submit"
          phx-change="validate_upload"
          class="border-t border-gray-800 p-3 space-y-2"
        >
          <div :if={@uploads.attachments.entries != []} class="flex flex-wrap gap-1">
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
              class="self-end rounded-md border border-gray-700 bg-gray-800 px-2 py-2 text-sm text-gray-400 hover:bg-gray-700 cursor-pointer"
              title="Attach files"
            >
              📎 <.live_file_input upload={@uploads.attachments} class="hidden" />
            </label>
            <textarea
              id="conversation-textarea"
              phx-hook="AquaChat"
              name="message"
              phx-change="update_input"
              rows="1"
              placeholder={
                composer_placeholder(@athanor, @answer_mode, orchestrator_handle(@orchestrator))
              }
              class="flex-1 resize-none rounded-md border border-gray-700 bg-gray-950 px-3 py-1.5 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:outline-none max-h-40 overflow-y-auto"
              autofocus
              disabled={@orchestrators == []}
            >{@input}</textarea>
            <button
              type="submit"
              disabled={@orchestrators == [] or (@input == "" and @uploads.attachments.entries == [])}
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
          <span class="truncate">
            {if @conversation, do: @conversation.title, else: "New conversation"}
          </span>
          <span :if={@token_usage.input > 0 or @token_usage.output > 0} class="font-mono shrink-0">
            {@token_usage.input} in / {@token_usage.output} out
          </span>
        </div>
      </section>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :role, :string, required: true
  attr :content, :string, required: true
  attr :author, :any, default: nil
  attr :attachments, :list, default: []
  attr :attachment_href, :any, default: nil

  defp message_bubble(assigns) do
    # Strip aqua-actions blocks for display, then trim — a stray block or the
    # model's surrounding whitespace would inflate the bubble.
    display = assigns.content |> Prism.AquaActions.strip_blocks() |> String.trim()
    assigns = assign(assigns, :display_content, display)

    ~H"""
    <div class={["flex flex-col", role_align(@role)]}>
      <span :if={@author} class="text-[10px] text-gray-500 mb-0.5 px-1">{@author}</span>
      <div class={[
        "max-w-[85%] rounded-lg px-3 py-1.5 text-sm break-words",
        role_class(@role)
      ]}>
        <%= if @role == "assistant" do %>
          <div
            id={@id}
            phx-hook="MarkdownContent"
            phx-update="ignore"
            data-raw-content={@display_content}
            class="prose prose-invert prose-sm max-w-none"
          >
          </div>
        <% else %>
          <span class="whitespace-pre-wrap">{@display_content}</span>
        <% end %>
        <div :if={@attachments != []} class="mt-1 flex flex-wrap gap-1">
          <%= for a <- @attachments do %>
            <a
              :if={@attachment_href && a["path"]}
              href={@attachment_href.(a["filename"])}
              download={a["filename"]}
              class="inline-flex items-center rounded bg-black/20 px-1.5 py-0.5 text-[10px] hover:bg-black/40 underline-offset-2 hover:underline"
            >
              📎 {a["filename"]}
            </a>
            <span
              :if={!(@attachment_href && a["path"])}
              class="inline-flex items-center rounded bg-black/20 px-1.5 py-0.5 text-[10px]"
            >
              📎 {a["filename"]}
            </span>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp role_of(%{kind: "error"}), do: "error"
  defp role_of(%{kind: "system"}), do: "system"
  defp role_of(%{author: "aqua"}), do: "assistant"
  defp role_of(_), do: "user"

  defp author_label(%{author: "aqua"}, _members, _ctx), do: nil
  defp author_label(%{author: "system"}, _members, _ctx), do: nil
  defp author_label(%{kind: kind}, _members, _ctx) when kind in ["error", "system"], do: nil
  defp author_label(%{author: author}, members, ctx), do: label_for(members, author, ctx)

  defp label_for(_members, user_id, %{user_id: user_id}), do: "You"

  defp label_for(members, user_id, _ctx) when is_binary(user_id) do
    Map.get(members, user_id) || PrismWeb.DisplayHelpers.principal_label(user_id)
  end

  defp label_for(_members, _user_id, _ctx), do: nil

  defp scope_atom("conversation"), do: :conversation
  defp scope_atom("always"), do: :always
  defp scope_atom("never"), do: :never
  defp scope_atom(_), do: :once

  defp role_align("user"), do: "items-end"
  defp role_align(_), do: "items-start"

  defp role_class("user"), do: "bg-indigo-600 text-white"
  defp role_class("error"), do: "bg-red-900/40 text-red-300 border border-red-800"
  defp role_class("system"), do: "bg-gray-800/60 text-gray-400 border border-gray-800 italic"
  defp role_class(_), do: "bg-gray-800 text-gray-200"
end
