# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ConversationPaneLive do
  @moduledoc """
  One conversation on screen: the tape, the composer, the approval cards,
  the consent sheet and the uploads — a window onto `Aqua.ConversationRunner`
  for one thread, under one focused context.

  Each nested LiveView has its own mailbox, authenticated session context,
  and membership-checked athanor focus. Runner calls, row reads, and
  attachment writes use that context, independently of the host’s focus.

  One pane per estate (`id: "pane-<athanor id>"`): the host names the
  thread at mount and turns the pane to another with `{:switch_thread,
  id | nil}` — the estate's reads (the row, the roster, the members, the
  models) are made once, the thread's (its rows, the runner's live state,
  the subscription) on every turn. What the host must know travels back
  as `{:pane, id, message}` to `socket.parent_pid`, first of all
  `{:ready, pid, conversation_id}` once the pane is live, which is how
  the host learns where to send the switch.

  In the person's own panel (`PrismWeb.AquaPanelLive`, session `"panel"`)
  the pane sits beside a room: it hears what the host page shows
  (`PrismWeb.RoomFeed`), reads that room into each send as the turn's
  context (`Aqua.RoomExcerpt` — under the person's own membership, never
  kept), and offers to paste a line onto it (`conversation.aloud`).
  """

  use PrismWeb, :live_view

  require Logger

  alias Arca.ConversationStorage, as: Conversations
  alias Aqua.ConversationRunner
  alias Phoenix.LiveView.JS
  alias Sanctum.Tenancy.Users

  @agent_author Arca.Schemas.Message.agent_author()
  @system_author Arca.Schemas.Message.system_author()

  # How many pages the assistant may leave pointed at in the panel at once.
  @max_links 5

  @impl true
  def mount(_params, session, socket) do
    token = session[to_string(PrismWeb.SignInResponse.session_key())]
    # Every DOM id here carries the pane's own: a page may hold two panes.
    socket = assign(socket, :dom, socket.id)

    case PrismWeb.AuthHelpers.authenticate_session(token, session["athanor_id"]) do
      {:ok, ctx} ->
        socket = socket |> assign(:context, ctx) |> beside(session) |> open(ctx, session)

        if connected?(socket) do
          conversation = socket.assigns.conversation
          tell_host(socket, {:ready, self(), conversation && conversation.id})
        end

        {:ok, socket, layout: false}

      {:error, _} ->
        {:ok, assign(socket, :context, nil), layout: false}
    end
  end

  # A pane in the person's own panel sits beside a room: it hears what the
  # host page shows and reads it into each send.
  defp beside(socket, session) do
    room_feed = session["room_feed"]

    if connected?(socket) and is_binary(room_feed), do: PrismWeb.RoomFeed.subscribe(room_feed)

    socket
    |> assign(:panel?, session["panel"] == true)
    |> assign(:room, session["room"])
    |> assign(:read_room?, true)
  end

  # Everything the pane knows of its estate, from its own context: the
  # athanor row, the roster (the estate's soul and roles), the members and
  # the models — read once, however many threads the pane is turned to.
  # The thread named at mount is opened last, the way any thread is.
  defp open(socket, ctx, session) do
    dom = socket.assigns.dom

    # Subscribe BEFORE reading the row: the fill may finish between the two,
    # and a page that read "not yet" without listening would sit on it until
    # someone reloaded.
    if connected?(socket), do: subscribe_estate(ctx)

    athanor =
      case Sanctum.Tenancy.Athanors.get(ctx.athanor_id) do
        {:ok, athanor} -> athanor
        _ -> nil
      end

    # The tree reads through the seed overlay from the first moment, so the
    # roster is real before anything is filled. What is not ready is the
    # consent a turn pins, which is why sending is held rather than reading.
    preparing? = preparing?(athanor)
    roster = if connected?(socket), do: Aqua.Turn.roster(ctx), else: []

    socket =
      socket
      |> assign(:athanor, athanor)
      |> assign(:athanor_route, PrismWeb.Focus.route_of(ctx))
      |> assign(:ui_mode, Prism.Labels.mode(session["ui_mode"], ctx))
      |> assign(:conversation, nil)
      |> assign(:members, member_labels(ctx))
      |> assign(:roster, roster)
      |> assign(:preparing?, preparing?)
      |> assign(:model_ready, model_ready(ctx, roster))
      |> assign(:solo_human, Sanctum.Tenancy.Members.solo?(ctx.athanor_id))
      |> assign(:own?, Users.own_athanor?(ctx.user_id, ctx.athanor_id))
      |> assign(:links, [])
      |> assign(:model_override, nil)
      |> assign(:models_by_provider, %{})
      |> assign(:models_loaded, false)
      |> stream_configure(:messages, dom_id: &(dom <> "-m-" <> &1.id))
      |> stream(:messages, [])
      |> allow_upload(:attachments,
        accept: :any,
        max_entries: Aqua.Attachments.limits().max_files,
        # 20 MB — sized with EmissaryWeb.Endpoint's Plug.Parsers :length so a
        # base64-encoded attachment of this size fits through POST /mcp.
        max_file_size: Aqua.Attachments.limits().max_file_bytes,
        auto_upload: true
      )

    socket = if connected?(socket), do: load_models(socket), else: socket

    open_thread(socket, conversation_of(ctx, session["conversation_id"]))
  end

  # The estate's own topic. `Sanctum.Provisioning` broadcasts
  # `:athanor_changed` when a fill completes, which is what clears the
  # preparing state without a reload.
  defp subscribe_estate(%Sanctum.Context{athanor_id: id}) when is_binary(id) and id != "",
    do: Phoenix.PubSub.subscribe(Emissary.PubSub, Cyfr.Topics.notify(id))

  defp subscribe_estate(_ctx), do: :ok

  defp preparing?(%{provisioned_at: nil}), do: true
  defp preparing?(_athanor), do: false

  # The thread a host names, under the pane's own context — so a thread
  # another estate holds is nothing here — or the blank slate, where the
  # first message creates the row.
  defp conversation_of(ctx, id) when is_binary(id) and id != "" do
    case Conversations.get(ctx, id) do
      {:ok, conv} -> conv
      _ -> nil
    end
  end

  defp conversation_of(_ctx, _none), do: nil

  # Everything the pane knows of one thread — its rows, the runner's live
  # state and the subscription that keeps them current — replacing what it
  # knew of the last: the tape, the cards, the draft and the turn's state
  # are the thread's, never carried over.
  defp open_thread(socket, conversation) do
    socket =
      socket
      |> unsubscribe_thread()
      |> assign(:conversation, conversation)
      |> assign(:assistant, nil)
      |> assign(:input, "")
      |> stream(:messages, [], reset: true)
      |> assign(:pending_approvals, [])
      |> assign(:any_messages, false)
      |> reset_live()

    case {connected?(socket), conversation} do
      {true, %{} = conv} ->
        ConversationRunner.subscribe(conv.id, conv.athanor_id)
        live = ConversationRunner.state(conv.id, conv.athanor_id)

        # Newest window only: unbounded, this read loaded every row of a
        # long-lived conversation into every viewer's socket. The runner's
        # own turn assembly stays windowed separately.
        rows =
          case Conversations.latest_messages(socket.assigns.context, conv.id, 500) do
            rows when is_list(rows) -> rows
            {:error, _} -> []
          end

        socket
        |> stream(:messages, rows, reset: true)
        |> assign(:pending_approvals, pending_in(rows))
        |> assign(:any_messages, rows != [])
        |> apply_live(live)

      _ ->
        socket
    end
  end

  defp unsubscribe_thread(%{assigns: %{conversation: %{id: id, athanor_id: athanor_id}}} = socket) do
    ConversationRunner.unsubscribe(id, athanor_id)
    socket
  end

  defp unsubscribe_thread(socket), do: socket

  defp reset_live(socket) do
    socket
    |> assign(:running, false)
    |> assign(:queued, 0)
    |> assign(:turn_user, nil)
    |> assign(:streaming_text, "")
    |> assign(:tool_activity, [])
    |> assign(:token_usage, %{input: 0, output: 0})
    |> assign(:grants, MapSet.new())
    |> assign(:announcement, "")
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
    |> assign(:solo_human, Map.get(live, :solo_human, socket.assigns.solo_human))
    |> assign(:assistant, live.orchestrator || socket.assigns.assistant)
  end

  defp apply_live(socket, _), do: socket

  # Every member by name, once at mount, the one way a person is named on
  # the console (`PrismWeb.People.label/2`) — the viewer as "You".
  defp member_labels(ctx) do
    case Sanctum.Tenancy.Members.list_by_athanor(ctx.athanor_id) do
      {:ok, rows} ->
        for m <- rows, is_binary(m.user_id), into: %{} do
          {m.user_id, PrismWeb.People.label(m, ctx)}
        end

      {:error, _} ->
        %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Models (async, best-effort)
  # ---------------------------------------------------------------------------

  defp load_models(socket) do
    case PrismWeb.ModelCatalog.load(socket.assigns.context) do
      :ok -> socket
      :unavailable -> assign(socket, :models_loaded, true)
    end
  end

  # ============================================================================
  # Events from this pane's own markup
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
         run(
           socket,
           &PrismWeb.Ops.call_tool(&1, "conversation/stop", %{"conversation" => conv.id}),
           cancel_requested: true
         )}
    end
  end

  def handle_event("select_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, :model_override, if(model == "", do: nil, else: model))}
  end

  def handle_event(
        "revoke_grant",
        %{"agent" => agent, "tool" => tool, "action" => action},
        socket
      ) do
    case socket.assigns.conversation do
      nil ->
        {:noreply, socket}

      conv ->
        {:noreply,
         run(
           socket,
           &PrismWeb.Ops.call_tool(&1, "conversation/revoke_grant", %{
             "conversation" => conv.id,
             "agent_name" => agent,
             "tool" => tool,
             "tool_action" => action
           })
         )}
    end
  end

  def handle_event("approve_all_pending", _params, socket) do
    socket =
      Enum.reduce(socket.assigns.pending_approvals, socket, fn msg, acc ->
        decide(acc, {:approval_approve, msg.id, :once})
      end)

    {:noreply, socket}
  end

  def handle_event("decline_all_pending", _params, socket) do
    socket =
      Enum.reduce(socket.assigns.pending_approvals, socket, fn msg, acc ->
        decide(acc, {:approval_decline, msg.id, "", :once})
      end)

    {:noreply, socket}
  end

  # Saying a line aloud is the host's picker; the pane names the line.
  def handle_event("aloud_open", %{"id" => msg_id}, socket) do
    tell_host(socket, {:aloud_open, msg_id})
    {:noreply, socket}
  end

  # The list beside the thread is the host's drawer on a phone.
  def handle_event("toggle_rail", _params, socket) do
    tell_host(socket, :toggle_rail)
    {:noreply, socket}
  end

  # Beside a room: whether each send reads it.
  def handle_event("toggle_read_room", _params, socket) do
    {:noreply, assign(socket, :read_room?, not socket.assigns.read_room?)}
  end

  # A line from this thread onto the room beside it — the same
  # `conversation.aloud` verb as the picker, its target already known.
  # `Aqua.Aloud` decides what may be said and attributes the copy.
  def handle_event("paste", %{"id" => msg_id}, socket) do
    case {socket.assigns.room, socket.assigns.conversation} do
      {%{} = room, %{} = conv} ->
        result =
          call_tool(socket.assigns.context, "conversation/aloud", %{
            "conversation" => conv.id,
            "message_ids" => [msg_id],
            "target_athanor" => room["athanor_id"],
            "target_conversation" => room["conversation_id"]
          })

        case result do
          {:ok, _} ->
            {:noreply,
             put_flash(
               socket,
               :info,
               "Pasted onto #{PrismWeb.RoomFeed.label(room)} — attributed to you."
             )}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not paste: #{error_message(reason)}")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # A page the assistant pointed at from the panel, taken or left.
  def handle_event("dismiss_link", %{"to" => to}, socket) do
    {:noreply, assign(socket, :links, List.delete(socket.assigns.links, to))}
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  # ============================================================================
  # The pane's mailbox: runner broadcasts, card decisions, the consent sheet
  # ============================================================================

  @impl true
  def handle_info({:conversation, id, event}, %{assigns: %{conversation: %{id: id}}} = socket) do
    {:noreply, handle_conversation_event(socket, event)}
  end

  def handle_info({:conversation, _other, _event}, socket), do: {:noreply, socket}

  # Approval cards dispatch the decision to their LiveView — this one; a
  # refusal reaches the person who clicked.
  def handle_info({:approval_approve, _id, _scope} = decision, socket) do
    {:noreply, decide(socket, decision)}
  end

  def handle_info({:approval_decline, _id, _reason, _scope} = decision, socket) do
    {:noreply, decide(socket, decision)}
  end

  # The consent sheet closes itself once the grant lands; the running turn
  # is cut for the delta and the sender re-sends.
  def handle_info({:consent_granted, _ref, result}, socket) do
    socket = assign(socket, :consent_sheet_ref, nil)

    case socket.assigns.conversation do
      nil ->
        {:noreply, socket}

      conv ->
        {:noreply,
         run(
           socket,
           &PrismWeb.Ops.call_tool(&1, "conversation/restart_for_consent", %{
             "conversation" => conv.id,
             "profile_id" => Map.get(result, :profile_id),
             "revision" => Map.get(result, :revision)
           })
         )}
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

  # The host turned this pane to another thread — or to the blank slate.
  # The thread it is already on is left alone: a host that patched its
  # address to the thread this pane just created must not reset the tape.
  def handle_info({:switch_thread, id}, socket) do
    current = socket.assigns.conversation && socket.assigns.conversation.id

    if id == current,
      do: {:noreply, socket},
      else: {:noreply, open_thread(socket, conversation_of(socket.assigns.context, id))}
  end

  # The host page opened another thread: the room this pane reads changed.
  def handle_info({:room_in_view, room}, socket), do: {:noreply, assign(socket, :room, room)}

  # The estate's row changed. When it was the fill completing, the reads
  # skipped at mount are made now and the pane stops saying "preparing".
  def handle_info({:notify, _athanor_id, :athanor_changed, _payload}, socket) do
    ctx = socket.assigns.context

    case Sanctum.Tenancy.Athanors.get(ctx.athanor_id) do
      {:ok, athanor} ->
        socket = assign(socket, :athanor, athanor)

        if socket.assigns.preparing? and not preparing?(athanor) do
          roster = Aqua.Turn.roster(ctx)

          {:noreply,
           socket
           |> assign(:preparing?, false)
           |> assign(:roster, roster)
           |> assign(:model_ready, model_ready(ctx, roster))
           |> load_models()}
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(msg, socket) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  # A refusal reaches the person who clicked — log-only made the button
  # appear to do nothing.
  defp decide(socket, {:approval_approve, id, scope}) do
    case socket.assigns.conversation do
      %{id: conv_id} ->
        case PrismWeb.Ops.call_tool(socket, "conversation/approve", %{
               "conversation" => conv_id,
               "message_id" => id,
               "scope" => Aqua.ApprovalScope.to_string(scope)
             }) do
          {:ok, _} ->
            socket

          {:error, :already_resolved} ->
            socket

          {:error, reason} ->
            Logger.warning("[ConversationPane] approve failed: #{inspect(reason)}")
            put_flash(socket, :error, "Approve failed: #{error_message(reason)}")
        end

      _ ->
        socket
    end
  end

  defp decide(socket, {:approval_decline, id, reason, scope}) do
    case socket.assigns.conversation do
      %{id: conv_id} ->
        case PrismWeb.Ops.call_tool(socket, "conversation/decline", %{
               "conversation" => conv_id,
               "message_id" => id,
               "reason" => reason,
               "scope" => Aqua.ApprovalScope.to_string(scope)
             }) do
          {:ok, _} ->
            socket

          {:error, :already_resolved} ->
            socket

          {:error, why} ->
            Logger.warning("[ConversationPane] decline failed: #{inspect(why)}")
            put_flash(socket, :error, "Decline failed: #{error_message(why)}")
        end

      _ ->
        socket
    end
  end

  # ---------------------------------------------------------------------------
  # Runner events
  # ---------------------------------------------------------------------------

  defp handle_conversation_event(socket, {:message, row}), do: upsert_message(socket, row)
  defp handle_conversation_event(socket, {:message_updated, row}), do: upsert_message(socket, row)

  # A turn may start for a message queued earlier — the sender's draft of
  # a newer message stays where it is (`send_message/3` clears on send).
  defp handle_conversation_event(socket, {:turn_starting, user_id}) do
    socket = assign(socket, :announcement, "AQUA is thinking.")

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
    socket = assign(socket, :announcement, "AQUA replied.")

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
    pending = Enum.reject(socket.assigns.pending_approvals, &(&1.id == row.id))

    pending =
      if row.kind == "approval" and row.status == "pending",
        do: pending ++ [row],
        else: pending

    socket
    |> stream_insert(:messages, row)
    |> assign(:pending_approvals, pending)
    |> assign(:any_messages, true)
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

    with {:ok, conv, created?} <- current_or_new(socket),
         {room, socket} = room_context(socket, conv),
         {:ok, refs} <- Aqua.Attachments.store(ctx, conv.id, message_id, files),
         :ok <- send_or_discard(ctx, conv, message, message_id, refs, room, socket) do
      # A conversation this send created is this pane's now, and the host's
      # to address — the URL is the host's, the pane only asked for a row.
      if created?, do: tell_host(socket, {:opened, conv})
      socket = if created?, do: open_thread(socket, conv), else: socket
      {:noreply, assign(socket, :input, "")}
    else
      {:error, :busy} ->
        {:noreply,
         put_flash(socket, :error, "Too many turns are already waiting — let one finish first.")}

      {:error, :not_member} ->
        {:noreply, put_flash(socket, :error, "You are no longer a member here.")}

      {:error, :archived} ->
        {:noreply, put_flash(socket, :error, "This estate has been archived.")}

      {:error, :no_orchestrator} ->
        {:noreply, put_flash(socket, :error, "This estate has no assistant — see AQUA.")}

      {:error, :storage_full} ->
        {:noreply, put_flash(socket, :error, "This estate's storage is full.")}

      {:error, :storage_unverifiable} ->
        {:noreply,
         put_flash(socket, :error, "Storage usage can't be verified right now — try again.")}

      {:error, :message_too_long} ->
        {:noreply,
         put_flash(socket, :error, "That message is too long — up to 32 KiB of text per line.")}

      {:error, :context_too_long} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "What the room shows is too long to read into one message — untick reading it and send again."
         )}

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
  defp send_or_discard(ctx, conv, message, message_id, refs, room, socket) do
    args =
      %{
        "conversation" => conv.id,
        "message" => message,
        "id" => message_id,
        "attachments" => refs,
        "model" => socket.assigns.model_override,
        "agent" => socket.assigns.assistant && socket.assigns.assistant["name"]
      }
      |> Map.merge(Map.new(room, fn {k, v} -> {Atom.to_string(k), v} end))
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    case PrismWeb.Ops.call_tool(ctx, "conversation/send", args) do
      {:ok, _} ->
        :ok

      {:error, _reason} = error ->
        Aqua.Attachments.discard(ctx, conv.id, message_id, refs)
        error
    end
  end

  # The room beside this pane, named for this send — the panel alone, and
  # not a thread reading itself. The room's lines are read server-side,
  # for this one turn.
  defp room_context(
         %{assigns: %{panel?: true, read_room?: true, room: %{} = room}} = socket,
         conv
       ) do
    if reads_room?(room, conv), do: {[room: room], socket}, else: {[], socket}
  end

  defp room_context(socket, _conv), do: {[], socket}

  # Beside a room, and not the room itself: a thread never reads itself,
  # and nothing is pasted onto where it already is.
  defp reads_room?(%{"conversation_id" => room_id}, conversation) do
    is_nil(conversation) or conversation.id != room_id
  end

  defp reads_room?(_room, _conversation), do: false

  defp current_or_new(%{assigns: %{conversation: %{} = conv}}), do: {:ok, conv, false}

  defp current_or_new(socket) do
    with {:ok, %{id: id}} <- PrismWeb.Ops.call_tool(socket, "conversation/create", %{}),
         {:ok, conv} <- Conversations.get(socket.assigns.context, id) do
      {:ok, conv, true}
    end
  end

  # A conversation verb for the current member, through the tool surface;
  # `assigns` are applied when it answers.
  defp run(socket, fun, assigns \\ []) do
    case fun.(socket.assigns.context) do
      {:ok, _} -> assign(socket, assigns)
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
      Logger.warning("[ConversationPane] consume uploads failed: #{Exception.message(e)}")
      {:error, :attachments_unreadable}
  end

  defp pending_in(messages) do
    Enum.filter(messages, &(&1.kind == "approval" and &1.status == "pending"))
  end

  # A pane mounted on its own (a test's isolated mount) has no host to tell.
  defp tell_host(%{parent_pid: pid} = socket, message) when is_pid(pid),
    do: send(pid, {:pane, socket.id, message})

  defp tell_host(_socket, _message), do: :ok

  # Whether this athanor's AQUA can answer at all: a soul, and a model
  # with a key behind it. A fresh furnace has neither, and the chat is
  # where someone finds that out — not the drawer.
  defp model_ready(ctx, roster) do
    case Aqua.AgentConfig.model_status(ctx, roster) do
      empty when map_size(empty) == 0 -> :no_model
      statuses -> if Enum.any?(statuses, &match?({_, {:ready, _}}, &1)), do: :ready, else: :no_key
    end
  end

  # What to call the athanor in its own chat: the person's own is "your
  # AQUA" — theirs, not any person-kind athanor an operator opened — a DM
  # or a group goes by its label.
  defp athanor_label(%{} = athanor, ctx) do
    if PrismWeb.Estates.own?(athanor, ctx),
      do: "your AQUA",
      else: PrismWeb.Estates.label(athanor, ctx)
  end

  defp athanor_label(_none, _ctx), do: "this estate"

  # What a message would address, and what to call it: the soul or role
  # the thread is on, or the roster's first — the estate's soul — before
  # any turn has run.
  defp assistant_handle(%{"name" => name} = o, _athanor) when is_binary(name) and name != "",
    do: {name, o["title"] || name}

  # No roster entry at all: teach nothing rather than a handle that does
  # not resolve — the "no assistant" note in the header is the honest
  # sentence.
  defp assistant_handle(_, _athanor), do: nil

  defp current_assistant(nil, roster), do: List.first(roster)
  defp current_assistant(%{} = assistant, _roster), do: assistant

  defp assistant_label(%{} = o), do: o["title"] || o["name"]
  defp assistant_label(_), do: "your AQUA"

  # Whether a mention is needed is derived from how many people are here,
  # so the placeholder asks the same question the runner does rather than
  # reading a setting.
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

  # Navigate intents are page paths (`/activities`); the athanor this pane
  # is on is added here, so the assistant never addresses another athanor's
  # pages. A global page (the chat) is its own address.
  #
  # The push names this pane: the client hands a pushed event to every
  # pane on the page, and each acts only on `%{pane: <its section id>}`.
  # In the panel a navigate never moves the page the person is reading —
  # a chat path onto a thread of You turns the panel to that thread, and
  # any other page is offered as a link line, theirs to take or leave.
  defp push_intents(socket, []), do: socket

  defp push_intents(socket, intents) do
    mode = socket.assigns[:ui_mode]
    route = socket.assigns.athanor_route

    intents =
      intents
      |> Enum.filter(&mode_permits?(&1, mode))
      |> Enum.map(fn
        # One decision for "global page or under the estate": `Nav.href/2`.
        %{kind: "navigate", to: to} = intent -> %{intent | to: PrismWeb.Nav.href(to, route)}
        intent -> intent
      end)
      |> Enum.filter(&served?/1)

    {socket, intents} =
      if socket.assigns.panel?, do: keep_navigates(socket, intents), else: {socket, intents}

    if intents == [],
      do: socket,
      else: push_event(socket, "aqua:intents", %{pane: pane_id(socket), intents: intents})
  end

  defp keep_navigates(socket, intents) do
    {navigates, rest} = Enum.split_with(intents, &(&1.kind == "navigate"))

    socket =
      Enum.reduce(navigates, socket, fn %{to: to}, socket ->
        case own_thread(to, socket.assigns.athanor_route) do
          {:ok, conversation_id} ->
            tell_host(socket, {:open_thread, conversation_id})
            socket

          :elsewhere ->
            assign(socket, :links, Enum.take(Enum.uniq([to | socket.assigns.links]), @max_links))
        end
      end)

    {socket, rest}
  end

  # A chat path onto one thread of the athanor this pane is on —
  # `/chat?a=<route>&c=<id>`, as `PrismWeb.ChatLive.chat_path/2` spells it.
  # The estate alone, with no `c`, names no thread the panel could turn
  # to: that is a page, and offered as a link like any other.
  defp own_thread(to, route) do
    uri = URI.parse(to)
    params = URI.decode_query(uri.query || "")

    case params["c"] do
      id when is_binary(id) and id != "" ->
        if uri.path == PrismWeb.ChatLive.chat_path(nil) and params["a"] == route,
          do: {:ok, id},
          else: :elsewhere

      _ ->
        :elsewhere
    end
  end

  defp pane_id(socket), do: socket.assigns.dom <> "-pane"

  # A navigate lands on a page the console serves or nowhere: the link,
  # focused on this pane's estate, must resolve in the router, and a
  # redirect stub is not a page. The engine checks a path's shape alone;
  # this is where it is mapped to a route.
  defp served?(%{kind: "navigate", to: href}) do
    if PrismWeb.Nav.page?(href) do
      true
    else
      Logger.warning("[ConversationPane] navigate dropped: #{inspect(href)} is not a page")
      false
    end
  end

  defp served?(_intent), do: true

  # A navigate to a page the current mode's nav does not show is dropped —
  # `PrismWeb.Nav` is the one owner of what a mode surfaces, and an
  # the assistant's intent gets no wider view than the person's own chrome.
  defp mode_permits?(%{kind: "navigate", to: to}, mode) do
    base = to |> String.split("?", parts: 2) |> hd()

    Enum.any?(PrismWeb.Nav.items(mode), fn %{path: path} ->
      base == path or String.starts_with?(base, path <> "/")
    end)
  end

  defp mode_permits?(_intent, _mode), do: true

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(%{context: nil} = assigns) do
    ~H"""
    <section
      id={@dom <> "-pane"}
      class="flex flex-1 min-w-0 flex-col items-center justify-center p-4 text-sm text-gray-500"
    >
      <p>Signed out — reload to continue.</p>
    </section>
    """
  end

  def render(assigns) do
    ~H"""
    <%!-- Focusable so a click anywhere in the pane makes it the one ⌘. halts. --%>
    <section
      id={@dom <> "-pane"}
      phx-hook="Conversation"
      tabindex="-1"
      class="flex flex-1 min-w-0 flex-col focus:outline-none"
    >
      <header class="flex items-center justify-between gap-2 border-b border-gray-800 px-4 py-2">
        <div class="flex items-center gap-2 min-w-0">
          <%!-- The phone drawer is the host's: this only asks for it. --%>
          <button
            :if={not @panel?}
            type="button"
            phx-click="toggle_rail"
            class="md:hidden rounded px-1.5 py-1 text-[11px] uppercase tracking-wider text-gray-400 hover:bg-gray-800 hover:text-gray-200"
            title="Chats"
          >
            Chats
          </button>
          <span class="text-sm font-medium text-gray-200 shrink-0">AQUA</span>
          <%!-- Which furnace this chat is: a key bound here is bound here.
                The panel's header already says You. --%>
          <span :if={not @panel?} class="text-xs text-gray-500 shrink-0 truncate max-w-[10rem]">
            in {athanor_label(@athanor, @context)}
          </span>
          <span
            :if={@athanor && @athanor.roster == "frozen"}
            class="shrink-0 rounded bg-gray-800 px-1.5 py-0.5 text-[10px] text-gray-400"
            title="A DM — a frozen two-person estate; it ends when either of you leaves"
          >
            DM
          </span>
          <span
            :if={@roster != []}
            class="text-xs text-gray-400 max-w-[14rem] truncate"
            title="The soul or role this thread is on"
          >
            {assistant_label(current_assistant(@assistant, @roster))}
          </span>
          <span :if={@preparing?} class="text-xs text-amber-400">
            Still being prepared
          </span>
          <span :if={@roster == [] and not @preparing?} class="text-xs text-amber-400">
            No assistant here
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
            aria-label="Override model"
          >
            <option value="" selected={is_nil(@model_override)}>
              {(@assistant && @assistant["model"]) || "default"}
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
          <%!-- The workbench is the page's; from the panel it would leave the room. --%>
          <.link
            :if={not @panel?}
            navigate={PrismWeb.Focus.path(@athanor_route, "/aqua")}
            class="rounded px-2 py-1 text-[11px] uppercase tracking-wider text-gray-500 hover:bg-gray-800 hover:text-gray-300"
          >
            AQUA
          </.link>
        </div>
      </header>

      <%!-- The pane's own flash: a nested view's shows nowhere else. --%>
      <div
        :for={
          {kind, style} <- [
            {:error, "border-red-900/60 bg-red-950/40 text-red-200"},
            {:info, "border-emerald-900/60 bg-emerald-950/40 text-emerald-200"}
          ]
        }
        :if={Phoenix.Flash.get(@flash, kind)}
        id={"#{@dom}-flash-#{kind}"}
        role="alert"
        phx-click={JS.push("lv:clear-flash", value: %{key: kind})}
        title="Dismiss"
        class={["cursor-pointer border-b px-4 py-1.5 text-xs", style]}
      >
        {Phoenix.Flash.get(@flash, kind)}
      </div>

      <%!-- What a screen reader hears: a coherent update — AQUA started, AQUA
            replied — never the stream, which would announce every word. --%>
      <div id={@dom <> "-announcer"} class="sr-only" aria-live="polite" aria-atomic="true">
        {@announcement}
      </div>
      <div
        id={@dom <> "-thread"}
        phx-hook="ScrollBottom"
        class="flex-1 overflow-y-auto px-4 py-3 space-y-3"
      >
        <div
          :if={not @any_messages and @streaming_text == ""}
          class="flex flex-col items-center justify-center h-full gap-2 text-sm text-gray-500"
        >
          <%= if @preparing? do %>
            <span>{athanor_label(@athanor, @context)} is still being prepared.</span>
            <span class="text-gray-600">Its agents and components are being installed.</span>
          <% else %>
            <%= if @model_ready in [:no_model, :no_key] do %>
              <span>{athanor_label(@athanor, @context)} has no model yet.</span>
              <%!-- From the panel a navigate would leave the room being read. --%>
              <.link
                :if={not @panel?}
                navigate={PrismWeb.Focus.path(@athanor_route, "/aqua")}
                class="text-blue-400 hover:text-blue-300"
              >
                Connect a model
              </.link>
              <span :if={@panel?} class="text-gray-500">Connect one on your AQUA page.</span>
            <% else %>
              <span>
                Ask {assistant_label(current_assistant(@assistant, @roster))} anything.
              </span>
            <% end %>
          <% end %>
        </div>

        <div
          :if={MapSet.size(@grants) > 0}
          class="flex flex-wrap items-center gap-1.5 text-[10px] text-gray-500"
        >
          <span>auto-approving this chat:</span>
          <span
            :for={{agent, tool, action} <- Enum.sort(@grants)}
            class="inline-flex items-center gap-1 rounded bg-gray-800 px-1.5 py-0.5 text-gray-300 font-mono"
            title={"answered for #{agent}"}
          >
            <span class="text-gray-500">{agent}:</span>{tool}.{action}
            <button
              type="button"
              phx-click="revoke_grant"
              phx-value-agent={agent}
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

        <%!-- A log to assistive tech, but not a live region: the announcer
              above speaks the coherent updates, not every streamed delta. --%>
        <div
          id={@dom <> "-messages"}
          phx-update="stream"
          role="log"
          aria-live="off"
          class="space-y-3"
        >
          <%= for {dom_id, msg} <- @streams.messages do %>
            <div id={dom_id}>
              <%= if msg.kind == "approval" do %>
                <% intent = Conversations.payload(msg)["intent"] || %{} %>
                <% resolution = Conversations.resolution(msg) %>
                <.live_component
                  module={PrismWeb.AquaApprovalCard}
                  id={@dom <> "-card-" <> msg.id}
                  message_id={msg.id}
                  payload={intent}
                  status={msg.status}
                  decided_at={msg.resolved_at}
                  reason={resolution["reason"]}
                  result_summary={resolution["summary"]}
                  scope={scope_atom(resolution["scope"])}
                  resolved_by={msg.resolved_by && label_for(@members, msg.resolved_by, @context)}
                  agent_label={@assistant && @assistant["title"]}
                  shared_with={@athanor.kind == "group" && @athanor.name}
                />
              <% else %>
                <div class="group/aloud">
                  <.message_bubble
                    id={@dom <> "-msg-" <> msg.id}
                    role={role_of(msg)}
                    content={msg.content}
                    author={author_label(msg, @members, @context)}
                    attachments={Conversations.payload(msg)["attachments"] || []}
                    attachment_href={&attachment_path(@athanor_route, msg.id, &1)}
                  />
                  <%!-- A line you may say aloud: yours, or your assistant's
                        in your own athanor. The host owns the picker — in
                        the panel the target is the room beside it. --%>
                  <div :if={sayable?(msg, @context, @own?)} class="flex justify-end">
                    <button
                      :if={not @panel?}
                      type="button"
                      phx-click="aloud_open"
                      phx-value-id={msg.id}
                      class={aloud_button_class()}
                    >
                      Say aloud…
                    </button>
                    <button
                      :if={@panel? and reads_room?(@room, @conversation)}
                      type="button"
                      phx-click="paste"
                      phx-value-id={msg.id}
                      class={aloud_button_class()}
                    >
                      Paste to {PrismWeb.RoomFeed.label(@room)}
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
          id={@dom <> "-streaming"}
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

      <div
        :if={@links != []}
        id={@dom <> "-links"}
        class="flex flex-col gap-1 border-t border-gray-800 px-3 py-1.5 text-[11px] text-gray-500"
      >
        <div :for={to <- @links} class="flex min-w-0 items-center gap-2">
          <span class="shrink-0">AQUA points to</span>
          <.link navigate={to} class="truncate text-blue-400 hover:text-blue-300">{to}</.link>
          <button
            type="button"
            phx-click="dismiss_link"
            phx-value-to={to}
            aria-label="Dismiss"
            class="ml-auto shrink-0 px-1 text-gray-500 hover:text-gray-200"
          >
            ×
          </button>
        </div>
      </div>

      <label
        :if={@panel? and reads_room?(@room, @conversation)}
        id={@dom <> "-read-room"}
        title="Each message you send here carries what the room shows — read for you, never kept"
        class="flex cursor-pointer items-center gap-2 border-t border-gray-800 px-3 py-1 text-[11px] text-gray-500"
      >
        <input
          type="checkbox"
          phx-click="toggle_read_room"
          checked={@read_room?}
          class="h-3 w-3 rounded border-gray-700 bg-gray-900"
        />
        <span class="truncate">Read {PrismWeb.RoomFeed.label(@room)} with each message</span>
      </label>

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
            id={@dom <> "-textarea"}
            phx-hook="AquaChat"
            name="message"
            phx-change="update_input"
            rows="1"
            placeholder={
              composer_placeholder(
                @solo_human,
                assistant_handle(current_assistant(@assistant, @roster), @athanor)
              )
            }
            class="flex-1 resize-none rounded-md border border-gray-700 bg-gray-950 px-3 py-1.5 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:outline-none max-h-40 overflow-y-auto"
            disabled={@roster == [] or @preparing?}
          >{@input}</textarea>
          <button
            type="submit"
            disabled={
              @roster == [] or @preparing? or
                (@input == "" and @uploads.attachments.entries == [])
            }
            class="self-end rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-500 disabled:opacity-40 disabled:cursor-not-allowed"
          >
            Send
          </button>
          <button
            :if={@running}
            type="button"
            phx-click="stop"
            title="Stop the running turn"
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
    display = assigns.content |> Aqua.Wire.strip_blocks() |> String.trim()
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

  # A line the person may say aloud: their own, or their assistant's in
  # their own athanor — the same rule `Aqua.Aloud` enforces, shown here so
  # the button is offered only where the verb would accept it. Whether this
  # is the person's own athanor is read once at mount (`:own?`).
  defp sayable?(%{kind: "text", author: author}, %{user_id: author}, _own?), do: true
  defp sayable?(%{kind: "text", author: @agent_author}, _ctx, own?), do: own?
  defp sayable?(_msg, _ctx, _own?), do: false

  # Hidden until the line is hovered or reached by keyboard; there is no
  # hover to reach it by on a narrow screen, so there it always shows.
  defp aloud_button_class do
    "opacity-0 group-hover/aloud:opacity-100 group-focus-within/aloud:opacity-100 " <>
      "focus-visible:opacity-100 max-md:opacity-100 text-[10px] text-gray-500 hover:text-gray-300 px-1"
  end

  defp role_of(%{kind: "error"}), do: "error"
  defp role_of(%{kind: "system"}), do: "system"
  defp role_of(%{author: @agent_author}), do: "assistant"
  defp role_of(_), do: "user"

  defp author_label(%{author: @agent_author}, _members, _ctx), do: nil
  defp author_label(%{author: @system_author}, _members, _ctx), do: nil
  defp author_label(%{kind: kind}, _members, _ctx) when kind in ["error", "system"], do: nil

  # A copy of an assistant's line is the person's, and says so.
  defp author_label(%{author: author} = msg, members, ctx) do
    label = label_for(members, author, ctx)

    if Conversations.payload(msg)["shared_agent"] == true,
      do: "shared from AQUA by #{label}",
      else: label
  end

  # A member from the labels read at mount; anyone since gone (or an
  # operator reading a room they hold no seat in) by the same rule.
  defp label_for(members, user_id, ctx) when is_binary(user_id) do
    Map.get(members, user_id) || PrismWeb.People.label(user_id, ctx)
  end

  defp label_for(_members, _user_id, _ctx), do: nil

  defp scope_atom(scope), do: Aqua.ApprovalScope.parse(scope)

  defp role_align("user"), do: "items-end"
  defp role_align(_), do: "items-start"

  defp role_class("user"), do: "bg-indigo-600 text-white"
  defp role_class("error"), do: "bg-red-900/40 text-red-300 border border-red-800"
  defp role_class("system"), do: "bg-gray-800/60 text-gray-400 border border-gray-800 italic"
  defp role_class(_), do: "bg-gray-800 text-gray-200"
end
