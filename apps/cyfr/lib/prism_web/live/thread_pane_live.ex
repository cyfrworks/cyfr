# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ThreadPaneLive do
  @moduledoc """
  One thread of the person's own Aqua on screen: the tape, the composer
  and the uploads — a window onto `Aqua.Runner` for one thread, under one
  focused context. Its host is Aqua's panel (`PrismWeb.AquaPanelLive`),
  which mounts one pane (`id: "aqua-panel-pane"`) focused on the person's
  own athanor.

  The pane is a nested LiveView with its own mailbox, authenticated
  session context and owner-checked athanor focus. Runner calls, row
  reads and attachment writes use that context, independently of the
  host's.

  The host names the thread at mount and turns the pane to another with
  `{:switch_thread, id | nil}` — the athanor's reads (the row, the
  roster, the members, the models) are made once, the thread's (its
  rows, the runner's live state, the subscription) on every turn. What
  the host must know travels back as `{:pane, id, message}` to
  `socket.parent_pid`, first of all `{:ready, pid, thread_id}` once the
  pane is live, which is how the host learns where to send the switch.

  A send from a daily thread, of today or an earlier day, or from a pane
  on no thread names no thread and joins today's daily thread
  (`thread.send`); its files are written under today's first
  (`thread.today`). When the thread it joined is not the one shown, the
  pane turns to it and asks its host to show it, `{:open_thread, id}`.
  While the pane shows a thread the person has seen it: the read mark
  moves to the newest row when the thread opens and as each row lands
  (`Aqua.mark_read/3`, forward only).

  A turn that needs a grant asks for it as a `:grant` prompt read under
  the pane's own context and sent to the view that renders the pane,
  never past it: `{:grant, pid, prompt}`. That view places it in its own
  system layer, under its own context in the same athanor, and hands the
  outcome back as `{:system_layer, id, outcome}`
  (`PrismWeb.SystemLayer.relay/4`). Granted, the running turn is cut for
  the new consent and the sender re-sends. A grant asked for an account a
  launch named (`account` on the turn's `:consent_required`) opens on that
  account, on the launched app's own profile; the turn that asked has
  already ended, so once it is granted nothing is cut, and the pane
  offers to send that turn's own message (`message_id` on the event,
  read by its id from this thread) again, as a new turn, or says that
  the turn ended when it has no such message to offer.

  Every line is named by who sent it (`sent_by`): a person as the console
  names them, the soul as Aqua, a crew member by its name. A schedule's
  fire is written in the server's voice and drawn as that schedule's,
  under its name, never as the person's line. A request to a crew member
  says who asked whom and whether it is answered, with the replies to it
  beneath it; a reply whose request is not on screen stands on its own.
  A room lists its crew members' threads; a member's thread names its
  member, leads back to its room and, while it stands, can be archived
  (`thread.archive`). The pane opens neither: it asks its host to open
  the thread, `{:open_thread, id}`.

  The pane sits beside the shared thread the chat overlay shows, when it
  shows one (`PrismWeb.RoomFeed`, the session's `room_feed` and `room`):
  ticked, its box reads that thread into each send as the turn's context
  (`Aqua.RoomExcerpt` — under the person's own seat, never kept); it
  starts unticked, since Aqua reads a shared thread itself when a
  question needs it (`threads.read`). It offers to paste a line onto the
  thread (`thread.aloud`). Until the person dismisses it, a line says
  that what Aqua reads in a shared thread, other people's words
  included, goes to their model provider; dismissing it writes
  `users.prefs`' `aqua_reads_threads_seen`, so it is said once.

  A workspace thread's pointer and each of its reports on a daily thread
  is a card: the post as it was written (a report's summary with its
  pictures, files and links), the workspace thread's state as it is now
  (`Aqua.workspace/2`, worded by `PrismWeb.DisplayHelpers.work_state/1`,
  never the outcome the report was written with), and Open, which asks
  the host to open that thread, `{:open_thread, id}`. The state is read
  again when the person's list announces the thread (`Cyfr.Bus.ThreadListed`,
  on their `Cyfr.Bus.threads/2` topic); a thread the list says left takes
  its cards with it. A thread that cannot be found any more has no Open.

  What the thread made is told to the host as it is read, for a host that
  shows it beside the thread's posts (`PrismWeb.WorkspaceLive`): Aqua's
  posts that hold a picture, a file or a link, `{:results, thread_id,
  results, window}` when a thread opens and `{:result, thread_id, result}`
  as each one lands, each `%{id, seq, content, attachments, links}` from
  the rows the pane reads under its own context. The pane reads a thread's
  newest posts only, `@window` of them, and has no way to earlier ones:
  `window` is that number when the read filled it, so earlier posts and
  what they hold may exist and are shown nowhere here, and nil when the
  pane holds the whole thread.

  What a turn asks of the browser is its sender's alone: a page the
  assistant points at is offered as a link under the thread
  (`<dom>-links`), never followed, so the page the person is reading
  stays; every other intent is pushed as `aqua:intents` naming this pane.

  The panel's own header names Aqua and the thread, so the pane draws no
  name or thread label of its own, and its model override, soul or crew
  member and token counts sit in a menu (`<dom>-menu`, which the panel's
  header opens). Its status line appears only while it has something to
  say (still being prepared, no assistant, messages queued, a turn being
  asked).
  """

  use PrismWeb, :live_view

  require Logger

  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.{ThreadEvent, ThreadListed}
  alias Phoenix.LiveView.JS
  alias Sanctum.Tenancy.Users

  @agent_author Prima.Author.agent()
  @system_author Prima.Author.system()
  # The `sent_by` of a person's line; any other names an agent.
  @person "person"

  # How many pages the assistant may leave pointed at in the panel at once.
  @max_links 5

  # The thread events that carry a row the pane draws, each with its files
  # as they stand when it arrives (`files_kept/2`).
  @row_events [:message, :request, :reply]

  # How many of a thread's newest rows the pane reads when it opens one.
  @window 500

  # The threads that hold crew threads.
  @rooms Threads.room_kinds()

  # The session, focused on the athanor the host names (`"athanor_id"`), is
  # established and kept current by the guard; a refused one never mounts.
  on_mount {CyfrWeb.ContextGuard, :protected}

  @impl true
  def mount(_params, session, socket) do
    ctx = socket.assigns.context
    # Every DOM id here carries the pane's own.
    socket = socket |> assign(:dom, socket.id) |> beside(session) |> open(ctx, session)

    if connected?(socket) do
      thread = socket.assigns.thread
      tell_host(socket, {:ready, self(), thread && thread.id})
    end

    {:ok, socket, layout: false}
  end

  # The pane sits beside the shared thread the chat overlay shows: it hears
  # which on the desktop's feed, and reads it into a send only when the
  # person ticks the box.
  defp beside(socket, session) do
    room_feed = session["room_feed"]

    if connected?(socket) and is_binary(room_feed), do: PrismWeb.RoomFeed.subscribe(room_feed)

    socket
    |> assign(:room, session["room"])
    |> assign(:read_room?, false)
    |> assign(:reads_notice?, not reads_notice_seen?(socket.assigns.context))
  end

  @reads_notice_seen "aqua_reads_threads_seen"

  # A person whose row cannot be read is told again rather than never.
  defp reads_notice_seen?(%{user_id: user_id}) when is_binary(user_id) do
    case Users.get(user_id) do
      {:ok, user} -> Users.prefs(user)[@reads_notice_seen] == true
      _unread -> false
    end
  end

  defp reads_notice_seen?(_ctx), do: false

  defp keep_reads_notice_seen(%{user_id: user_id}) when is_binary(user_id) do
    with {:ok, user} <- Users.get(user_id),
         {:ok, _user} <- Users.put_prefs(user, %{@reads_notice_seen => true}) do
      :ok
    else
      {:error, _unkept} -> Logger.warning("[ThreadPaneLive] the reads notice was not kept")
    end
  end

  defp keep_reads_notice_seen(_ctx), do: :ok

  # Everything the pane knows of its athanor, from its own context: the
  # athanor row, the roster (the athanor's soul and crew), the members and
  # the models — read once, however many threads the pane is turned to.
  # The thread named at mount is opened last, the way any thread is.
  defp open(socket, ctx, session) do
    dom = socket.assigns.dom

    # Subscribe BEFORE reading the row: the fill may finish between the two,
    # and a page that read "not yet" without listening would sit on it until
    # someone reloaded.
    if connected?(socket), do: subscribe_athanor(ctx)

    athanor =
      case Sanctum.Tenancy.Athanors.get(ctx.athanor_id) do
        {:ok, athanor} -> athanor
        _ -> nil
      end

    # The tree reads through the seed overlay from the first moment, so the
    # roster is real before anything is filled. What is not ready is the
    # consent a turn pins, which is why sending is held rather than reading.
    preparing? = preparing?(athanor)
    roster = if connected?(socket), do: Aqua.roster(ctx), else: []

    socket =
      socket
      |> assign(:athanor, athanor)
      |> assign(:athanor_route, PrismWeb.Focus.route_of(ctx))
      |> assign(:ui_mode, Prism.Labels.mode(session["ui_mode"], ctx))
      |> assign(:thread, nil)
      |> assign(:members, member_labels(ctx))
      |> assign(:roster, roster)
      |> assign(:preparing?, preparing?)
      # Before the socket connects the model's status is not read, and is
      # pending: no status is made up from agents never asked for.
      |> assign(
        :model_ready,
        if(connected?(socket), do: model_ready(ctx, agents(ctx)), else: :pending)
      )
      |> assign(:own?, Users.own_athanor?(ctx.user_id, ctx.athanor_id))
      |> assign(:links, [])
      |> assign(:held_send, nil)
      |> assign(:model_override, nil)
      |> assign(:models_by_provider, %{})
      |> assign(:models_loaded, false)
      |> stream_configure(:messages, dom_id: &(dom <> "-m-" <> &1.id))
      |> stream(:messages, [])
      |> allow_upload(:attachments,
        accept: :any,
        max_entries: Aqua.attachment_limits().max_files,
        # 20 MB — sized with CyfrWeb.Endpoint's Plug.Parsers :length so a
        # base64-encoded attachment of this size fits through POST /mcp.
        max_file_size: Aqua.attachment_limits().max_file_bytes,
        auto_upload: true
      )

    socket = if connected?(socket), do: load_models(socket), else: socket

    open_thread(socket, thread_of(ctx, session["thread_id"]))
  end

  # The athanor's own topic. `Sanctum.Provisioning` broadcasts
  # `:athanor_changed` when a fill completes, which is what clears the
  # preparing state without a reload. And the person's list of threads,
  # which says when a workspace thread a card names moved or left.
  defp subscribe_athanor(%Sanctum.Context{athanor_id: id} = ctx)
       when is_binary(id) and id != "" do
    actor = Sanctum.Context.actor(ctx)
    Cyfr.Bus.subscribe(actor, Cyfr.Bus.notify(actor))

    if is_binary(ctx.user_id),
      do: Cyfr.Bus.subscribe(actor, Cyfr.Bus.threads(actor, ctx.user_id))
  end

  defp subscribe_athanor(_ctx), do: :ok

  defp preparing?(%{provisioned_at: nil}), do: true
  defp preparing?(_athanor), do: false

  # The thread a host names, under the pane's own context — so a thread
  # another athanor holds is nothing here — or the blank slate, where the
  # first message creates the row.
  defp thread_of(ctx, id) when is_binary(id) and id != "" do
    case Threads.get(Sanctum.Context.actor(ctx), id) do
      {:ok, thread} -> thread
      _ -> nil
    end
  end

  defp thread_of(_ctx, _none), do: nil

  # A daily or a workspace thread: one the person archives.
  defp room?(%{kind: kind}), do: kind in ["daily", "workspace"]
  defp room?(_none), do: false

  # Everything the pane knows of one thread — its rows, the runner's live
  # state and the subscription that keeps them current — replacing what it
  # knew of the last: the tape, the cards, the draft and the turn's state
  # are the thread's, never carried over.
  defp open_thread(socket, thread) do
    socket =
      socket
      |> unsubscribe_thread()
      |> assign(:thread, thread)
      |> assign(:assistant, nil)
      |> assign(:input, "")
      |> stream(:messages, [], reset: true)
      |> assign(:requests, %{})
      |> assign(:children, [])
      |> assign(:parent, nil)
      |> assign(:seen, thread && thread.read_seq)
      |> assign(:any_messages, false)
      |> assign(:cards, %{})
      |> assign(:works, %{})
      |> reset_live()

    case {connected?(socket), thread} do
      {true, %{} = thread} ->
        follow_thread(thread.id, thread.athanor_id)
        live = Aqua.thread_state(thread.id, thread.athanor_id)

        # Newest window only: unbounded, this read loaded every row of a
        # long-lived thread into every viewer's socket. The runner's
        # own turn assembly stays windowed separately.
        ctx = socket.assigns.context

        rows =
          case Threads.latest_messages(Sanctum.Context.actor(ctx), thread.id, @window) do
            rows when is_list(rows) -> Enum.map(rows, &files_kept(&1, ctx))
            {:error, _} -> []
          end

        {shown, requests} = file_replies(rows)

        tell_host(
          socket,
          {:results, thread.id, rows |> Enum.map(&result/1) |> Enum.reject(&is_nil/1),
           if(length(rows) >= @window, do: @window)}
        )

        socket
        |> hold_cards(rows)
        |> stream(:messages, shown, reset: true)
        |> assign(:requests, requests)
        |> assign(:any_messages, rows != [])
        |> apply_live(live)
        |> relatives(thread)
        |> seen(rows |> Enum.map(& &1.seq) |> Enum.max(fn -> nil end))

      _ ->
        socket
    end
  end

  # A request is shown with the replies to it beneath it, and kept by id
  # so a reply heard later files under it too; a reply whose request is
  # not among the rows shown stands on its own.
  defp file_replies(rows) do
    asked = for row <- rows, crew(row) == :request, into: MapSet.new(), do: row.id

    {nested, shown} =
      Enum.split_with(rows, &(crew(&1) == :reply and MapSet.member?(asked, &1.reply_to)))

    replies = Enum.group_by(nested, & &1.reply_to)

    shown =
      Enum.map(shown, fn row ->
        if crew(row) == :request,
          do: Map.put(row, :replies, Map.get(replies, row.id, [])),
          else: row
      end)

    {shown, for(row <- shown, crew(row) == :request, into: %{}, do: {row.id, row})}
  end

  # A workspace thread's pointer and reports on this thread, kept by id so
  # a move of that thread draws them again, and each workspace thread they
  # name as it is now.
  defp hold_cards(socket, rows), do: Enum.reduce(rows, socket, &hold_card(&2, &1))

  defp hold_card(socket, %{kind: kind, workspace_id: id} = row)
       when kind in ["pointer", "report"] and is_binary(id) do
    socket = assign(socket, :cards, Map.put(socket.assigns.cards, row.id, row))
    if Map.has_key?(socket.assigns.works, id), do: socket, else: read_work(socket, id)
  end

  defp hold_card(socket, _row), do: socket

  # The workspace thread as it is now, under the pane's own context: one
  # that cannot be found is gone, and one that cannot be read right now
  # keeps what was held.
  defp read_work(socket, id) do
    work =
      case Aqua.workspace(socket.assigns.context, id) do
        {:ok, record} -> record
        {:error, :not_found} -> :gone
        {:error, _unread} -> Map.get(socket.assigns.works, id, :gone)
      end

    assign(socket, :works, Map.put(socket.assigns.works, id, work))
  end

  # Each workspace thread `ids` names read again, and its cards drawn again
  # with it (the stream draws a row once, so each is put back).
  defp reread_works(socket, ids) do
    ids = Enum.filter(ids, &Map.has_key?(socket.assigns.works, &1))
    socket = Enum.reduce(ids, socket, &read_work(&2, &1))

    socket.assigns.cards
    |> Map.values()
    |> Enum.filter(&(&1.workspace_id in ids))
    |> Enum.reduce(socket, &stream_insert(&2, :messages, &1))
  end

  # A workspace thread that left the list takes its cards with it: its
  # pointer and reports were deleted with it.
  defp drop_work(socket, id) do
    {gone, kept} =
      Enum.split_with(socket.assigns.cards, fn {_id, row} -> row.workspace_id == id end)

    gone
    |> Enum.reduce(socket, fn {_id, row}, socket -> stream_delete(socket, :messages, row) end)
    |> assign(:cards, Map.new(kept))
    |> assign(:works, Map.delete(socket.assigns.works, id))
  end

  # A post's files as the pane draws them, each one whose bytes the person
  # deleted from Files marked removed (`Aqua.attachments_as_kept/2`), read
  # when the thread opens and when a row arrives. A post already drawn
  # changes at the next read.
  defp files_kept(row, ctx) do
    case Aqua.attachment_refs(row) do
      [] -> row
      _refs -> Map.put(row, :attachments, Aqua.attachments_as_kept(ctx, row))
    end
  end

  # A row's files: those `files_kept/2` read, else the stored refs.
  defp attachments(row),
    do: Map.get(row, :attachments) || Threads.payload(row)["attachments"] || []

  # What the thread made: a post of Aqua's that holds a picture, a file or
  # a link, as a host draws it; nil for any other row.
  defp result(%{author: @agent_author} = row) do
    payload = Threads.payload(row)
    attachments = attachments(row)
    links = payload["links"] || []

    if attachments != [] or links != [],
      do: %{
        id: row.id,
        seq: row.seq,
        content: row.content,
        attachments: attachments,
        links: links
      }
  end

  defp result(_row), do: nil

  # A room's crew threads, or a crew thread's room.
  defp relatives(socket, %{kind: "crew", parent_id: room_id}),
    do: assign(socket, :parent, thread_of(socket.assigns.context, room_id))

  defp relatives(socket, _room), do: read_children(socket)

  # Read again on each crew row the room hears: a request or a reply names
  # a thread the room may not have listed yet.
  defp read_children(%{assigns: %{thread: %{kind: kind, id: id}}} = socket)
       when kind in @rooms do
    case Threads.children(Sanctum.Context.actor(socket.assigns.context), id) do
      children when is_list(children) -> assign(socket, :children, children)
      {:error, _} -> socket
    end
  end

  defp read_children(socket), do: socket

  # The person has seen the rows the pane shows: the thread's read mark
  # moves to `seq`, forward only, and a row at or behind the mark it holds
  # moves nothing.
  defp seen(%{assigns: %{thread: %{id: id}, seen: mark}} = socket, seq)
       when is_integer(seq) and (is_nil(mark) or seq > mark) do
    _ = Aqua.mark_read(socket.assigns.context, id, seq)
    assign(socket, :seen, seq)
  end

  defp seen(socket, _seq), do: socket

  defp unsubscribe_thread(%{assigns: %{thread: %{id: id, athanor_id: athanor_id}}} = socket) do
    unfollow_thread(id, athanor_id)
    socket
  end

  defp unsubscribe_thread(socket), do: socket

  # A thread's broadcasts: the bus topic its athanor's actor names.
  defp follow_thread(thread_id, athanor_id) do
    actor = Prima.Actor.in_athanor(athanor_id)
    Cyfr.Bus.subscribe(actor, Cyfr.Bus.thread(actor, thread_id))
  end

  defp unfollow_thread(thread_id, athanor_id) do
    actor = Prima.Actor.in_athanor(athanor_id)
    Cyfr.Bus.unsubscribe(actor, Cyfr.Bus.thread(actor, thread_id))
  end

  defp reset_live(socket) do
    socket
    |> assign(:running, false)
    |> assign(:paused, false)
    |> assign(:paused_reason, nil)
    |> assign(:queued, 0)
    |> assign(:turn_user, nil)
    |> assign(:live_turn_id, nil)
    |> assign(:partials, Aqua.stream_new())
    |> assign(:tool_activity, [])
    |> assign(:token_usage, %{input: 0, output: 0})
    |> assign(:announcement, "")
    # Whether the running turn wrote a reply: its end is announced as one
    # only then.
    |> assign(:turn_replied, false)
    |> assign(:grant_prompt, nil)
    |> assign(:grant_retry, nil)
    |> assign(:restart_prompt, nil)
    |> assign(:restart_note, nil)
    |> assign(:cancel_requested, false)
  end

  defp apply_live(socket, %{} = live) do
    socket
    |> assign(:running, live.running)
    |> assign(:paused, Map.get(live, :paused, false))
    |> assign(:paused_reason, Map.get(live, :paused_reason))
    |> assign(:queued, Map.get(live, :queued, 0))
    |> assign(:turn_user, live.turn_user)
    |> assign(:live_turn_id, if(live.running, do: live.turn_id))
    |> assign(:partials, live.partials)
    |> assign(:tool_activity, live.tool_activity)
    |> assign(:token_usage, live.usage)
    |> assign(:assistant, live.agent || socket.assigns.assistant)
  end

  defp apply_live(socket, _), do: socket

  # The athanor's person by name, once at mount, the one way a person is
  # named on the console (`PrismWeb.People.label/2`) — the viewer as "You".
  defp member_labels(%{user_id: user_id} = ctx) when is_binary(user_id),
    do: %{user_id => PrismWeb.People.label(%{user_id: user_id}, ctx)}

  defp member_labels(_ctx), do: %{}

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

  def handle_event("retry_send", _params, %{assigns: %{held_send: %{} = held}} = socket),
    do: deliver(socket, held)

  def handle_event("retry_send", _params, socket), do: {:noreply, socket}

  def handle_event("discard_send", _params, %{assigns: %{held_send: %{} = held}} = socket) do
    {:noreply, socket |> discard_stored(held) |> assign(:held_send, nil) |> mirror(nil)}
  end

  def handle_event("discard_send", _params, socket), do: {:noreply, socket}

  # The held send the browser kept across a reload, offered back by the
  # pane's hook. It is trusted no further than a send over the wire: the
  # shape is checked and the thread must be this member's to read.
  def handle_event("restore_draft", params, socket) do
    case restored(socket, params) do
      {:ok, envelope} -> deliver(socket, envelope)
      :error -> {:noreply, mirror(socket, nil)}
    end
  end

  def handle_event("stop", _params, socket) do
    case socket.assigns.thread do
      nil ->
        {:noreply, socket}

      thread ->
        {:noreply,
         run(
           socket,
           &PrismWeb.Ops.call_tool(&1, "thread/stop", %{"thread" => thread.id}),
           cancel_requested: true
         )}
    end
  end

  def handle_event("select_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, :model_override, if(model == "", do: nil, else: model))}
  end

  # A crew thread, or its room: the host opens it, as it opens any thread.
  def handle_event("open_thread", %{"id" => id}, socket) do
    tell_host(socket, {:open_thread, id})
    {:noreply, socket}
  end

  # Archiving a daily or a workspace thread puts it behind the list's
  # Archived filter and changes nothing else; on a crew thread it retires
  # it, which stops its member's work there. The row read again says
  # whether it took.
  def handle_event("archive", _params, %{assigns: %{thread: %{id: id} = thread}} = socket) do
    socket = run(socket, &PrismWeb.Ops.call_tool(&1, "thread/archive", %{"thread" => id}))
    {:noreply, assign(socket, :thread, thread_of(socket.assigns.context, id) || thread)}
  end

  def handle_event("archive", _params, socket), do: {:noreply, socket}

  # Beside a shared thread: whether each send reads it.
  def handle_event("toggle_read_room", _params, socket) do
    {:noreply, assign(socket, :read_room?, not socket.assigns.read_room?)}
  end

  # Said once: the person's own row keeps that they have read it. A write
  # that fails leaves it to be said again at the next mount.
  def handle_event("dismiss_reads_notice", _params, socket) do
    keep_reads_notice_seen(socket.assigns.context)
    {:noreply, assign(socket, :reads_notice?, false)}
  end

  # A line from this thread onto the shared thread beside it, through
  # `thread.aloud`. `Aqua.Aloud` decides what may be said and attributes
  # the copy.
  def handle_event("paste", %{"id" => msg_id}, socket) do
    case {socket.assigns.room, socket.assigns.thread} do
      {%{} = room, %{} = thread} ->
        result =
          call_tool(socket.assigns.context, "thread/aloud", %{
            "thread" => thread.id,
            "message_ids" => [msg_id],
            "target_thread" => room["shared_thread_id"]
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

  # A page the assistant pointed at, taken or left.
  def handle_event("dismiss_link", %{"to" => to}, socket) do
    {:noreply, assign(socket, :links, List.delete(socket.assigns.links, to))}
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  # ============================================================================
  # The pane's mailbox: runner broadcasts, the grant's outcome
  # ============================================================================

  @impl true
  def handle_info(
        %ThreadEvent{thread_id: id, kind: kind, data: data},
        %{assigns: %{thread: %{id: id}}} = socket
      ) do
    data = if kind in @row_events, do: files_kept(data, socket.assigns.context), else: data
    {:noreply, socket |> handle_thread_event(kind, data) |> seen(landed(kind, data))}
  end

  def handle_info(%ThreadEvent{}, socket), do: {:noreply, socket}

  # The thread shown, archived or taken out of the archive by new work as
  # the person's list announces it: read again.
  def handle_info(
        %ThreadListed{kind: kind, id: id, archived: archived},
        %{assigns: %{thread: %{id: id, archived_at: at} = thread}} = socket
      )
      when kind in [:daily, :workspace] and archived != not is_nil(at) do
    socket = assign(socket, :thread, thread_of(socket.assigns.context, id) || thread)
    if kind == :workspace, do: {:noreply, reread_works(socket, [id])}, else: {:noreply, socket}
  end

  # A workspace thread a card names, as the person's list announces it:
  # moved, read again; gone, its cards with it.
  def handle_info(%ThreadListed{kind: :workspace, id: id}, socket),
    do: {:noreply, reread_works(socket, [id])}

  def handle_info(%ThreadListed{kind: :removed, id: id}, socket) do
    if Map.has_key?(socket.assigns.works, id),
      do: {:noreply, drop_work(socket, id)},
      else: {:noreply, socket}
  end

  def handle_info(%ThreadListed{}, socket), do: {:noreply, socket}

  # The grant this pane asked for, as the host's layer reported it.
  # Granted, the running turn is cut for the new consent and the sender
  # re-sends; granted for a launch's account, whose turn already ended,
  # nothing is cut and the pane offers that turn's message again as a new
  # turn; a refused commit leaves the prompt open; anything else ended it.
  def handle_info({:system_layer, id, outcome}, %{assigns: %{grant_prompt: id}} = socket)
      when is_binary(id) do
    case outcome do
      :confirmed ->
        {:noreply, socket |> assign(:grant_prompt, nil) |> after_grant()}

      {:refused, reason} when reason != :invalid_prompt ->
        {:noreply, socket}

      _ended ->
        {:noreply, socket |> assign(:grant_prompt, nil) |> assign(:grant_retry, nil)}
    end
  end

  def handle_info({:system_layer, _id, _outcome}, socket), do: {:noreply, socket}

  # The catalogue, for the focus it was read under.
  def handle_info({:list_models_result, tag, result}, socket),
    do: CyfrWeb.ContextGuard.deliver(socket, tag, &models_loaded(&1, result))

  def handle_info({:task_timeout, :models}, socket) do
    {:noreply, assign(socket, :models_loaded, true)}
  end

  # The host turned this pane to another thread — or to the blank slate.
  # The thread it is already on is left alone: a host that patched its
  # address to the thread this pane just created must not reset the tape.
  def handle_info({:switch_thread, id}, socket) do
    current = socket.assigns.thread && socket.assigns.thread.id

    if id == current,
      do: {:noreply, socket},
      else: {:noreply, open_thread(socket, thread_of(socket.assigns.context, id))}
  end

  # A desktop asked about something it shows: Prism's sentence goes after
  # the person's draft, which it never replaces, and nothing is sent.
  # LiveView leaves a focused textarea's value alone, and the composer takes
  # focus as the panel opens, so the value is also pushed to the composer's
  # hook, which sets it; the assign stays what a send carries.
  def handle_info({:aqua_ask, sentence}, socket) when is_binary(sentence) do
    draft = String.trim_trailing(socket.assigns.input)
    input = if draft == "", do: sentence, else: draft <> "\n\n" <> sentence

    {:noreply,
     socket
     |> assign(:input, input)
     |> push_event("aqua:composer", %{pane: pane_id(socket), value: input})}
  end

  # The chat overlay opened another shared thread, or none: the thread this
  # pane reads changed.
  def handle_info(%Cyfr.Bus.RoomInView{room: room}, socket),
    do: {:noreply, assign(socket, :room, room)}

  # The athanor's row changed. When it was the fill completing, the reads
  # skipped at mount are made now and the pane stops saying "preparing".
  def handle_info(%Cyfr.Bus.Notify{kind: :athanor_changed}, socket) do
    ctx = socket.assigns.context

    case Sanctum.Tenancy.Athanors.get(ctx.athanor_id) do
      {:ok, athanor} ->
        socket = assign(socket, :athanor, athanor)

        if socket.assigns.preparing? and not preparing?(athanor) do
          roster = Aqua.roster(ctx)

          socket =
            socket
            |> assign(:preparing?, false)
            |> assign(:roster, roster)
            |> assign(:model_ready, model_ready(ctx, agents(ctx)))
            |> load_models()

          # The send held for the fill goes now, once; a refusal holds it
          # again for the person's own retry.
          case socket.assigns.held_send do
            %{} = held -> deliver(socket, held)
            nil -> {:noreply, socket}
          end
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  defp models_loaded(socket, {:ok, result}) do
    %{models: models} = PrismWeb.ModelCatalog.parse(result)

    {:noreply,
     socket
     |> assign(:models_by_provider, models)
     |> assign(:models_loaded, true)}
  end

  defp models_loaded(socket, {:error, _}), do: {:noreply, assign(socket, :models_loaded, true)}

  # ---------------------------------------------------------------------------
  # Runner events
  # ---------------------------------------------------------------------------

  # A step's text row replaces the answer that streamed for it.
  # A row a turn writes for itself lands as the thread reads it on open:
  # as its steps, never as a post.
  defp handle_thread_event(socket, :message, row) do
    if result = result(row), do: tell_host(socket, {:result, row.thread_id, result})

    socket
    |> hold_card(row)
    |> then(&if(drawn?(row), do: upsert_message(&1, row), else: &1))
    |> assign(:partials, Aqua.stream_landed(socket.assigns.partials, row))
    |> assign(:turn_replied, socket.assigns.turn_replied or replied?(row, socket))
  end

  defp handle_thread_event(socket, :request, row) do
    replies = get_in(socket.assigns.requests, [row.id, :replies]) || []
    socket |> put_request(Map.put(row, :replies, replies)) |> read_children()
  end

  # A reply answers every request its payload names, as its write did, and
  # is shown beneath the one it replies to when that one is shown.
  defp handle_thread_event(socket, :reply, row) do
    requests = socket.assigns.requests
    answered = Enum.uniq([row.reply_to | List.wrap(Threads.payload(row)["answers"])])

    socket =
      for id <- answered, %{} = request <- [requests[id]], reduce: socket do
        acc -> put_request(acc, answered_by(request, row))
      end

    socket =
      if Map.has_key?(requests, row.reply_to), do: socket, else: upsert_message(socket, row)

    read_children(socket)
  end

  # A turn may start for a message queued earlier — the sender's draft of
  # a newer message stays where it is (`send_message/3` clears on send).
  defp handle_thread_event(socket, :turn_starting, user_id) do
    socket = assign(socket, :announcement, "Aqua is thinking.")

    socket
    |> assign(:turn_replied, false)
    |> assign(:running, true)
    |> assign(:paused, false)
    |> assign(:paused_reason, nil)
    |> assign(:turn_user, user_id)
    |> assign(:partials, Aqua.stream_new())
    |> assign(:tool_activity, [])
    |> assign(:token_usage, %{input: 0, output: 0})
  end

  defp handle_thread_event(socket, :queued, n), do: assign(socket, :queued, n)

  defp handle_thread_event(socket, :turn_started, turn_id) do
    socket
    |> assign(:running, true)
    |> assign(:paused, false)
    |> assign(:paused_reason, nil)
    |> assign(:live_turn_id, turn_id)
  end

  # The turn stopped on a launch or on a call whose outcome is unknown;
  # the sender it waits on stays named.
  defp handle_thread_event(socket, :turn_paused, %{reason: reason}) do
    socket =
      if reason == :uncertain,
        do: assign(socket, :announcement, "Aqua stopped: a tool's outcome is unknown."),
        else: socket

    socket
    |> assign(:running, false)
    |> assign(:paused, true)
    |> assign(:paused_reason, reason)
    |> assign(:live_turn_id, nil)
    |> assign(:partials, Aqua.stream_new())
    |> assign(:tool_activity, [])
  end

  defp handle_thread_event(socket, :turn_finished, _data) do
    said =
      if socket.assigns.turn_replied, do: "Aqua replied.", else: "Aqua stopped without a reply."

    socket = assign(socket, :announcement, said)

    socket
    |> assign(:turn_replied, false)
    |> assign(:running, false)
    |> assign(:paused, false)
    |> assign(:paused_reason, nil)
    |> assign(:turn_user, nil)
    |> assign(:live_turn_id, nil)
    |> assign(:partials, Aqua.stream_new())
    |> assign(:tool_activity, [])
    |> assign(:cancel_requested, false)
  end

  # Streamed text belongs to the running turn alone: an announcement or a
  # delta for any other turn, or while none runs, is not kept.
  defp handle_thread_event(
         %{assigns: %{running: true, live_turn_id: turn_id}} = socket,
         :turn_fence,
         %{turn_id: turn_id, fence: fence}
       ),
       do: assign(socket, :partials, Aqua.stream_advance(socket.assigns.partials, fence))

  defp handle_thread_event(
         %{assigns: %{running: true, live_turn_id: turn_id}} = socket,
         :delta_abandoned,
         %{turn_id: turn_id} = marker
       ),
       do: assign(socket, :partials, Aqua.stream_abandoned(socket.assigns.partials, marker))

  defp handle_thread_event(
         %{assigns: %{running: true, live_turn_id: turn_id}} = socket,
         :delta,
         %{turn_id: turn_id} = delta
       ),
       do: assign(socket, :partials, Aqua.stream_add(socket.assigns.partials, delta))

  defp handle_thread_event(socket, :tool_activity, list),
    do: assign(socket, :tool_activity, list)

  defp handle_thread_event(socket, :usage, usage), do: assign(socket, :token_usage, usage)

  # Client intents and the grant prompt are the sender's alone: another
  # member's browser must not navigate or be asked because this one asked.
  defp handle_thread_event(socket, :intents, %{intents: intents, user_id: user_id}) do
    if user_id == socket.assigns.context.user_id, do: push_intents(socket, intents), else: socket
  end

  # One grant asked at a time: the turn says it again while the prompt is
  # open, and the open prompt already asks it. A launch naming an account
  # its app does not bind asks for that account.
  defp handle_thread_event(socket, :consent_required, %{ref: ref, user_id: user_id} = data) do
    if user_id == socket.assigns.context.user_id and is_nil(socket.assigns.grant_prompt),
      do: ask_grant(socket, ref, Map.get(data, :account), Map.get(data, :message_id)),
      else: socket
  end

  defp handle_thread_event(socket, :restart_prompt, %{text: text, user_id: user_id}) do
    if user_id == socket.assigns.context.user_id do
      socket
      |> assign(:restart_prompt, text)
      |> assign(:restart_note, nil)
      |> put_flash(:info, "Approved — re-send to continue.")
    else
      socket
    end
  end

  defp handle_thread_event(socket, :error, text), do: put_flash(socket, :error, text)
  defp handle_thread_event(socket, _kind, _data), do: socket

  # The row an event landed on the tape, by its sequence.
  defp landed(kind, %{seq: seq}) when kind in @row_events, do: seq
  defp landed(_kind, _data), do: nil

  # A text row an agent wrote while a turn runs is the turn's reply.
  defp replied?(%{kind: "text", author: @agent_author}, %{assigns: %{running: true}}), do: true
  defp replied?(_row, _socket), do: false

  # The stream owns membership and ordering (stream_insert replaces an
  # existing dom id in place); only whether the thread holds a row, which
  # the empty state reads, is kept as an assign.
  defp upsert_message(socket, row) do
    socket
    |> stream_insert(:messages, row)
    |> assign(:any_messages, true)
  end

  defp put_request(socket, request) do
    socket
    |> assign(:requests, Map.put(socket.assigns.requests, request.id, request))
    |> upsert_message(request)
  end

  # A request already answered stays as its first reply left it.
  defp answered_by(request, reply) do
    request =
      if request.status == "pending",
        do: %{request | status: "answered", resolved_by: reply.id},
        else: request

    if request.id == reply.reply_to,
      do: %{request | replies: Enum.reject(request.replies, &(&1.id == reply.id)) ++ [reply]},
      else: request
  end

  # ---------------------------------------------------------------------------
  # Sending
  # ---------------------------------------------------------------------------

  # The message id is minted here so the attachment bytes can be written
  # under it — by this member's session, through `thread/attach` — before
  # the runner sees the message; the runner then only records the refs.
  defp send_message(socket, message, files) do
    ctx = socket.assigns.context
    message_id = Prima.UUID7.generate_id("msg")

    with {:ok, thread_id} <- destination(socket, files),
         {room, socket} = room_context(socket),
         {:ok, refs} <- attach(ctx, thread_id, message_id, files) do
      envelope = %{
        thread_id: thread_id,
        client_id: Prima.UUID7.generate_id("snd"),
        message_id: message_id,
        text: message,
        attachments: refs,
        agent: socket.assigns.assistant && socket.assigns.assistant["name"],
        model: socket.assigns.model_override,
        room: Keyword.get(room, :room)
      }

      deliver(socket, envelope)
    else
      {:error, reason} -> {:noreply, refuse(socket, reason)}
    end
  end

  # One send, identified once: the envelope carries the message id, the
  # `client_id` and every argument, so a retry — the person's, the pane's
  # own when the fill completes, or one after a reload — offers the same
  # send and is accepted once. The athanor being prepared holds the send
  # with its attachments in place; any other refusal is final, and the
  # files this session stored under the message id are discarded
  # (`discard_stored/2`), since a refused send would otherwise leave blobs
  # that belong to no row.
  defp deliver(socket, envelope) do
    ctx = socket.assigns.context

    case PrismWeb.Ops.call_tool(ctx, "thread/send", send_args(envelope)) do
      {:ok, answer} ->
        {:noreply,
         socket
         |> assign(:held_send, nil)
         |> assign(:input, "")
         |> mirror(nil)
         |> joined(answer[:thread])}

      {:error, :not_provisioned} ->
        {:noreply,
         socket
         |> assign(:held_send, envelope)
         |> assign(:input, "")
         |> mirror(envelope)}

      {:error, reason} ->
        {:noreply,
         socket
         |> discard_stored(envelope)
         |> assign(:held_send, nil)
         |> mirror(nil)
         |> refuse(reason)}
    end
  end

  # Where a send goes: a crew member's or a workspace thread by its id. A
  # send from a daily thread, or from a pane on no thread, names none and
  # joins today's daily thread; its files are written under today's, the
  # thread the message joins, so one with files asks for it first.
  defp destination(%{assigns: %{thread: %{kind: kind, id: id}}}, _files) when kind != "daily",
    do: {:ok, id}

  defp destination(_socket, []), do: {:ok, nil}

  defp destination(socket, _files) do
    with {:ok, %{id: id}} <- PrismWeb.Ops.call_tool(socket, "thread/today", %{}), do: {:ok, id}
  end

  # The message's files go through the gate (`thread/attach`) under the
  # message id minted for this send, before the send names them.
  defp attach(_ctx, _thread_id, _message_id, []), do: {:ok, []}

  defp attach(ctx, thread_id, message_id, files) do
    args = %{
      "thread" => thread_id,
      "message_id" => message_id,
      "files" =>
        for file <- files do
          %{
            "filename" => file["filename"],
            "media_type" => file["media_type"] || Prima.MediaType.binary(),
            "data" => Base.encode64(file["bytes"] || "")
          }
        end
    }

    with {:ok, %{attachments: refs}} <- PrismWeb.Ops.call_tool(ctx, "thread/attach", args) do
      {:ok, refs}
    end
  end

  # The files a refused or given-up send leaves go through the gate
  # (`thread/discard`), which removes only what this person's own session
  # stored under the message and nothing of a sent one, whatever the
  # envelope (which a reload hands back from the browser) names. A send
  # with no files has nothing to discard.
  defp discard_stored(socket, %{attachments: []}), do: socket

  defp discard_stored(socket, envelope) do
    _ =
      PrismWeb.Ops.call_tool(socket.assigns.context, "thread/discard", %{
        "thread" => envelope.thread_id,
        "message_id" => envelope.message_id
      })

    socket
  end

  defp send_args(envelope) do
    %{
      "thread" => envelope.thread_id,
      "message" => envelope.text,
      "id" => envelope.message_id,
      "client_id" => envelope.client_id,
      "attachments" => envelope.attachments,
      "model" => envelope.model,
      "agent" => envelope.agent,
      "room" => envelope.room
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  # The thread a send joined: today's daily thread, when the pane showed
  # another day or none, is shown now, here and by the host.
  defp joined(%{assigns: %{thread: %{id: id}}} = socket, id), do: socket

  defp joined(socket, id) when is_binary(id) do
    tell_host(socket, {:open_thread, id})
    open_thread(socket, thread_of(socket.assigns.context, id))
  end

  defp joined(socket, _none), do: socket

  # What the browser keeps of a held send, so a reload offers it back
  # (`restore_draft`) under the same identity; nil clears it.
  defp mirror(socket, envelope) do
    push_event(socket, "aqua:held_send", %{
      pane: pane_id(socket),
      envelope: envelope && Map.new(envelope, fn {k, v} -> {Atom.to_string(k), v} end)
    })
  end

  # A send that names no thread joins today's and carries no files.
  defp restored(
         socket,
         %{"client_id" => client_id, "message_id" => message_id, "text" => text} = params
       )
       when is_binary(client_id) and is_binary(message_id) and is_binary(text) do
    thread_id = params["thread_id"]
    attachments = params["attachments"] || []
    room = params["room"]

    with true <- is_list(attachments) and Enum.all?(attachments, &is_map/1),
         true <- is_nil(room) or is_map(room),
         true <- (is_nil(thread_id) and attachments == []) or readable?(socket, thread_id) do
      {:ok,
       %{
         thread_id: thread_id,
         client_id: client_id,
         message_id: message_id,
         text: text,
         attachments: attachments,
         agent: if(is_binary(params["agent"]), do: params["agent"]),
         model: if(is_binary(params["model"]), do: params["model"]),
         room: room
       }}
    else
      _ -> :error
    end
  end

  defp restored(_socket, _params), do: :error

  defp readable?(socket, thread_id) when is_binary(thread_id),
    do: match?({:ok, _}, Threads.get(Sanctum.Context.actor(socket.assigns.context), thread_id))

  defp readable?(_socket, _thread_id), do: false

  defp refuse(socket, reason) do
    case reason do
      :busy ->
        put_flash(socket, :error, "Too many turns are already waiting — let one finish first.")

      :held_elsewhere ->
        put_flash(socket, :error, "Another server is running this thread — try again shortly.")

      :not_member ->
        put_flash(socket, :error, "This athanor is not yours.")

      :archived ->
        put_flash(socket, :error, "This athanor has been archived.")

      :thread_retired ->
        put_flash(socket, :error, "This crew member's thread is retired.")

      :not_addressable ->
        put_flash(socket, :error, "Only this thread's crew member can be addressed here.")

      :no_agent ->
        put_flash(socket, :error, "This athanor has no assistant — see Aqua.")

      :storage_full ->
        put_flash(socket, :error, "This athanor's storage is full.")

      :storage_unverifiable ->
        put_flash(socket, :error, "Storage usage can't be verified right now — try again.")

      :message_too_long ->
        put_flash(socket, :error, "That message is too long — up to 32 KiB of text per line.")

      :context_too_long ->
        put_flash(
          socket,
          :error,
          "What the thread beside this shows is too long to read into one message — untick reading it and send again."
        )

      :too_many_attachments ->
        put_flash(socket, :error, "Too many attachments for one message.")

      :attachment_too_large ->
        put_flash(socket, :error, "An attachment is too large.")

      :storage_error ->
        put_flash(socket, :error, "Storing the attachments failed — nothing was sent.")

      other ->
        put_flash(socket, :error, "Could not send: #{error_message(other)}")
    end
  end

  # The shared thread beside this pane, named for this send. Its lines are
  # read server-side, under the person's seat, for this one turn.
  defp room_context(%{assigns: %{read_room?: true, room: %{} = room}} = socket) do
    if reads_room?(room), do: {[room: room], socket}, else: {[], socket}
  end

  defp room_context(socket), do: {[], socket}

  # Beside a shared thread: what the chat overlay shows is one, so there is
  # something to read and to paste onto.
  defp reads_room?(%{"shared_thread_id" => id}) when is_binary(id), do: true
  defp reads_room?(_room), do: false

  # A thread verb for the current member, through the tool surface;
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
      Logger.warning(
        "[ThreadPane] consume uploads failed: #{Prima.LogFilter.exception_message(e)}"
      )

      {:error, :attachments_unreadable}
  end

  # The grant for `ref`, read under the pane's context and asked in the
  # system layer of the view that renders the pane: opened on `account`,
  # the account a launch named, on the app's own calls, when the turn
  # names one, remembering the message of the turn that asked
  # (`message_id`).
  defp ask_grant(socket, ref, account, message_id) do
    id = "grant-#{socket.id}-#{System.unique_integer([:positive])}"

    case PrismWeb.SystemLayer.grant_prompt(socket, id, ref, account_opts(account)) do
      {:ok, prompt} ->
        tell_host(socket, {:grant, self(), prompt})

        socket
        |> assign(:grant_prompt, id)
        |> assign(:grant_retry, if(account, do: {:account, message_id}))

      {:error, reason} ->
        put_flash(socket, :error, "Cannot ask for this grant: #{error_message(reason)}")
    end
  end

  defp account_opts(%{name: name} = account) when is_binary(name),
    do: [account: %{name: name, dep: nil, need: Map.get(account, :need)}]

  defp account_opts(_none), do: []

  # The text of the ended turn's own message, read by its id from this
  # thread: never a scan of the rows around it, which may hold a line
  # queued while the turn ran, or not reach back to it at all.
  defp retry_text(%{assigns: %{thread: %{id: thread_id}, context: ctx}}, message_id)
       when is_binary(message_id) do
    case Threads.get_message(Sanctum.Context.actor(ctx), message_id) do
      {:ok, %{thread_id: ^thread_id, kind: "text", content: text}}
      when is_binary(text) and text != "" ->
        text

      _none ->
        nil
    end
  end

  defp retry_text(_socket, _message_id), do: nil

  # A grant opened for a launch's account offers its turn's message again,
  # as a new turn: that turn ended, so nothing is cut, and with no message
  # of that turn to offer the pane only says so. Any other grant cuts the
  # running turn for the new consent.
  defp after_grant(%{assigns: %{grant_retry: {:account, message_id}}} = socket) do
    socket = assign(socket, :grant_retry, nil)

    case retry_text(socket, message_id) do
      text when is_binary(text) ->
        socket
        |> assign(:restart_prompt, text)
        |> assign(
          :restart_note,
          "The account is granted — send that message again, as a new turn?"
        )
        |> put_flash(:info, "Granted — re-send to continue.")

      nil ->
        put_flash(
          socket,
          :info,
          "Granted. The turn that asked has ended — send your message again to run it."
        )
    end
  end

  defp after_grant(socket), do: socket |> assign(:grant_retry, nil) |> restart_for_consent()

  defp restart_for_consent(socket) do
    case socket.assigns.thread do
      nil ->
        socket

      thread ->
        run(
          socket,
          &PrismWeb.Ops.call_tool(&1, "thread/restart_for_consent", %{"thread" => thread.id})
        )
    end
  end

  # A pane mounted on its own (a test's isolated mount) has no host to tell.
  defp tell_host(%{parent_pid: pid} = socket, message) when is_pid(pid),
    do: send(pid, {:pane, socket.id, message})

  defp tell_host(_socket, _message), do: :ok

  # Whether this athanor's Aqua can answer at all: a soul, and a model
  # with a key behind it. A fresh furnace has neither, and the pane's empty
  # state is where someone finds that out. A model whose consent
  # exists but is damaged, could not be read, or no longer covers what the
  # soul runs on, is said as such: no model is offered to connect over a
  # consent that exists. One that waits on the person's grant alone says
  # so.
  # An agents list that could not be read is not a room with no model.
  defp model_ready(_ctx, :unread), do: :agents_unavailable

  defp model_ready(ctx, agents) do
    case Aqua.model_status(ctx, agents) do
      empty when map_size(empty) == 0 -> :no_model
      statuses -> unready_model(Map.values(statuses))
    end
  end

  # The athanor's soul with its model, read through the `aqua` tool's list
  # with detail, as the Aqua page's agents panel reads it: the roster names
  # who can be addressed and carries no model, so a model's status read
  # from it would always be none. Whether Aqua can answer is the soul's to
  # say, so the crew is left out. The soul is put in the roster's
  # string-keyed projection, its catalyst or the name of its program,
  # which `Aqua.model_status/2` reads. A list
  # that cannot be read is `:unread`, never no agents.
  defp agents(ctx) do
    soul = Compendium.agent_soul_type()

    case PrismWeb.Ops.call_tool(ctx, "aqua", %{"action" => "list", "detail" => true}) do
      {:ok, %{guides: guides}} when is_list(guides) ->
        for %{type: ^soul} = guide <- guides do
          %{
            "name" => guide.name,
            "type" => guide.type,
            "catalyst_ref" => guide[:catalyst_ref],
            "program" => guide[:program]
          }
        end

      _unread ->
        :unread
    end
  end

  defp unready_model(statuses) do
    cond do
      Enum.any?(statuses, &match?({:ready, _}, &1)) -> :ready
      Enum.any?(statuses, &match?({:consent_stale, _}, &1)) -> :consent_stale
      Enum.any?(statuses, &match?({:consent_damaged, _}, &1)) -> :consent_damaged
      Enum.any?(statuses, &match?({:consent_unavailable, _}, &1)) -> :consent_unavailable
      Enum.any?(statuses, &match?({:model_unavailable, _}, &1)) -> :model_unavailable
      Enum.any?(statuses, &match?({:needs_grant, _}, &1)) -> :needs_grant
      true -> :no_key
    end
  end

  # What to call the athanor: the person's own is "your Aqua" — the one
  # their row names as theirs.
  defp athanor_label(%{} = athanor, ctx) do
    if PrismWeb.Athanors.own?(athanor, ctx),
      do: "your Aqua",
      else: PrismWeb.Athanors.label(athanor, ctx)
  end

  defp athanor_label(_none, _ctx), do: "this athanor"

  # What a message would address, and what to call it: the soul or crew member
  # the thread is on, or the roster's first — the athanor's soul — before
  # any turn has run.
  defp assistant_handle(%{"name" => name} = o, _athanor) when is_binary(name) and name != "",
    do: {name, agent_title(o)}

  # No roster entry at all: teach nothing rather than a handle that does
  # not resolve — the "no assistant" note in the header is the honest
  # sentence.
  defp assistant_handle(_, _athanor), do: nil

  defp current_assistant(nil, roster), do: List.first(roster)
  defp current_assistant(%{} = assistant, _roster), do: assistant

  defp assistant_label(%{"name" => name} = o) when is_binary(name), do: agent_title(o)
  defp assistant_label(%{} = o), do: o["title"]
  defp assistant_label(_), do: "your Aqua"

  # An agent by its title; a title that only repeats its name (the
  # runner's live state carries the name in both) reads as the name does
  # to a person, the soul as Aqua (`agent_name/1`).
  defp agent_title(%{"name" => name, "title" => title}) when is_binary(title) and title != name,
    do: title

  defp agent_title(%{"name" => name}), do: agent_name(name)

  # Every message addresses the agent, so the placeholder names it.
  defp composer_placeholder({_handle, label}),
    do: "Ask #{label}…  (Enter to send · Shift+Enter for newline)"

  defp composer_placeholder(nil),
    do: "Say something…  (Enter to send · Shift+Enter for newline)"

  @doc """
  The route a second device reads an attachment's bytes from: the stored
  file `filename` of message `message_id`, in the athanor `athanor_route`
  names.
  """
  @spec attachment_path(String.t() | nil, String.t(), String.t()) :: String.t()
  def attachment_path(athanor_route, message_id, filename) do
    PrismWeb.Focus.path(
      athanor_route,
      "/attachments/#{URI.encode(message_id, &URI.char_unreserved?/1)}/#{URI.encode(filename, &URI.char_unreserved?/1)}"
    )
  end

  # Navigate intents are page paths (`/activities`); the athanor this pane
  # is on is added here, so the assistant never addresses another athanor's
  # pages. A navigate never moves the page the person is reading: it is
  # offered as a link line, theirs to take or leave. Every other intent is
  # pushed, naming this pane: the client acts only on `%{pane: <its
  # section id>}`.
  defp push_intents(socket, []), do: socket

  defp push_intents(socket, intents) do
    mode = socket.assigns[:ui_mode]
    route = socket.assigns.athanor_route

    {navigates, rest} =
      intents
      |> Enum.filter(&mode_permits?(&1, mode))
      |> Enum.map(fn
        %{kind: "navigate", to: to} = intent -> %{intent | to: PrismWeb.Nav.href(to, route)}
        intent -> intent
      end)
      |> Enum.filter(&served?/1)
      |> Enum.split_with(&(&1.kind == "navigate"))

    socket =
      Enum.reduce(navigates, socket, fn %{to: to}, socket ->
        assign(socket, :links, Enum.take(Enum.uniq([to | socket.assigns.links]), @max_links))
      end)

    if rest == [],
      do: socket,
      else: push_event(socket, "aqua:intents", %{pane: pane_id(socket), intents: rest})
  end

  defp pane_id(socket), do: socket.assigns.dom <> "-pane"

  # A navigate lands on a page the console serves or nowhere: the link,
  # focused on this pane's athanor, must resolve in the router, and a
  # redirect stub is not a page. The engine checks a path's shape alone;
  # this is where it is mapped to a route.
  defp served?(%{kind: "navigate", to: href}) do
    if PrismWeb.Nav.page?(href) do
      true
    else
      Logger.warning("[ThreadPane] navigate dropped: #{inspect(href)} is not a page")
      false
    end
  end

  defp served?(_intent), do: true

  # A navigate to a page the current mode does not show is dropped —
  # `PrismWeb.Nav` is the one owner of what a mode surfaces, and an
  # the assistant's intent gets no wider view than the person's own chrome.
  defp mode_permits?(%{kind: "navigate", to: to}, mode), do: PrismWeb.Nav.shown?(to, mode)

  defp mode_permits?(_intent, _mode), do: true

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- Focusable so a click anywhere in the pane makes it the one ⌘. halts.
          `min-h-0`: a column flex item no taller than its host, so a tall
          thread scrolls inside it and the composer stays in view. --%>
    <section
      id={@dom <> "-pane"}
      phx-hook="Thread"
      tabindex="-1"
      class="flex min-h-0 flex-1 min-w-0 flex-col focus:outline-none"
    >
      <header
        :if={status?(assigns)}
        class="flex items-center justify-between gap-2 border-b border-border-default px-3 py-1"
      >
        <div class="flex items-center gap-2 min-w-0">
          <span :if={@preparing?} class="text-xs text-amber-400">
            Still being prepared
          </span>
          <span :if={@roster == [] and not @preparing?} class="text-xs text-amber-400">
            No assistant here
          </span>
          <span
            :if={@queued > 0}
            class="shrink-0 inline-flex items-center rounded bg-gray-800 px-1.5 py-0.5 text-xs text-gray-300"
            title="Messages waiting for Aqua"
          >
            {@queued} queued
          </span>
        </div>
        <div class="flex items-center gap-1">
          <span
            :if={@running and @turn_user}
            class="text-xs text-gray-500 truncate max-w-[12rem]"
          >
            {label_for(@members, @turn_user, @context)} is asking…
          </span>
        </div>
      </header>

      <%!-- The thread's menu: the model override, the soul or crew member and
            the thread's usage. The panel's hook shows and hides it from the
            panel's header, so its `hidden` is the browser's to keep. --%>
      <div
        id={@dom <> "-menu"}
        hidden
        phx-mounted={JS.ignore_attributes(["hidden"])}
        role="group"
        aria-label="This thread"
        class="aqua-panel-menu"
      >
        <div class="aqua-panel-menu-row">
          <span>Model</span>
          <%= cond do %>
            <% @models_loaded and @models_by_provider != %{} -> %>
              <.model_override
                assistant={@assistant}
                models_by_provider={@models_by_provider}
                model_override={@model_override}
                class="min-w-0 max-w-[10rem] cursor-pointer truncate rounded-[7px] border border-border-default bg-surface-base px-1.5 py-0.5 font-mono text-xs text-text-primary focus:border-border-focus focus:outline-none"
              />
            <% @models_loaded -> %>
              <span class="truncate font-mono">
                {(@assistant && @assistant["model"]) || "default"}
              </span>
            <% true -> %>
              <span>Reading the models…</span>
          <% end %>
        </div>
        <div class="aqua-panel-menu-row" title="The soul or crew member this thread is on">
          <span>Soul or crew member</span>
          <span class="truncate">
            {if @roster == [],
              do: "No assistant here",
              else: assistant_label(current_assistant(@assistant, @roster))}
          </span>
        </div>
        <div :if={room?(@thread)} class="aqua-panel-menu-row">
          <span :if={@thread.archived_at} title="New work here takes it out of the archive">
            Archived
          </span>
          <button
            :if={is_nil(@thread.archived_at)}
            id={@dom <> "-archive"}
            type="button"
            phx-click="archive"
            title="Your list shows it under Archived; nothing else about it changes"
            class="rounded px-1.5 py-0.5 text-text-secondary hover:bg-surface-base hover:text-text-primary"
          >
            Archive
          </button>
        </div>
        <div class="aqua-panel-menu-row">
          <span>Tokens</span>
          <span class="font-mono">
            {@token_usage.input} in · {@token_usage.output} out
          </span>
        </div>
      </div>

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

      <%!-- What a screen reader hears: a coherent update — Aqua started, Aqua
            replied — never the stream, which would announce every word. --%>
      <div id={@dom <> "-announcer"} class="sr-only" aria-live="polite" aria-atomic="true">
        {@announcement}
      </div>

      <nav
        :if={@children != []}
        id={@dom <> "-crew"}
        aria-label="Crew threads"
        class="flex flex-wrap items-center gap-1.5 border-b border-gray-800 px-4 py-1.5 text-xs text-gray-500"
      >
        <span>Crew</span>
        <button
          :for={child <- @children}
          id={@dom <> "-crew-" <> child.id}
          type="button"
          phx-click="open_thread"
          phx-value-id={child.id}
          class="min-h-6 rounded bg-gray-800 px-2 py-0.5 text-gray-300 hover:bg-gray-700"
        >
          {child.agent}<span :if={child.retired_at} class="text-gray-500"> · archived</span>
        </button>
      </nav>

      <div
        :if={match?(%{kind: "crew"}, @thread)}
        id={@dom <> "-crew-thread"}
        class="flex items-center gap-2 border-b border-gray-800 px-4 py-1.5 text-xs text-gray-500"
      >
        <span class="shrink-0">{@thread.agent}'s thread</span>
        <button
          type="button"
          phx-click="open_thread"
          phx-value-id={@thread.parent_id}
          class="min-h-6 min-w-0 truncate text-blue-400 hover:text-blue-300"
        >
          Back to {room_name(@parent)}
        </button>
        <span :if={@thread.retired_at} class="ml-auto shrink-0">Archived</span>
        <button
          :if={is_nil(@thread.retired_at)}
          type="button"
          phx-click="archive"
          data-confirm={"Archive #{@thread.agent}'s thread? Its work here stops."}
          class="ml-auto min-h-6 shrink-0 rounded px-2 py-0.5 text-gray-400 hover:bg-gray-800 hover:text-gray-200"
        >
          Archive
        </button>
      </div>

      <div
        id={@dom <> "-thread"}
        data-thread={@thread && @thread.id}
        phx-hook="ScrollBottom"
        class="flex-1 overflow-y-auto px-4 py-3 space-y-3"
      >
        <div
          :if={not @any_messages and Aqua.stream_texts(@partials) == []}
          class="flex flex-col items-center justify-center h-full gap-2 text-sm text-gray-500"
        >
          <%= if @preparing? do %>
            <span>{athanor_label(@athanor, @context)} is still being prepared.</span>
            <span class="text-gray-600">Its agents and components are being installed.</span>
          <% else %>
            <%= cond do %>
              <% @model_ready == :pending -> %>
                <span data-test="model-pending">Reading the model…</span>
              <% @model_ready in [:no_model, :no_key] -> %>
                <span>{athanor_label(@athanor, @context)} has no model yet.</span>
                <.link
                  navigate={PrismWeb.Focus.path(@athanor, "/aqua?setup=1")}
                  data-test="model-connect"
                  class="text-blue-400 hover:underline"
                >
                  Connect one on your Aqua page.
                </.link>
              <% @model_ready == :needs_grant -> %>
                <%!-- A model with nothing left to set up waits on the
                     person's grant alone, given in Aqua's setup. --%>
                <span data-test="model-grant">
                  {athanor_label(@athanor, @context)}'s model needs only your grant.
                </span>
                <.link
                  navigate={PrismWeb.Focus.path(@athanor, "/aqua?setup=1")}
                  class="text-blue-400 hover:underline"
                >
                  Grant it on your Aqua page.
                </.link>
              <% @model_ready == :consent_stale -> %>
                <%!-- The soul's shape moved since its consent: consenting
                     again is all it needs, never a model to connect. --%>
                <span data-test="model-consent">
                  What Aqua runs on changed since it was consented.
                </span>
                <.link
                  navigate={PrismWeb.Focus.path(@athanor, "/aqua")}
                  class="text-blue-400 hover:underline"
                >
                  Consent again on your Aqua page.
                </.link>
              <% @model_ready == :consent_damaged -> %>
                <%!-- A consent that exists but is damaged, or could not be read,
                     is no model to connect: it is said as such. --%>
                <span data-test="model-consent">
                  A consent this model runs under is damaged and cannot be used — revoke the damaged profile and grant it again.
                </span>
              <% @model_ready == :consent_unavailable -> %>
                <span data-test="model-consent">
                  A consent this model runs under cannot be read right now — try again.
                </span>
              <% @model_ready == :agents_unavailable -> %>
                <%!-- Whether the room has agents, or a model, could not be
                     read: nothing is offered but to try again. --%>
                <span data-test="agents-unavailable">
                  Aqua and its crew members cannot be read right now — try again.
                </span>
              <% @model_ready == :model_unavailable -> %>
                <%!-- Whether the model is installed could not be read: nothing
                     is offered but to try again. --%>
                <span data-test="model-unavailable">
                  This model cannot be read right now — try again.
                </span>
              <% true -> %>
                <span>
                  Ask {assistant_label(current_assistant(@assistant, @roster))} anything.
                </span>
            <% end %>
          <% end %>
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
              <%= cond do %>
                <% crew(msg) == :request -> %>
                  <.message_bubble
                    id={@dom <> "-msg-" <> msg.id}
                    role={role_of(msg)}
                    content={msg.content}
                    author={"#{speaker(msg, @members, @context)} asked #{msg.addressee} · #{msg.status}"}
                    attachments={attachments(msg)}
                    attachment_href={&attachment_path(@athanor_route, msg.id, &1)}
                    links={Threads.payload(msg)["links"] || []}
                  />
                  <.reply
                    :for={reply <- msg.replies}
                    id={@dom <> "-reply-" <> reply.id}
                    dom={@dom}
                    reply={reply}
                    athanor_route={@athanor_route}
                  />
                <% crew(msg) == :reply -> %>
                  <.reply
                    id={@dom <> "-reply-" <> msg.id}
                    dom={@dom}
                    reply={msg}
                    athanor_route={@athanor_route}
                  />
                <% Map.has_key?(@cards, msg.id) -> %>
                  <.work_card
                    id={@dom <> "-msg-" <> msg.id}
                    msg={msg}
                    work={@works[msg.workspace_id]}
                    author={author_label(msg, @members, @context)}
                    athanor_route={@athanor_route}
                  />
                <% true -> %>
                  <div class="group/aloud">
                    <.message_bubble
                      id={@dom <> "-msg-" <> msg.id}
                      role={role_of(msg)}
                      content={msg.content}
                      author={author_label(msg, @members, @context)}
                      attachments={attachments(msg)}
                      attachment_href={&attachment_path(@athanor_route, msg.id, &1)}
                      links={Threads.payload(msg)["links"] || []}
                    />
                    <%!-- A line you may paste onto the shared thread beside
                        the pane: yours, or your assistant's in your own
                        athanor. --%>
                    <div
                      :if={reads_room?(@room) and sayable?(msg, @context, @own?)}
                      class="flex justify-end"
                    >
                      <button
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
          <li :for={entry <- @tool_activity} class="flex items-center gap-2 text-xs">
            <span class="inline-flex items-center px-2 py-0.5 rounded bg-gray-800 text-gray-300 font-mono shrink-0">
              {entry.tool}
            </span>
            <.status_indicator status={if entry.status == :done, do: "completed", else: "running"} />
            <span :if={entry.preview} class="text-gray-500 truncate">{entry.preview}</span>
          </li>
        </ul>

        <.message_bubble
          :for={partial <- Aqua.stream_texts(@partials)}
          id={@dom <> "-streaming-" <> partial.step_id}
          role="assistant"
          content={partial.text}
          author={agent_name(partial.role || Prima.AgentRef.soul_name())}
        />

        <div
          :if={@running and Aqua.stream_texts(@partials) == [] and @tool_activity == []}
          class="flex items-center gap-2 text-xs text-gray-500"
        >
          <span class="inline-block h-2 w-2 animate-pulse rounded-full bg-blue-400" />
          <span>Thinking…</span>
        </div>

        <div
          :if={@paused and @paused_reason == :uncertain}
          id={@dom <> "-stopped"}
          class="flex items-center gap-2 text-xs text-amber-700"
        >
          <span class="inline-block h-2 w-2 rounded-full bg-amber-500" />
          <span>Stopped: a tool's outcome is unknown.</span>
          <span :if={@turn_user == @context.user_id}>
            Your next message continues this turn with reads only.
          </span>
          <span :if={@turn_user != @context.user_id}>
            A message from you waits behind this turn.
          </span>
        </div>
      </div>

      <div
        :if={@restart_prompt}
        class="flex items-center gap-2 border-t border-blue-900/60 bg-blue-900/10 px-3 py-2 text-xs text-blue-200"
      >
        <span class="truncate">
          {@restart_note || "The turn was cut for the new consent — send it again?"}
        </span>
        <button
          type="button"
          phx-click="restart_send"
          class="ml-auto min-h-6 rounded bg-blue-700 px-2 py-0.5 text-white hover:bg-blue-600"
        >
          Re-send
        </button>
        <button
          type="button"
          phx-click="dismiss_restart"
          class="min-h-6 rounded px-2 py-0.5 text-gray-400 hover:text-gray-200"
        >
          Dismiss
        </button>
      </div>

      <div
        :if={@held_send}
        class="flex items-center gap-2 border-t border-amber-900/60 bg-amber-900/10 px-3 py-2 text-xs text-amber-200"
      >
        <span class="truncate">
          Still being prepared — your message is held and goes when the athanor is ready.
        </span>
        <button
          type="button"
          phx-click="retry_send"
          class="ml-auto min-h-6 rounded bg-amber-700 px-2 py-0.5 text-white hover:bg-amber-600"
        >
          Retry
        </button>
        <button
          type="button"
          phx-click="discard_send"
          class="min-h-6 rounded px-2 py-0.5 text-gray-400 hover:text-gray-200"
        >
          Discard
        </button>
      </div>

      <div
        :if={@links != []}
        id={@dom <> "-links"}
        class="flex flex-col gap-1 border-t border-gray-800 px-3 py-1.5 text-xs text-gray-500"
      >
        <div :for={to <- @links} class="flex min-w-0 items-center gap-2">
          <span class="shrink-0">Aqua points to</span>
          <.link navigate={to} class="truncate leading-6 text-blue-400 hover:text-blue-300">
            {to}
          </.link>
          <button
            type="button"
            phx-click="dismiss_link"
            phx-value-to={to}
            aria-label="Dismiss"
            class="ml-auto min-h-6 min-w-6 shrink-0 px-1 text-gray-500 hover:text-gray-200"
          >
            ×
          </button>
        </div>
      </div>

      <div
        :if={@reads_notice?}
        id={@dom <> "-reads-notice"}
        class="flex items-start gap-2 border-t border-gray-800 px-3 py-1.5 text-xs text-gray-400"
      >
        <p class="min-w-0 flex-1">
          Aqua reads your shared threads when you ask about them. What it reads there, other people's words included, goes to your model provider.
        </p>
        <button
          type="button"
          phx-click="dismiss_reads_notice"
          class="min-h-6 shrink-0 px-1 text-gray-500 hover:text-gray-200"
        >
          Got it
        </button>
      </div>

      <label
        :if={reads_room?(@room)}
        id={@dom <> "-read-room"}
        title="Each message you send here carries what the thread beside it shows — read for you, never kept"
        class="flex cursor-pointer items-center gap-2 border-t border-gray-800 px-3 py-1 text-xs text-gray-500"
      >
        <input
          type="checkbox"
          phx-click="toggle_read_room"
          checked={@read_room?}
          class="h-6 w-6 rounded border-gray-700 bg-gray-900"
        />
        <span class="truncate">Read {PrismWeb.RoomFeed.label(@room)} with each message</span>
      </label>

      <form
        id={@dom <> "-composer"}
        phx-submit="submit"
        phx-change="validate_upload"
        class="space-y-2 border-t border-border-default px-3 pt-2.5 pb-3"
      >
        <div :if={@uploads.attachments.entries != []} class="flex flex-wrap gap-1">
          <div
            :for={entry <- @uploads.attachments.entries}
            class="flex items-center gap-1 rounded bg-gray-800 px-2 py-0.5 text-xs"
          >
            <span class="text-gray-300 truncate max-w-[12rem]">{entry.client_name}</span>
            <span :if={entry.progress > 0 and entry.progress < 100} class="text-gray-500">
              {entry.progress}%
            </span>
            <button
              type="button"
              phx-click="cancel_upload"
              phx-value-ref={entry.ref}
              class="inline-flex min-h-6 min-w-6 items-center justify-center text-gray-500 hover:text-red-400"
              aria-label="Remove"
            >
              ×
            </button>
          </div>
        </div>

        <div class="flex gap-2 items-end">
          <label
            class="grid h-9 w-8 cursor-pointer place-items-center self-end rounded-[10px] text-sm text-text-muted hover:text-text-secondary"
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
              composer_placeholder(assistant_handle(current_assistant(@assistant, @roster), @athanor))
            }
            class="min-h-9 max-h-40 flex-1 resize-none overflow-y-auto rounded-[10px] border border-border-default bg-surface-base px-2.5 py-2 text-sm text-text-primary placeholder-text-muted focus:border-border-focus focus:outline-none focus:ring-0"
            disabled={@roster == []}
          >{@input}</textarea>
          <button
            type="submit"
            disabled={@roster == [] or (@input == "" and @uploads.attachments.entries == [])}
            class="h-9 self-end rounded-[10px] bg-accent-primary px-3.5 text-sm font-semibold text-white hover:bg-accent-hover disabled:cursor-not-allowed disabled:opacity-40"
          >
            Send
          </button>
          <button
            :if={@running or @paused}
            type="button"
            phx-click="stop"
            title="Stop this turn; what waits behind it is dropped"
            class="self-end rounded-md bg-red-600 px-4 py-2 text-sm font-medium text-white hover:bg-red-500"
          >
            {if @cancel_requested, do: "Cancelling…", else: "Stop"}
          </button>
        </div>
      </form>
    </section>
    """
  end

  attr :assistant, :any, required: true
  attr :models_by_provider, :map, required: true
  attr :model_override, :any, required: true
  attr :class, :string, required: true

  # The thread's model for the next sends: the assistant's own, or one the
  # catalogue offers.
  defp model_override(assigns) do
    ~H"""
    <select
      phx-change="select_model"
      name="model"
      class={@class}
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
    """
  end

  # The status line is drawn only while it says something.
  defp status?(assigns) do
    assigns.preparing? or assigns.roster == [] or assigns.queued > 0 or
      (assigns.running and assigns.turn_user != nil)
  end

  attr :id, :string, required: true
  attr :role, :string, required: true
  attr :content, :string, required: true
  attr :author, :any, default: nil
  attr :attachments, :list, default: []
  attr :attachment_href, :any, default: nil
  attr :links, :list, default: []

  @doc """
  A post as the pane draws it, by its `role` and `author`: it draws what it
  holds, whoever wrote it, a picture in place, which opens large over the
  page, any other file a chip that downloads (`attachment_href`, a
  function of the stored name), a file marked `"removed"` (deleted from
  Files) a line saying so, and a link a link, never fetched. The
  workspace layer draws a thread's results with it.
  """
  def message_bubble(assigns) do
    # The model's surrounding whitespace would inflate the bubble.
    display = String.trim(assigns.content || "")

    {removed, kept} = Enum.split_with(assigns.attachments, &(&1["removed"] == true))

    {pictures, files} =
      kept
      |> Enum.with_index()
      |> Enum.split_with(fn {a, _} -> picture?(a, assigns.attachment_href) end)

    pictures = for {a, n} <- pictures, do: {a, "#{assigns.id}-picture-#{n}"}

    assigns =
      assign(assigns,
        display_content: display,
        pictures: pictures,
        files: Enum.map(files, &elem(&1, 0)),
        removed: removed,
        shown_links: shown_links(assigns.links)
      )

    ~H"""
    <div class={["flex flex-col", role_align(@role)]}>
      <span :if={@author} class="text-xs text-gray-500 mb-0.5 px-1">{@author}</span>
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
        <div :if={@pictures != []} class="mt-1 flex flex-wrap gap-1">
          <%= for {a, large} <- @pictures do %>
            <button
              type="button"
              phx-click={open_large(large)}
              aria-label={"Open #{a["filename"]} large"}
              class="block min-h-6 rounded hover:opacity-90"
            >
              <img
                src={@attachment_href.(a["stored_name"])}
                alt={a["filename"]}
                loading="lazy"
                class="max-h-48 max-w-full rounded"
              />
            </button>
            <div id={large} class="hidden">
              <div
                role="dialog"
                aria-modal="true"
                aria-label={a["filename"]}
                phx-click={close_large(large)}
                class="fixed inset-0 z-50 flex flex-col items-center justify-center gap-2 bg-black/85 p-4"
              >
                <img
                  src={@attachment_href.(a["stored_name"])}
                  alt={a["filename"]}
                  class="max-h-[90%] max-w-full object-contain"
                />
                <%!-- Escape is bound here, where opening puts the focus:
                      LiveView reads a key binding from the key's own
                      target, never from an ancestor. --%>
                <button
                  id={"#{large}-close"}
                  type="button"
                  phx-keydown={close_large(large)}
                  phx-key="Escape"
                  class="min-h-6 rounded bg-gray-800 px-2 py-0.5 text-xs text-gray-200 hover:bg-gray-700"
                >
                  Close
                </button>
              </div>
            </div>
          <% end %>
        </div>
        <div :if={@files != []} class="mt-1 flex flex-wrap gap-1">
          <%= for a <- @files do %>
            <a
              :if={@attachment_href && a["stored_name"]}
              href={@attachment_href.(a["stored_name"])}
              download={a["filename"]}
              class="inline-flex min-h-6 items-center rounded bg-black/20 px-1.5 py-0.5 text-xs hover:bg-black/40 underline-offset-2 hover:underline"
            >
              📎 {a["filename"]}
            </a>
            <span
              :if={!(@attachment_href && a["stored_name"])}
              class="inline-flex items-center rounded bg-black/20 px-1.5 py-0.5 text-xs"
            >
              📎 {a["filename"]}
            </span>
          <% end %>
        </div>
        <div :if={@removed != []} class="mt-1 flex flex-wrap gap-1">
          <span
            :for={a <- @removed}
            data-removed
            class="inline-flex min-h-6 items-center rounded bg-black/20 px-1.5 py-0.5 text-xs text-gray-400 italic"
          >
            {a["filename"]} was removed
          </span>
        </div>
        <div :if={@shown_links != []} class="mt-1 flex flex-col items-start gap-0.5">
          <a
            :for={link <- @shown_links}
            href={link.url}
            target="_blank"
            rel="noopener noreferrer"
            class="inline-flex min-h-6 items-center text-xs text-blue-300 underline hover:text-blue-200 break-all"
          >
            {link.title}
          </a>
        </div>
      </div>
    </div>
    """
  end

  # The picture types the attachment address serves as themselves
  # (`PrismWeb.AttachmentController`); an SVG is never one, since it runs
  # script. A file that is not stored, or another type, is a chip.
  @picture_types ~w(image/png image/jpeg image/gif image/webp)

  # The large view opens over the page with the focus on its Close, and
  # gives the focus back to the picture when it closes.
  defp open_large(large) do
    JS.push_focus()
    |> JS.remove_class("hidden", to: "##{large}")
    |> JS.focus(to: "##{large}-close")
  end

  defp close_large(large), do: JS.add_class("hidden", to: "##{large}") |> JS.pop_focus()

  defp picture?(a, href),
    do: href != nil and is_binary(a["stored_name"]) and a["media_type"] in @picture_types

  # A link is drawn only as an http or https address with a host: anything
  # else (`javascript:`, `data:`) is not a link a post may carry. Its title
  # is the author's, or the address itself.
  defp shown_links(links) when is_list(links) do
    for %{"url" => url} = link <- links,
        is_binary(url),
        %URI{scheme: scheme, host: host} <- [URI.parse(url)],
        scheme in ["http", "https"] and is_binary(host) and host != "" do
      title = link["title"]
      %{url: url, title: if(is_binary(title) and String.trim(title) != "", do: title, else: url)}
    end
  end

  defp shown_links(_), do: []

  attr :id, :string, required: true
  attr :dom, :string, required: true
  attr :reply, :map, required: true
  attr :athanor_route, :any, required: true

  # A crew member's reply, by its member and outcome. A reply cut short
  # says where the whole of it is: the member's thread.
  defp reply(assigns) do
    assigns = assign(assigns, :payload, Threads.payload(assigns.reply))

    ~H"""
    <div id={@id}>
      <.message_bubble
        id={@dom <> "-msg-" <> @reply.id}
        role="assistant"
        content={@reply.content}
        author={"#{agent_name(@reply.sent_by)} · #{@reply.outcome}"}
        attachments={attachments(@reply)}
        attachment_href={&attachment_path(@athanor_route, @reply.id, &1)}
        links={@payload["links"] || []}
      />
      <button
        :if={@payload["truncated"] == true and is_binary(@payload["from_thread"])}
        type="button"
        phx-click="open_thread"
        phx-value-id={@payload["from_thread"]}
        class="min-h-6 px-1 text-xs text-blue-400 hover:text-blue-300"
      >
        The whole answer is in {agent_name(@reply.sent_by)}'s thread
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :msg, :map, required: true
  attr :work, :any, required: true
  attr :author, :string, default: nil
  attr :athanor_route, :any, required: true

  # A workspace thread's pointer or report: the post as it was written, then
  # its thread's state as it is now and Open, or that it is gone.
  defp work_card(assigns) do
    assigns = assign(assigns, :payload, Threads.payload(assigns.msg))

    ~H"""
    <div id={@id <> "-card"}>
      <.message_bubble
        id={@id}
        role={role_of(@msg)}
        content={@msg.content}
        author={@author}
        attachments={attachments(@msg)}
        attachment_href={&attachment_path(@athanor_route, @msg.id, &1)}
        links={@payload["links"] || []}
      />
      <div class={["mt-0.5 flex items-center gap-2 px-1 text-xs", role_align_row(role_of(@msg))]}>
        <%= case @work do %>
          <% %{id: id, state: state} -> %>
            <span id={@id <> "-state"} data-state={state} class="text-gray-400">
              {work_state(state)}
            </span>
            <span :if={@work.unread > 0} class="text-gray-500">· {@work.unread} new</span>
            <button
              id={@id <> "-open"}
              type="button"
              phx-click="open_thread"
              phx-value-id={id}
              class="min-h-6 text-blue-400 hover:text-blue-300"
            >
              Open
            </button>
          <% _gone -> %>
            <span id={@id <> "-state"} class="text-gray-500">
              This workspace thread was deleted
            </span>
        <% end %>
      </div>
    </div>
    """
  end

  defp role_align_row("user"), do: "justify-end"
  defp role_align_row(_role), do: "justify-start"

  # What a row is on the tape, as `Aqua.Tape` announces it: a request to a
  # crew member, a reply to one, or neither.
  defp crew(%{reply_to: id}) when is_binary(id), do: :reply

  defp crew(%{addressee: addressee, status: status})
       when is_binary(addressee) and status in ["pending", "answered"],
       do: :request

  defp crew(_row), do: nil

  # The room a crew thread works under: a daily thread by its day's date,
  # a workspace thread by its title.
  defp room_name(%{kind: "daily", day: %Date{} = day}), do: day_name(day)
  defp room_name(%{title: title}) when is_binary(title), do: title
  defp room_name(_none), do: "its thread"

  # Who sent a line: a person as the console names them, an agent by
  # `agent_name/1`.
  defp speaker(%{sent_by: @person, author: author}, members, ctx),
    do: label_for(members, author, ctx)

  defp speaker(%{sent_by: agent}, _members, _ctx), do: agent_name(agent)

  defp agent_name(name) do
    if Prima.AgentRef.soul?(name), do: "Aqua", else: name
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
      "focus-visible:opacity-100 max-md:opacity-100 min-h-6 text-xs text-gray-500 hover:text-gray-300 px-1"
  end

  # A post, and a line of the server's to the thread's Aqua (`Aqua.Nudge`),
  # which is drawn as the server's and is no post.
  defp drawn?(row), do: Threads.post?(row) or row.kind == "nudge"

  defp role_of(%{kind: "error"}), do: "error"
  defp role_of(%{kind: kind}) when kind in ["system", "nudge"], do: "system"
  defp role_of(%{author: @agent_author}), do: "assistant"

  # A post in the server's voice: a schedule's line, or a post of the
  # server's own (`Aqua.Nudge`), never the person's.
  defp role_of(%{kind: "text", author: @system_author}), do: "server"

  defp role_of(_), do: "user"

  # The schedule whose fire a row is, by its name: a text row in the
  # server's voice that names it.
  defp fired_by(%{kind: "text", author: @system_author} = msg) do
    case Threads.payload(msg)["schedule"] do
      %{"name" => name} when is_binary(name) -> name
      _none -> nil
    end
  end

  defp fired_by(_msg), do: nil

  defp author_label(%{author: @system_author} = msg, _members, _ctx) do
    if name = fired_by(msg), do: "Schedule · #{name}"
  end

  defp author_label(%{kind: kind}, _members, _ctx) when kind in ["error", "system", "nudge"],
    do: nil

  # A workspace thread's pointer, whose post is its title, and its report,
  # which names it.
  defp author_label(%{kind: "pointer"}, _members, _ctx), do: "Workspace thread"

  defp author_label(%{kind: "report"} = msg, _members, _ctx),
    do: "Report · #{Threads.payload(msg)["title"]}"

  # A copy of an assistant's line is the person's, and says so.
  defp author_label(msg, members, ctx) do
    label = speaker(msg, members, ctx)

    if Threads.payload(msg)["shared_agent"] == true,
      do: "shared from Aqua by #{label}",
      else: label
  end

  # A member from the labels read at mount; anyone since gone by the same
  # rule.
  defp label_for(members, user_id, ctx) when is_binary(user_id) do
    Map.get(members, user_id) || PrismWeb.People.label(user_id, ctx)
  end

  defp label_for(_members, _user_id, _ctx), do: nil

  defp role_align("user"), do: "items-end"
  defp role_align(_), do: "items-start"

  defp role_class("user"), do: "bg-indigo-600 text-white"
  defp role_class("error"), do: "bg-red-900/40 text-red-300 border border-red-800"
  defp role_class("system"), do: "bg-gray-800/60 text-gray-400 border border-gray-800 italic"
  defp role_class("server"), do: "bg-sky-950/50 text-sky-100 border border-sky-900/60"
  defp role_class(_), do: "bg-gray-800 text-gray-200"
end
