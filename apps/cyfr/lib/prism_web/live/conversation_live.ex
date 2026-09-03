# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ConversationLive do
  @moduledoc """
  The athanor's chat — where `/a/<athanor>` lands.

  A window onto `Aqua.ConversationRunner`: the thread is the conversation's
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
  alias Aqua.ConversationRunner

  @impl true
  def mount(_params, _session, socket) do
    ctx = socket.assigns[:context]

    socket =
      socket
      |> assign(:page_title, "Chat")
      |> assign(:active_nav, "chat")
      |> assign(:conversations, [])
      |> assign(:followed, MapSet.new())
      |> assign(:aloud_for, nil)
      |> assign(:aloud_targets, [])
      |> assign(:aloud_estate, nil)
      |> assign(:aloud_topics, [])
      |> assign(:conversation, nil)
      |> stream(:messages, [])
      |> assign(:pending_approvals, [])
      |> assign(:any_messages, false)
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
      # Whether this estate needs a mention — the same derivation the
      # runner makes, so the composer's placeholder and the addressing rule
      # cannot disagree. Assigned at mount too: the first render happens
      # before any runner exists.
      |> assign(:solo_human, ctx && Sanctum.Tenancy.Members.solo?(ctx.athanor_id))
      |> allow_upload(:attachments,
        accept: :any,
        max_entries: Aqua.Attachments.limits().max_files,
        # 20 MB — sized with EmissaryWeb.Endpoint's Plug.Parsers :length so a
        # base64-encoded attachment of this size fits through POST /mcp.
        max_file_size: Aqua.Attachments.limits().max_file_bytes,
        auto_upload: true
      )

    socket =
      if connected?(socket) and ctx do
        Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Notify.topic(ctx.athanor_id))

        orchestrators = Aqua.Turn.orchestrators(ctx)

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

  # The athanor row as it is now — after a settings change or a provisioning retry.
  defp reload_athanor(socket) do
    case Sanctum.Tenancy.Athanors.get(socket.assigns.context.athanor_id) do
      {:ok, athanor} ->
        socket
        |> assign(:athanor, athanor)

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
       |> refresh_followed()
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
    |> stream(:messages, [], reset: true)
    |> assign(:pending_approvals, [])
    |> assign(:any_messages, false)
    |> reset_live()
  end

  defp open(socket, conv) do
    ctx = socket.assigns.context

    socket = unsubscribe_current(socket)
    ConversationRunner.subscribe(conv.id, conv.athanor_id)
    live = ConversationRunner.state(conv.id, conv.athanor_id)

    # Newest window only: unbounded, this read loaded every row of a
    # long-lived conversation into every viewer's socket. The runner's own
    # turn assembly stays windowed separately (after_seq/upto_seq).
    rows =
      case Conversations.latest_messages(ctx, conv.id, 500) do
        rows when is_list(rows) -> rows
        {:error, _} -> []
      end

    socket
    |> assign(:conversation, conv)
    |> stream(:messages, rows, reset: true)
    |> assign(:pending_approvals, pending_in(rows))
    |> assign(:any_messages, rows != [])
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
    |> assign(:solo_human, Map.get(live, :solo_human, false))
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

    cond do
      message == "" and not has_uploads ->
        {:noreply, socket}

      true ->
        case consume_attachments(socket) do
          {:ok, files} ->
            send_message(socket, message, files)

          {:error, :attachments_unreadable} ->
            {:noreply,
             put_flash(socket, :error, "Could not read the attachments — try adding them again.")}
        end
    end
  end

  # A seeding that failed is retried by any member; the row says how it went.
  def handle_event("provision", _params, socket) do
    case call_tool(socket, "athanor/provision", %{}) do
      {:ok, _} ->
        {:noreply, socket |> reload_athanor() |> put_flash(:info, "Set up — AQUA is ready.")}

      {:error, reason} ->
        # error_message/1, not interpolation: the registry answers with
        # tuple reasons ({:tool_auth_required, _}, {:timeout, _}, …) and
        # interpolating one crashes the LiveView mid-render.
        {:noreply,
         socket
         |> reload_athanor()
         |> put_flash(:error, "Still not set up: #{error_message(reason)}")}
    end
  end

  # A group setting: does AQUA answer everything, or only when @-mentioned?
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
    # Deliberately does NOT follow: reading a thread is not joining it.
    {:noreply, push_patch(socket, to: chat_path(socket, id))}
  end

  # Saying one of your own private lines out loud: pick an estate you
  # belong to, then one of its topics. The rules (author-only, membership
  # on both sides, byte-copied attachments) are `Aqua.Aloud`'s — this UI
  # drives the same `conversation.aloud` verb a headless client has.
  def handle_event("aloud_open", %{"id" => msg_id}, socket) do
    # Every active estate the person belongs to except this one — the
    # verb's own domain (membership both sides), so a DM or your own
    # athanor is as much a target as a team room. DMs are labeled.
    targets =
      case call_tool(socket, "athanor/list", %{}) do
        {:ok, %{athanors: athanors}} ->
          Enum.filter(
            athanors,
            &(&1[:status] == "active" and &1[:id] != socket.assigns.context.athanor_id)
          )

        _ ->
          []
      end

    {:noreply,
     socket
     |> assign(:aloud_for, msg_id)
     |> assign(:aloud_targets, targets)
     |> assign(:aloud_estate, nil)
     |> assign(:aloud_topics, [])}
  end

  def handle_event("aloud_pick_estate", %{"athanor" => athanor_id}, socket) do
    # `focus/2` is the audited narrowing entry — membership checked, an
    # archived estate refused — and the read lists that estate's topics.
    case Sanctum.Context.focus(socket.assigns.context, athanor_id) do
      {:ok, focused} ->
        {:noreply,
         socket
         |> assign(:aloud_estate, athanor_id)
         |> assign(:aloud_topics, Conversations.list(focused))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "You are not a member of that estate.")}
    end
  end

  def handle_event("aloud_post", %{"conversation" => topic_id}, socket) do
    %{conversation: conv, aloud_for: msg_id, aloud_estate: estate} = socket.assigns

    result =
      call_tool(socket, "conversation/aloud", %{
        "conversation" => conv.id,
        "message_ids" => [msg_id],
        "target_athanor" => estate,
        "target_conversation" => topic_id
      })

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:aloud_for, nil)
         |> put_flash(:info, "Said aloud — a copy is on that thread, attributed to you.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not say it aloud: #{error_message(reason)}")}
    end
  end

  def handle_event("aloud_cancel", _params, socket) do
    {:noreply, assign(socket, :aloud_for, nil)}
  end

  def handle_event("follow_topic", %{"id" => id}, socket) do
    ctx = socket.assigns.context

    case Arca.TopicSubscriptionStorage.follow(ctx, id, ctx.user_id) do
      :ok -> {:noreply, refresh_followed(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not follow — try again.")}
    end
  end

  def handle_event("unfollow_topic", %{"id" => id}, socket) do
    ctx = socket.assigns.context

    case Arca.TopicSubscriptionStorage.unfollow(ctx, id, ctx.user_id) do
      :ok -> {:noreply, refresh_followed(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not unfollow — try again.")}
    end
  end

  def handle_event("delete_conversation", %{"id" => id}, socket) do
    ctx = socket.assigns.context

    # The turn may be running in a thread this tab is not looking at: the
    # runner is the fact, not what this socket happens to be rendering.
    # Check-then-act across a process boundary: a turn that starts in the
    # window has its conversation deleted from under it — accepted, because
    # the runner degrades cleanly (its next append re-fetches and gets
    # :not_found), and serializing would mean starting a runner just to
    # delete its conversation.
    if Aqua.ConversationRunner.turn_running?(ctx, id) do
      {:noreply, put_flash(socket, :error, "Stop the running turn before deleting.")}
    else
      case Conversations.delete(ctx, id) do
        :ok ->
          current = socket.assigns.conversation && socket.assigns.conversation.id

          if current == id do
            {:noreply, push_patch(socket, to: chat_path(socket, nil))}
          else
            {:noreply, assign(socket, :conversations, Conversations.list(ctx))}
          end

        {:error, reason} ->
          # A failed delete leaves the row listed; saying nothing made the
          # button look broken.
          {:noreply, put_flash(socket, :error, "Delete failed: #{error_message(reason)}")}
      end
    end
  end

  # The option value is `owner/name` — two rosters can hold the same name
  # (yours and the estate's), so a bare name cannot say which tree to read.
  def handle_event("select_orchestrator", %{"name" => value}, socket) do
    ctx = socket.assigns.context
    {name, owner} = split_orchestrator_value(value)
    {:noreply, assign(socket, :orchestrator, Aqua.Turn.orchestrator(ctx, name, owner))}
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
    for msg <- socket.assigns.pending_approvals,
        do: send(self(), {:approval_approve, msg.id, :once})

    {:noreply, socket}
  end

  def handle_event("decline_all_pending", _params, socket) do
    for msg <- socket.assigns.pending_approvals,
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

  # Approval cards dispatch the decision to their parent; the runner runs
  # it. A refusal reaches the person who clicked — log-only made the button
  # appear to do nothing.
  def handle_info({:approval_approve, id, scope}, socket) do
    case socket.assigns.conversation do
      %{id: conv_id} ->
        case ConversationRunner.approve(socket.assigns.context, conv_id, id, scope) do
          :ok ->
            {:noreply, socket}

          {:error, :already_resolved} ->
            {:noreply, socket}

          {:error, {:scope_not_permitted, kind}} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "A #{kind} action always asks — 'always' cannot be granted for it."
             )}

          {:error, reason} ->
            Logger.warning("[ConversationLive] approve failed: #{inspect(reason)}")
            {:noreply, put_flash(socket, :error, "Approve failed: #{error_message(reason)}")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:approval_decline, id, reason, scope}, socket) do
    case socket.assigns.conversation do
      %{id: conv_id} ->
        case ConversationRunner.decline(socket.assigns.context, conv_id, id, reason, scope) do
          :ok ->
            {:noreply, socket}

          {:error, :already_resolved} ->
            {:noreply, socket}

          {:error, why} ->
            Logger.warning("[ConversationLive] decline failed: #{inspect(why)}")
            {:noreply, put_flash(socket, :error, "Decline failed: #{error_message(why)}")}
        end

      _ ->
        {:noreply, socket}
    end
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
    %{models: models} = PrismWeb.ModelCatalog.parse(result)

    {:noreply,
     socket
     |> assign(:models_by_provider, models)
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

  def handle_info(msg, socket) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Runner events
  # ---------------------------------------------------------------------------

  defp handle_conversation_event(socket, {:message, row}) do
    socket
    |> upsert_message(row)
    |> refresh_list()
  end

  defp handle_conversation_event(socket, {:message_updated, row}) do
    upsert_message(socket, row)
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

  # The stream owns membership and ordering (stream_insert replaces an
  # existing dom id in place); only the two derived facts the templates
  # and the approve-all handlers read are kept as assigns.
  defp upsert_message(socket, row) do
    pending =
      Enum.reject(socket.assigns.pending_approvals, &(&1.id == row.id))

    pending =
      if row.kind == "approval" and row.status == "pending",
        do: pending ++ [row],
        else: pending

    socket
    |> stream_insert(:messages, row)
    |> assign(:pending_approvals, pending)
    |> assign(:any_messages, true)
  end

  defp refresh_list(socket) do
    socket
    |> assign(:conversations, Conversations.list(socket.assigns.context))
    |> refresh_followed()
  end

  # Which of the estate's topics are in this person's sidebar. The list
  # itself is every topic — following decides emphasis and notification,
  # never visibility, so this read failing costs a dimmed list and nothing
  # more.
  defp refresh_followed(socket) do
    ctx = socket.assigns.context
    assign(socket, :followed, Arca.TopicSubscriptionStorage.followed(ctx, ctx.user_id))
  end

  defp followed?(followed, %{id: id}), do: MapSet.member?(followed, id)

  attr :conv, :map, required: true
  attr :current, :any, default: nil
  attr :followed, :boolean, required: true

  # One topic in the sidebar. Follow/unfollow is a word, not a glyph — the
  # action must read as what it does. Following decides emphasis and
  # notification, never access: every row opens on a click.
  defp topic_row(assigns) do
    ~H"""
    <li
      id={"conv-" <> @conv.id}
      class={[
        "group flex items-start gap-2 px-3 py-2 text-xs cursor-pointer hover:bg-gray-800/50",
        if(@current && @conv.id == @current.id, do: "bg-gray-800/80", else: "")
      ]}
      phx-click={
        JS.push("open_conversation", value: %{id: @conv.id})
        |> JS.add_class("max-md:hidden", to: "#conversation-list")
      }
    >
      <div class="flex-1 min-w-0">
        <p class={["truncate", if(@followed, do: "text-gray-200", else: "text-gray-400")]}>
          {@conv.title}
        </p>
        <p class="text-[10px] text-gray-600 mt-0.5">
          {Calendar.strftime(@conv.last_message_at || @conv.inserted_at, "%b %d %H:%M")}
          <span :if={@conv.execution_id} class="ml-1 text-blue-400">● running</span>
        </p>
      </div>
      <button
        type="button"
        phx-click={if @followed, do: "unfollow_topic", else: "follow_topic"}
        phx-value-id={@conv.id}
        class="opacity-0 group-hover:opacity-100 text-[10px] text-gray-500 hover:text-gray-200 shrink-0"
      >
        {if @followed, do: "Unfollow", else: "Follow"}
      </button>
      <button
        type="button"
        phx-click="delete_conversation"
        phx-value-id={@conv.id}
        class="opacity-0 group-hover:opacity-100 text-gray-500 hover:text-red-400 shrink-0"
        data-confirm="Delete this conversation for everyone?"
        aria-label="Delete"
      >
        ×
      </button>
    </li>
    """
  end

  # ---------------------------------------------------------------------------
  # Sending
  # ---------------------------------------------------------------------------

  # The message id is minted here so the attachment bytes can be written
  # under it — by this member, in this process — before the runner sees
  # the message; the runner then only records the refs.
  defp send_message(socket, message, files) do
    ctx = socket.assigns.context
    message_id = Cyfr.UUID7.generate_id("msg")

    with {:ok, conv} <- current_or_new(socket),
         {:ok, refs} <- Aqua.Attachments.store(ctx, conv.id, message_id, files),
         :ok <-
           send_or_discard(ctx, conv, message, message_id, refs, socket) do
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

      {:error, :storage_unverifiable} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Storage usage can't be verified right now — try again."
         )}

      {:error, :message_too_long} ->
        {:noreply,
         put_flash(socket, :error, "That message is too long — up to 32 KiB of text per line.")}

      {:error, :too_many_attachments} ->
        {:noreply, put_flash(socket, :error, "Too many attachments for one message.")}

      {:error, :attachment_too_large} ->
        {:noreply, put_flash(socket, :error, "An attachment is too large.")}

      {:error, :storage_error} ->
        {:noreply,
         put_flash(socket, :error, "Storing the attachments failed — nothing was sent.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not send: #{error_message(reason)}")}
    end
  end

  # The attachment bytes are written before the runner sees the message, so
  # that this member writes them in this process. A refused send therefore
  # leaves blobs behind that belong to no row — nothing lists them, nothing
  # reads them, and they count against the athanor's quota. The runner is
  # where the refusal is decided (membership, archive, a full queue), so
  # the cleanup belongs on its answer.
  defp send_or_discard(ctx, conv, message, message_id, refs, socket) do
    case ConversationRunner.send_message(ctx, conv.id, message,
           id: message_id,
           attachments: refs,
           model: socket.assigns.model_override,
           # The whole entry, not the name: the runner must know whose tree
           # the picked agent lives in.
           orchestrator: socket.assigns.orchestrator
         ) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        Aqua.Attachments.discard(ctx, conv.id, message_id, refs)
        error
    end
  end

  defp current_or_new(%{assigns: %{conversation: %{} = conv}}), do: {:ok, conv}
  defp current_or_new(socket), do: Conversations.create(socket.assigns.context)

  # A runner call for the current member; `assigns` are applied on `:ok`.
  defp run(socket, fun, assigns \\ []) do
    case fun.(socket.assigns.context) do
      :ok -> assign(socket, assigns)
      {:error, reason} -> put_flash(socket, :error, "Could not do that: #{error_message(reason)}")
    end
  end

  defp consume_attachments(socket) do
    files =
      consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
        # arca:bypass-ok=D — Plug-managed upload tmp file.
        {:ok,
         %{
           "filename" => entry.client_name,
           "media_type" => entry.client_type,
           # arca:bypass-ok=D — Plug-managed upload tmp file.
           "bytes" => File.read!(path)
         }}
      end)

    {:ok, files}
  rescue
    e ->
      Logger.warning("[ConversationLive] consume uploads failed: #{Exception.message(e)}")
      {:error, :attachments_unreadable}
  end

  defp pending_in(messages) do
    Enum.filter(messages, &(&1.kind == "approval" and &1.status == "pending"))
  end

  # Whether this athanor's AQUA can answer at all: an orchestrator, and a
  # model with a key behind it. A fresh furnace has neither, and the chat is
  # where someone finds that out — not the drawer.
  defp model_ready(ctx, orchestrators) do
    case Aqua.AgentConfig.model_status(ctx, orchestrators) do
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
  # focus, or the shipped default when the athanor has none yet. A personal
  # agent working in another estate is addressed QUALIFIED — the incantation
  # the placeholder teaches must be the one that resolves here, and the bare
  # name may mean the estate's own agent instead.
  defp orchestrator_handle(%{"name" => name} = o, athanor)
       when is_binary(name) and name != "" do
    focus = athanor && athanor.id

    handle =
      if is_binary(o["owner"]) and o["owner"] != focus and is_binary(o["owner_slug"]),
        do: "#{o["owner_slug"]}.#{name}",
        else: name

    {handle, o["title"] || name}
  end

  # No roster entry at all: teach nothing rather than a handle that does
  # not resolve — the "No orchestrator configured" note beside the picker
  # is the honest sentence.
  defp orchestrator_handle(_, _athanor), do: nil

  # What the composer and picker treat as current before any explicit
  # selection: the roster's first entry — the estate's, the same default
  # `pick_orchestrator/4` falls back to when nothing else picks. Before
  # this, a fresh estate taught `@aqua` even when its only agent was
  # named something else, and no picker row rendered selected.
  defp current_orchestrator(nil, roster), do: List.first(roster)
  defp current_orchestrator(%{} = orchestrator, _roster), do: orchestrator

  defp same_entry?(%{} = a, o), do: a["name"] == o["name"] and a["owner"] == o["owner"]
  defp same_entry?(_, _o), do: false

  defp agent_label(%{} = o), do: o["title"] || o["name"]
  defp agent_label(_), do: "your agent"

  # The picker names a personal agent by its qualified handle so two
  # same-named rows read as two agents, not a duplicate.
  defp option_label(%{"estate?" => false, "owner_slug" => slug} = o) when is_binary(slug),
    do: "#{o["title"]} (@#{slug}.#{o["name"]})"

  defp option_label(o), do: o["title"]

  # `owner/name` back apart. A value with no slash is a bare name from an
  # older client render — resolved ownerless, in the estate in focus.
  defp split_orchestrator_value(value) when is_binary(value) do
    case String.split(value, "/", parts: 2) do
      [owner, name] -> {name, owner}
      [name] -> {name, nil}
    end
  end

  # A group's orchestrator can be renamed or replaced from Agents, so the
  # incantation the placeholder teaches has to be the one that works here.
  # Whether a mention is needed is derived from how many people are here,
  # so the placeholder asks the same question the runner does rather than
  # reading a setting that no longer exists.
  defp composer_placeholder(false, {handle, label}),
    do:
      "Talk to the group · @#{handle} to ask #{label}" <>
        "  (Enter to send · Shift+Enter for newline)"

  defp composer_placeholder(_solo, {_handle, label}),
    do: "Ask #{label}…  (Enter to send · Shift+Enter for newline)"

  defp composer_placeholder(false, nil),
    do: "Talk to the group  (Enter to send · Shift+Enter for newline)"

  defp composer_placeholder(_solo, nil),
    do: "Say something…  (Enter to send · Shift+Enter for newline)"

  # The route a second device reads an attachment's bytes from.
  defp attachment_path(athanor_route, message_id, filename) do
    PrismWeb.Focus.path(
      athanor_route,
      "/attachments/#{URI.encode(message_id, &URI.char_unreserved?/1)}/#{URI.encode(filename, &URI.char_unreserved?/1)}"
    )
  end

  defp chat_path(socket, nil), do: PrismWeb.Focus.path(socket.assigns.athanor_route, "")

  defp chat_path(socket, id),
    do: PrismWeb.Focus.path(socket.assigns.athanor_route, "?c=" <> URI.encode_www_form(id))

  # Navigate intents are page paths (`/activities`); the athanor in focus is
  # added here, so the agent never addresses another athanor's pages.
  defp push_intents(socket, []), do: socket

  defp push_intents(socket, intents) do
    mode = socket.assigns[:ui_mode]

    intents = Enum.filter(intents, &mode_permits?(&1, mode))

    route = socket.assigns.athanor_route

    intents =
      Enum.map(intents, fn
        %{kind: "navigate", to: to} = intent -> %{intent | to: PrismWeb.Focus.path(route, to)}
        intent -> intent
      end)

    push_event(socket, "aqua:intents", %{intents: intents})
  end

  # A navigate to a page the current mode's nav does not show is dropped —
  # `PrismWeb.Nav` is the one owner of what a mode surfaces, and an
  # agent's intent gets no wider view than the person's own chrome.
  defp mode_permits?(%{kind: "navigate", to: to}, mode) do
    base = to |> String.split("?", parts: 2) |> hd()

    Enum.any?(PrismWeb.Nav.items(mode), fn %{path: path} ->
      (path == "" and base == "") or
        (path != "" and (base == path or String.starts_with?(base, path <> "/")))
    end)
  end

  defp mode_permits?(_intent, _mode), do: true

  # ---------------------------------------------------------------------------
  # Models (async, best-effort)
  # ---------------------------------------------------------------------------

  defp load_models(socket) do
    case PrismWeb.ModelCatalog.load(socket.assigns.context) do
      :ok -> socket
      :unavailable -> assign(socket, :models_loaded, true)
    end
  end

  defp member_labels(ctx) do
    case Sanctum.Tenancy.Members.list_by_athanor(ctx.athanor_id) do
      {:ok, rows} ->
        Enum.reduce(rows, %{}, fn m, acc ->
          case m.user_id do
            nil -> acc
            id -> Map.put(acc, id, m.display_name || m.email || id)
          end
        end)

      {:error, _} ->
        %{}
    end
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
        <%!-- Two lists, not one dimmed pile: what you follow, then the
              estate's other topics folded under a heading. Access is
              unchanged either way — every row opens on a click. --%>
        <% {following, other} = Enum.split_with(@conversations, &followed?(@followed, &1)) %>
        <div class="flex-1 overflow-y-auto">
          <ul :if={following != []} class="divide-y divide-gray-800/60">
            <.topic_row :for={conv <- following} conv={conv} current={@conversation} followed />
          </ul>
          <details :if={other != []} open={following == []} class="border-t border-gray-800">
            <summary class="px-3 py-1.5 text-[10px] uppercase tracking-wider text-gray-600 cursor-pointer hover:text-gray-400">
              Other topics ({length(other)})
            </summary>
            <ul class="divide-y divide-gray-800/60">
              <.topic_row
                :for={conv <- other}
                conv={conv}
                current={@conversation}
                followed={false}
              />
            </ul>
          </details>
        </div>
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
            <span
              :if={@athanor && @athanor.roster == "frozen"}
              class="shrink-0 rounded bg-gray-800 px-1.5 py-0.5 text-[10px] text-gray-400"
              title="A DM — a frozen two-person estate; it ends when either of you leaves"
            >
              DM
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
                value={"#{o["owner"]}/#{o["name"]}"}
                selected={same_entry?(current_orchestrator(@orchestrator, @orchestrators), o)}
              >
                {option_label(o)}
              </option>
            </select>
            <span :if={@orchestrators == []} class="text-xs text-amber-400">
              No orchestrator configured
            </span>
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
            :if={not @any_messages and @streaming_text == ""}
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
              <span>
                Ask {agent_label(current_orchestrator(@orchestrator, @orchestrators))} anything.
              </span>
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

          <% pending = @pending_approvals %>
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

          <div id="conversation-messages" phx-update="stream" class="space-y-3">
            <%= for {dom_id, msg} <- @streams.messages do %>
              <div id={dom_id}>
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
                  <div class="group/aloud">
                    <.message_bubble
                      id={"msg-" <> msg.id}
                      role={role_of(msg)}
                      content={msg.content}
                      author={author_label(msg, @members, @context)}
                      attachments={Conversations.payload(msg)["attachments"] || []}
                      attachment_href={&attachment_path(@athanor_route, msg.id, &1)}
                    />
                    <%!-- Your own line: the one deliberate copy. The verb
                          allows any two estates you belong to — a DM line
                          said into the team room as much as a private note —
                          so the button is offered wherever the domain would
                          accept it (author-only, membership both sides). --%>
                    <div
                      :if={msg.kind == "text" && msg.author == @context.user_id}
                      class="flex justify-end"
                    >
                      <button
                        type="button"
                        phx-click="aloud_open"
                        phx-value-id={msg.id}
                        class="opacity-0 group-hover/aloud:opacity-100 text-[10px] text-gray-500 hover:text-gray-300 px-1"
                      >
                        Say aloud…
                      </button>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

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
                composer_placeholder(
                  @solo_human,
                  orchestrator_handle(
                    current_orchestrator(@orchestrator, @orchestrators),
                    @athanor
                  )
                )
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

      <%!-- Say-aloud picker: which estate, then which of its topics. --%>
      <div
        :if={@aloud_for}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/70"
        phx-click="aloud_cancel"
      >
        <div
          class="w-full max-w-sm rounded-lg bg-gray-900 border border-gray-800 shadow-2xl p-4 space-y-3"
          phx-click-away="aloud_cancel"
        >
          <h3 class="text-sm font-medium text-gray-200">Say aloud</h3>
          <p class="text-[11px] text-gray-500">
            A copy of your line lands on an estate's thread, attributed to you.
            This conversation keeps the original.
          </p>

          <div :if={@aloud_targets == []} class="text-xs text-gray-500">
            You are not in any other estate yet — there is no room to say it in.
          </div>

          <div :if={@aloud_targets != []} class="space-y-1">
            <p class="text-[10px] uppercase tracking-wider text-gray-500">Estate</p>
            <button
              :for={t <- @aloud_targets}
              type="button"
              phx-click="aloud_pick_estate"
              phx-value-athanor={t[:id]}
              class={[
                "block w-full text-left rounded px-2 py-1 text-xs",
                if(@aloud_estate == t[:id],
                  do: "bg-gray-800 text-white",
                  else: "text-gray-300 hover:bg-gray-800/60"
                )
              ]}
            >
              {t[:name]}
              <span :if={t[:roster] == "frozen"} class="text-[10px] text-gray-500 ml-1">DM</span>
            </button>
          </div>

          <div :if={@aloud_estate} class="space-y-1">
            <p class="text-[10px] uppercase tracking-wider text-gray-500">Topic</p>
            <div :if={@aloud_topics == []} class="text-xs text-gray-500">
              That estate has no topics yet.
            </div>
            <button
              :for={topic <- @aloud_topics}
              type="button"
              phx-click="aloud_post"
              phx-value-conversation={topic.id}
              class="block w-full text-left rounded px-2 py-1 text-xs text-gray-300 hover:bg-gray-800/60"
            >
              {topic.title}
            </button>
          </div>

          <div class="flex justify-end">
            <button
              type="button"
              phx-click="aloud_cancel"
              class="rounded px-3 py-1 text-xs text-gray-400 hover:bg-gray-800"
            >
              Cancel
            </button>
          </div>
        </div>
      </div>
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
    display = assigns.content |> Aqua.Actions.strip_blocks() |> String.trim()
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
              :if={@attachment_href && a["stored_name"]}
              href={@attachment_href.(a["stored_name"])}
              download={a["filename"]}
              class="inline-flex items-center rounded bg-black/20 px-1.5 py-0.5 text-[10px] hover:bg-black/40 underline-offset-2 hover:underline"
            >
              📎 {a["filename"]}
            </a>
            <span
              :if={!(@attachment_href && a["stored_name"])}
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
