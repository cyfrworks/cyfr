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
  the turn ended when it has no such message to offer. A person's turn
  refused for Aqua's grant asks for it the same way, its message beside
  it: granted, that message is offered again as a new turn.

  Every line is named by who sent it (`sent_by`): a person as the console
  names them, the soul as Aqua, a crew member by its name. A schedule's
  fire is written in the server's voice and drawn as that schedule's,
  under its name, never as the person's line. A request to a crew member
  says who asked whom and how it stands: pending, then the outcome of the
  reply that resolved it, its own or another request's (`Arca.Schemas.Message`'s
  `resolved_by`), the same live and read again; the replies to it stand
  beneath it, and once its member's thread stands it opens that thread.
  A reply whose request is not on screen stands on its own. A room lists
  the threads of the crew members its roster holds (`Aqua.roster/1`): a
  member taken out of the crew keeps its thread, which the list leaves
  out. A member's thread names its member, leads back to its room and,
  while it stands, can be archived (`thread.archive`). The pane opens
  none of them: it asks its host to open the thread, `{:open_thread,
  id}`. Any thread it shows is deleted from its menu (`thread.delete`), a
  room with its crew threads, once the person says yes to what goes and
  what stays, and the deletion is told to the host, `{:deleted, id}`; the
  host leaves a thread the person's list announces removed.

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
  the rows the pane reads under its own context; and Aqua's newest answer,
  its soul's last post in the same shape (nil for none), `{:answer,
  thread_id, answer}` when a thread opens and as each one lands. The
  pane reads a thread's newest posts only, `@window` of them, and has no
  way to earlier ones:
  `window` is that number when the read filled it, so earlier posts and
  what they hold may exist and are shown nowhere here, and nil when the
  pane holds the whole thread.

  What a turn asks of the browser is its sender's alone: a page the
  assistant points at is offered as a link under the thread
  (`<dom>-links`), never followed, so the page the person is reading
  stays; every other intent is pushed as `aqua:intents` naming this pane.

  The panel's own header names Aqua and the thread, so the pane draws no
  name or thread label of its own, and its model override, soul or crew
  member and token counts sit in a menu (`<dom>-menu`), which its host
  opens: the panel's header through the panel's hook, which also closes
  it. A host that names its own toggle of the menu (the session's
  `"menu_toggle"`, its DOM id) has the menu close on a press away from
  it and on Escape, by JS commands alone, Escape giving focus back to the
  toggle. Its status line appears only while it has something to
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
    socket =
      socket
      |> assign(:dom, socket.id)
      |> assign(:menu_toggle, session["menu_toggle"])
      |> beside(session)
      |> open(ctx, session)

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
      |> assign(:choices, %{})
      |> assign(:proposals, %{})
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

        # What the thread drew live is what it draws opened again: the
        # newest rows it draws (`drawn_kinds/0`), however many of a turn's
        # own rows stand between them. Its cards and results are posts
        # too, read with them.
        rows =
          case Threads.latest_messages(Sanctum.Context.actor(ctx), thread.id, @window,
                 kinds: drawn_kinds()
               ) do
            rows when is_list(rows) -> Enum.map(rows, &files_kept(&1, ctx))
            {:error, _} -> []
          end

        rows = with_proposals(rows, ctx, thread.id)
        {rows, choices} = read_choices(rows, ctx)

        {shown, requests} = file_replies(rows, ctx)

        tell_host(
          socket,
          {:results, thread.id, rows |> Enum.map(&result/1) |> Enum.reject(&is_nil/1),
           if(length(rows) >= @window, do: @window)}
        )

        answer = rows |> Enum.filter(&answer?/1) |> Enum.max_by(& &1.seq, fn -> nil end)
        tell_host(socket, {:answer, thread.id, answer && post(answer)})

        socket
        |> hold_cards(rows)
        |> assign(:choices, choices)
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

  # The scrolls the thread's turns proposed (`proposal?/1`), read as such
  # (`proposed`), each from where the posts drawn begin, and drawn in its
  # place among them: a proposal has its card while its row can be seen.
  defp with_proposals(rows, ctx, thread_id) do
    from = if length(rows) >= @window, do: rows |> Enum.map(& &1.seq) |> Enum.min(), else: 0

    case Threads.messages(Sanctum.Context.actor(ctx), thread_id,
           after_seq: from - 1,
           status: "proposed"
         ) do
      proposals when is_list(proposals) ->
        Enum.sort_by(rows ++ Enum.filter(proposals, &proposal?/1), & &1.seq)

      {:error, _} ->
        rows
    end
  end

  # A request is shown with the replies to it beneath it and the outcome
  # of the reply that resolved it, and kept by id so a reply heard later
  # files under it too; a reply whose request is not among the rows shown
  # stands on its own.
  defp file_replies(rows, ctx) do
    asked = for row <- rows, crew(row) == :request, into: MapSet.new(), do: row.id

    {nested, shown} =
      Enum.split_with(rows, &(crew(&1) == :reply and MapSet.member?(asked, &1.reply_to)))

    replies = Enum.group_by(nested, & &1.reply_to)
    by_id = Map.new(rows, &{&1.id, &1})

    shown =
      Enum.map(shown, fn row ->
        if crew(row) == :request,
          do:
            Map.merge(row, %{
              replies: Map.get(replies, row.id, []),
              outcome: resolved(row, by_id, ctx)
            }),
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

  # A reply's question as buttons (`Aqua.Choices.read/2`): a row that gives
  # them carries its card, and the pane holds each row whose card it draws
  # or may yet draw, a row of a turn still open, by id.
  defp read_choices(rows, ctx) do
    Enum.map_reduce(rows, %{}, fn row, held ->
      case Aqua.Choices.read(ctx, row) do
        {:ok, card} -> {Map.put(row, :card, card), Map.put(held, row.id, %{row: row, card: card})}
        :pending -> {row, Map.put(held, row.id, %{row: row, card: :pending})}
        :none -> {row, held}
      end
    end)
  end

  defp hold_choice(socket, row) do
    {[row], held} = read_choices([row], socket.assigns.context)
    {row, assign(socket, :choices, Map.merge(socket.assigns.choices, held))}
  end

  # Each card held, read again: a row lands that may close one, a turn
  # ends whose last row may be one, or a press was answered. The stream
  # draws a row once, so a changed one is put back, a reply beneath its
  # request. A card that cannot be read now keeps what it shows.
  defp reread_choices(socket) do
    ctx = socket.assigns.context

    Enum.reduce(socket.assigns.choices, socket, fn {id, %{row: row, card: was}}, socket ->
      case Aqua.Choices.read(ctx, row) do
        ^was ->
          socket

        :none when was == :pending ->
          assign(socket, :choices, Map.delete(socket.assigns.choices, id))

        :none ->
          socket

        :pending ->
          socket

        {:ok, card} ->
          socket
          |> assign(:choices, Map.put(socket.assigns.choices, id, %{row: row, card: card}))
          |> redraw(Map.put(row, :card, card))
      end
    end)
  end

  defp redraw(socket, %{reply_to: request_id} = reply) when is_binary(request_id) do
    case socket.assigns.requests[request_id] do
      %{replies: replies} = request ->
        if Enum.any?(replies, &(&1.id == reply.id)),
          do:
            put_request(socket, %{
              request
              | replies: Enum.map(replies, &if(&1.id == reply.id, do: reply, else: &1))
            }),
          else: stream_insert(socket, :messages, reply)

      nil ->
        stream_insert(socket, :messages, reply)
    end
  end

  defp redraw(socket, row), do: stream_insert(socket, :messages, row)

  # The outcome of the reply that resolved a request, read among the rows
  # shown or, past them, by its id; nil while it is pending, or when that
  # reply cannot be read.
  defp resolved(%{status: "answered", resolved_by: id}, rows, ctx) when is_binary(id) do
    case Map.fetch(rows, id) do
      {:ok, reply} ->
        reply.outcome

      :error ->
        case Threads.get_message(Sanctum.Context.actor(ctx), id) do
          {:ok, reply} -> reply.outcome
          {:error, _unread} -> nil
        end
    end
  end

  defp resolved(_request, _rows, _ctx), do: nil

  # The request `id` as the store holds its resolution: pending, or
  # answered by the reply it names as its resolver, with that reply's
  # outcome. An announcement names a request; the card takes what the
  # store holds, never the announcement's word. A request that cannot be
  # read answers nil, and the card keeps what it shows.
  defp stored_resolution(ctx, id) do
    actor = Sanctum.Context.actor(ctx)

    case Threads.get_message(actor, id) do
      {:ok, %{status: "answered", resolved_by: by} = request} when is_binary(by) ->
        %{status: "answered", resolved_by: by, outcome: resolved(request, %{}, ctx)}

      {:ok, %{status: status}} ->
        %{status: status, resolved_by: nil, outcome: nil}

      {:error, _unread} ->
        nil
    end
  end

  defp as_stored(request, ctx) do
    case stored_resolution(ctx, request.id) do
      %{} = held -> Map.merge(request, held)
      nil -> request
    end
  end

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
    post = post(row)
    if post.attachments != [] or post.links != [], do: post
  end

  defp result(_row), do: nil

  # A post of Aqua's as a host draws it.
  defp post(row) do
    %{
      id: row.id,
      seq: row.seq,
      content: row.content,
      attachments: attachments(row),
      links: Threads.payload(row)["links"] || []
    }
  end

  # An answer of Aqua's: a post its soul wrote, neither a request to a
  # crew member nor a reply from one.
  defp answer?(%{kind: "text", author: @agent_author, sent_by: sent_by} = row),
    do: Prima.AgentRef.soul?(sent_by) and is_nil(crew(row))

  defp answer?(_row), do: false

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

  # The crew threads of the members the roster holds; a member taken out
  # of the crew keeps its thread, unlisted.
  defp standing(children, roster) do
    names = MapSet.new(roster, & &1["name"])
    Enum.filter(children, &MapSet.member?(names, &1.agent))
  end

  # The thread a request's member works it in: its newest under this room,
  # the one a delivery makes or finds standing.
  defp member_thread(children, %{addressee: member}),
    do: children |> Enum.filter(&(&1.agent == member)) |> List.last()

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

  # A press of a card's choice is the person's answer to Aqua: the row and
  # the index are all the send names of it, and the server reads the
  # question again and says whether it is still open (`Aqua.Choices`). The
  # label goes as the line's text only because a send carries one.
  def handle_event("choose", %{"row" => row_id, "index" => index}, socket) do
    with %{id: thread_id} <- socket.assigns.thread,
         %{card: %{choices: choices}} <- socket.assigns.choices[row_id],
         {at, ""} <- Integer.parse(to_string(index)),
         label when is_binary(label) <- Enum.at(choices, at) do
      args = %{
        "thread" => thread_id,
        "message" => label,
        "choice" => %{"row" => row_id, "index" => at},
        "client_id" => Prima.UUID7.generate_id("snd")
      }

      case PrismWeb.Ops.call_tool(socket.assigns.context, "thread/send", args) do
        {:ok, answer} ->
          {:noreply, socket |> reread_choices() |> joined(answer[:thread])}

        {:error, reason} ->
          {:noreply,
           socket
           |> reread_choices()
           |> put_flash(:error, PrismWeb.Ops.error_message(reason))}
      end
    else
      _ -> {:noreply, socket}
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

  # The person's delete of the thread shown, and with a room the crew
  # threads under it (`thread.delete`), asked first by the menu's
  # question. The tool refuses a thread whose turn still runs, so work the
  # pane sees running is the person's stop first (`thread.stop`). The
  # removal reaches every screen as the person's list announces it, and
  # each host leaves the thread there, this one included; this host is
  # also told that the deletion was its person's own here.
  def handle_event("delete", _params, %{assigns: %{thread: %{id: id}}} = socket) do
    stopped =
      if socket.assigns.running,
        do: PrismWeb.Ops.call_tool(socket, "thread/stop", %{"thread" => id}),
        else: {:ok, :idle}

    with {:ok, _} <- stopped,
         {:ok, _} <- PrismWeb.Ops.call_tool(socket, "thread/delete", %{"thread" => id}) do
      tell_host(socket, {:deleted, id})
      {:noreply, socket}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete it: #{error_message(reason)}")}
    end
  end

  def handle_event("delete", _params, socket), do: {:noreply, socket}

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

  # A scroll a turn proposed, saved from the person's own session through
  # the action the Scrolls editor saves with: exactly the name, description
  # and body the card shows, read again from the row, and what the
  # proposal was made against, which the action holds the write to.
  def handle_event("save_scroll", %{"id" => id}, socket) do
    with %{id: thread_id} <- socket.assigns.thread,
         ctx = socket.assigns.context,
         {:ok, %{thread_id: ^thread_id} = row} <-
           Threads.get_message(Sanctum.Context.actor(ctx), id),
         %{"description" => _} = proposal <- proposal(row) do
      {action, against} = save_action(ctx, proposal)

      args = %{
        "action" => action,
        "name" => proposal["name"],
        "description" => proposal["description"],
        "content" => proposal["content"],
        "against" => against
      }

      # A proposal that makes a new pack is saved create-only, as the
      # Scrolls page's New pack is: refused when the pack is there.
      args = if proposal["new_pack"] == true, do: Map.put(args, "new_pack", true), else: args

      status =
        case call_tool(ctx, "aqua", args) do
          {:ok, _saved} -> :saved
          {:error, reason} -> {:refused, error_message(reason)}
        end

      {:noreply,
       socket
       |> assign(:proposals, Map.put(socket.assigns.proposals, id, status))
       |> stream_insert(:messages, row)}
    else
      _not_a_proposal -> {:noreply, socket}
    end
  end

  # A file a turn proposed beside a scroll, saved from the person's own
  # session: keep the proposal on this row as its card showed it. The page
  # sends the row and the digest it rendered, and the action writes the
  # row's bytes only while they are that digest, so a row changed after
  # the card was drawn is not saved by the old card.
  def handle_event("save_file", %{"id" => id, "sha256" => sha256}, socket) do
    with %{id: thread_id} <- socket.assigns.thread,
         ctx = socket.assigns.context,
         {:ok, %{thread_id: ^thread_id} = row} <-
           Threads.get_message(Sanctum.Context.actor(ctx), id),
         true <- file_proposal?(row) do
      status =
        case call_tool(ctx, "aqua", %{
               "action" => "skill_file",
               "proposal" => id,
               "sha256" => sha256
             }) do
          {:ok, _saved} -> :saved
          {:error, reason} -> {:refused, error_message(reason)}
        end

      {:noreply,
       socket
       |> assign(:proposals, Map.put(socket.assigns.proposals, id, status))
       |> stream_insert(:messages, row)}
    else
      _not_a_file_proposal -> {:noreply, socket}
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

  # The crew member's thread shown was deleted and its room stands: the
  # host opens the room, whichever host it is. A room deleted with it is
  # its host's to leave.
  def handle_info(
        %ThreadListed{kind: :removed, id: id},
        %{assigns: %{thread: %{id: id, kind: "crew", parent_id: room}}} = socket
      ) do
    if thread_of(socket.assigns.context, room), do: tell_host(socket, {:open_thread, room})
    {:noreply, socket}
  end

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
    if answer?(row), do: tell_host(socket, {:answer, row.thread_id, post(row)})
    socket = reread_choices(socket)
    {row, socket} = hold_choice(socket, row)

    socket
    |> hold_card(row)
    |> then(&if(drawn?(row), do: upsert_message(&1, row), else: &1))
    |> assign(:partials, Aqua.stream_landed(socket.assigns.partials, row))
    |> assign(:turn_replied, socket.assigns.turn_replied or replied?(row, socket))
  end

  # A request heard again once it is delivered keeps what a reply already
  # left it, and the room reads its crew threads again, the member's now
  # among them.
  defp handle_thread_event(socket, :request, row) do
    replies = get_in(socket.assigns.requests, [row.id, :replies]) || []

    request =
      row |> Map.merge(%{replies: replies, outcome: nil}) |> as_stored(socket.assigns.context)

    socket |> read_children() |> put_request(request) |> reread_choices()
  end

  # A reply answers every request its payload names, as its write did, and
  # is shown beneath the one it replies to when that one is shown.
  defp handle_thread_event(socket, :reply, row) do
    {row, socket} = socket |> reread_choices() |> hold_choice(row)
    requests = socket.assigns.requests
    answered = Enum.uniq([row.reply_to | List.wrap(Threads.payload(row)["answers"])])

    socket =
      for id <- answered, %{} = request <- [requests[id]], reduce: socket do
        acc -> put_request(acc, answered_by(request, row, acc.assigns.context))
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
    |> reread_choices()
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

  # A request a reply names reads as the store holds its resolution: the
  # outcome of the reply the store names as its resolver, whichever reply
  # was announced; a reply to it stands beneath it.
  defp answered_by(request, reply, ctx) do
    request = as_stored(request, ctx)

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
        |> assign(:grant_retry, retry_of(account, message_id))

      {:error, reason} ->
        put_flash(socket, :error, "Cannot ask for this grant: #{error_message(reason)}")
    end
  end

  # What the pane offers once the grant is given: a launch's account, or
  # Aqua's grant for a refused message, offers that message again.
  defp retry_of(nil, nil), do: nil
  defp retry_of(nil, message_id), do: {:grant, message_id}
  defp retry_of(_account, message_id), do: {:account, message_id}

  defp account_opts(%{name: name} = account) when is_binary(name),
    do: [account: %{name: name, dep: nil, need: Map.get(account, :need)}]

  defp account_opts(_none), do: []

  # The text of the ended turn's own message, read by its id from this
  # thread: never a scan of the rows around it, which may hold a line
  # queued while the turn ran, or not reach back to it at all. It is
  # offered as every stored line is (`Aqua.again_text/2`): this person's
  # own words with no files; its thread's line says to send it again.
  defp retry_text(%{assigns: %{thread: %{id: thread_id}, context: ctx}}, message_id)
       when is_binary(message_id) do
    case Threads.get_message(Sanctum.Context.actor(ctx), message_id) do
      {:ok, %{thread_id: ^thread_id} = row} -> Aqua.again_text(row, ctx.user_id)
      _none -> nil
    end
  end

  defp retry_text(_socket, _message_id), do: nil

  # A grant opened for a launch's account, or for a message refused for
  # Aqua's grant, offers its turn's message again, as a new
  # turn: that turn ended, so nothing is cut, and with no message of that
  # turn to offer the pane only says so. Any other grant cuts the running
  # turn for the new consent.
  defp after_grant(%{assigns: %{grant_retry: {kind, message_id}}} = socket) do
    socket = assign(socket, :grant_retry, nil)

    case retry_text(socket, message_id) do
      text when is_binary(text) ->
        socket
        |> assign(:restart_prompt, text)
        |> assign(:restart_note, retry_note(kind))
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

  defp retry_note(:account),
    do: "The account is granted — send that message again, as a new turn?"

  defp retry_note(:grant), do: "Granted — send that message again, as a new turn?"

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
  # so. A soul on a program the athanor has no row of, or whose row is
  # disabled or no brain's, says which, as a turn on it is refused
  # (`Prima.Refusal`), naming whose brain it is: the crew member Aqua runs
  # on, whose card installs or opens it. Aqua whose crew member does not
  # stand, or that names none, says so in the sentence its card says and
  # its turn is refused with (`aqua.list`'s `member_refusal`), never as
  # a model to connect. A soul whose file the list refuses, one that
  # still names a brain of its own among them, says the sentence the
  # list refuses it with, which the Aqua page says too.
  # An agents list that could not be read is not a room with no model.
  defp model_ready(_ctx, :unread), do: :agents_unavailable
  defp model_ready(_ctx, {:refused, sentence}), do: {:unseated, sentence}

  defp model_ready(ctx, agents) do
    case Enum.find_value(agents, & &1["member_refusal"]) do
      sentence when is_binary(sentence) -> {:unseated, sentence}
      nil -> model_status_ready(ctx, agents)
    end
  end

  defp model_status_ready(ctx, agents) do
    case Aqua.model_status(ctx, agents) do
      empty when map_size(empty) == 0 ->
        :no_model

      statuses ->
        case unready_model(Map.values(statuses)) do
          {:program, state} -> {:program, state, Enum.find_value(agents, & &1["member_title"])}
          ready -> ready
        end
    end
  end

  # The athanor's soul with its model, read through the `aqua` tool's list
  # with detail, as the Aqua page's agents panel reads it: the roster names
  # who can be addressed and carries no model, so a model's status read
  # from it would always be none. Whether Aqua can answer is the soul's to
  # say, so the crew is left out but for the title of the member it runs
  # on. The soul is put in the roster's string-keyed projection, its
  # catalyst or the name of its program, which `Aqua.model_status/2`
  # reads, with the sentence the list says while its member does not
  # stand. A list that refuses the soul's file is `{:refused, sentence}`,
  # in the sentence that says what to change; one that cannot be read is
  # `:unread`, never no agents.
  defp agents(ctx) do
    soul = Compendium.agent_soul_type()

    case PrismWeb.Ops.call_tool(ctx, "aqua", %{"action" => "list", "detail" => true}) do
      {:ok, %{guides: guides}} when is_list(guides) ->
        for %{type: ^soul} = guide <- guides do
          %{
            "name" => guide.name,
            "type" => guide.type,
            "catalyst_ref" => guide[:catalyst_ref],
            "model" => guide[:model],
            "program" => guide[:program],
            "member_refusal" => guide[:member_refusal],
            "member_title" => Enum.find_value(guides, &(&1.name == guide[:member] && &1[:title]))
          }
        end

      {:error, {:conflict, sentence}} when is_binary(sentence) ->
        {:refused, sentence}

      _unread ->
        :unread
    end
  end

  # The crew's grant's state as its refusal row names it (`Prima.Refusal`).
  defp grant_row(:consent_absent), do: :ungranted
  defp grant_row(:consent_revoked), do: :grant_revoked
  defp grant_row(:consent_stale), do: :agent_changed

  defp unready_model(statuses) do
    cond do
      Enum.any?(statuses, &match?({:ready, _}, &1)) -> :ready
      Enum.any?(statuses, &match?({:consent_absent, _}, &1)) -> :consent_absent
      Enum.any?(statuses, &match?({:consent_revoked, _}, &1)) -> :consent_revoked
      Enum.any?(statuses, &match?({:consent_stale, _}, &1)) -> :consent_stale
      Enum.any?(statuses, &match?({:consent_damaged, _}, &1)) -> :consent_damaged
      Enum.any?(statuses, &match?({:consent_unavailable, _}, &1)) -> :consent_unavailable
      Enum.any?(statuses, &match?({:model_unavailable, _}, &1)) -> :model_unavailable
      Enum.any?(statuses, &match?({:needs_grant, _}, &1)) -> :needs_grant
      Enum.any?(statuses, &match?({:needs_model, _}, &1)) -> :no_model
      program = Enum.find_value(statuses, &program_state/1) -> program
      true -> :no_key
    end
  end

  defp program_state({state, _program})
       when state in [:program_missing, :program_disabled, :program_unfit],
       do: {:program, state}

  defp program_state(_status), do: nil

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
            {asking(@members, @turn_user, @context)}
          </span>
        </div>
      </header>

      <%!-- The thread's menu: the model override, the soul or crew member and
            the thread's usage. Its host's toggle shows it, so its `hidden`
            is the browser's to keep; the panel's hook closes it, and for a
            host that names its toggle a press away and Escape do. --%>
      <div
        id={@dom <> "-menu"}
        hidden
        phx-mounted={JS.ignore_attributes(["hidden"])}
        phx-click-away={@menu_toggle && close_menu(@dom, @menu_toggle)}
        phx-window-keydown={@menu_toggle && close_menu(@dom, @menu_toggle, :focus)}
        phx-key={@menu_toggle && "Escape"}
        role="group"
        aria-label="This thread"
        class="aqua-panel-menu"
      >
        <div class="aqua-panel-menu-row">
          <span>Model</span>
          <%= cond do %>
            <% @models_loaded and @models_by_provider != %{} -> %>
              <.model_override
                label={model_label(@assistant, @token_usage)}
                models_by_provider={@models_by_provider}
                model_override={@model_override}
                class="min-w-0 max-w-[10rem] cursor-pointer truncate rounded-[7px] border border-border-default bg-surface-base px-1.5 py-0.5 font-mono text-xs text-text-primary focus:border-border-focus focus:outline-none"
              />
            <% @models_loaded -> %>
              <span class="truncate font-mono">
                {model_label(@assistant, @token_usage)}
              </span>
            <% true -> %>
              <span>Reading the models…</span>
          <% end %>
        </div>
        <div class="aqua-panel-menu-row" title="Aqua or the crew member this thread is on">
          <span>Aqua or crew member</span>
          <span class="truncate">
            {if @roster == [],
              do: "No assistant here",
              else: assistant_label(current_assistant(@assistant, @roster))}
          </span>
        </div>
        <div :if={@thread} class="aqua-panel-menu-row">
          <span
            :if={room?(@thread) and @thread.archived_at}
            title="New work here takes it out of the archive"
          >
            Archived
          </span>
          <button
            :if={room?(@thread) and is_nil(@thread.archived_at)}
            id={@dom <> "-archive"}
            type="button"
            phx-click="archive"
            title="Your list shows it under Archived; nothing else about it changes"
            class="rounded px-1.5 py-0.5 text-text-secondary hover:bg-surface-base hover:text-text-primary"
          >
            Archive
          </button>
          <button
            id={@dom <> "-delete"}
            type="button"
            phx-click="delete"
            data-confirm={delete_question(@children, @running)}
            title="Its posts, files and turns are removed"
            class="rounded px-1.5 py-0.5 text-text-secondary hover:bg-surface-base hover:text-text-primary"
          >
            Delete
          </button>
        </div>
        <div class="aqua-panel-menu-row">
          <span>Tokens</span>
          <span class="font-mono">
            {tokens(@token_usage)}
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
        :if={(listed = standing(@children, @roster)) != []}
        id={@dom <> "-crew"}
        aria-label="Crew threads"
        class="flex flex-wrap items-center gap-1.5 border-b border-gray-800 px-4 py-1.5 text-xs text-gray-500"
      >
        <span>Crew</span>
        <button
          :for={child <- listed}
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
              <% match?({:unseated, _}, @model_ready) -> %>
                <span data-test="model-unseated">{elem(@model_ready, 1)}</span>
                <.link
                  navigate={PrismWeb.Focus.path(@athanor, "/aqua?setup=1")}
                  data-test="model-connect"
                  class="text-blue-400 hover:underline"
                >
                  Open your Aqua page.
                </.link>
              <% @model_ready in [:no_model, :no_key] -> %>
                <span>{athanor_label(@athanor, @context)} has no model yet.</span>
                <.link
                  navigate={PrismWeb.Focus.path(@athanor, "/aqua?setup=1")}
                  data-test="model-connect"
                  class="text-blue-400 hover:underline"
                >
                  Connect one on your Aqua page.
                </.link>
              <% match?({:program, _, _}, @model_ready) -> %>
                <span data-test="model-program">
                  {Prima.Refusal.message(
                    {:crew_unready, elem(@model_ready, 2) || athanor_label(@athanor, @context),
                     elem(@model_ready, 1)}
                  )}
                </span>
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
                  {Prima.Refusal.grant_action(:ungranted)}
                </.link>
              <% @model_ready in [:consent_absent, :consent_revoked, :consent_stale] -> %>
                <%!-- The crew's grant was never given, was revoked by its
                     person, or no longer covers what the crew may use:
                     granting it on the Aqua page is all it needs, never a
                     model to connect. --%>
                <span data-test="model-consent">
                  {PrismWeb.AquaLive.AgentsComponent.grant_sentence(@model_ready)}
                </span>
                <.link
                  navigate={PrismWeb.Focus.path(@athanor, "/aqua")}
                  class="text-blue-400 hover:underline"
                >
                  {Prima.Refusal.grant_action(grant_row(@model_ready))}
                </.link>
              <% @model_ready in [:consent_damaged, :consent_unavailable] -> %>
                <%!-- A consent that exists but is damaged, or could not be read,
                     is no model to connect: it is said as such. --%>
                <span data-test="model-consent">
                  {PrismWeb.AquaLive.AgentsComponent.grant_sentence(@model_ready)}
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
                    author={"#{speaker(msg, @members, @context)} asked #{msg.addressee} · #{request_state(msg)}"}
                    attachments={attachments(msg)}
                    attachment_href={&attachment_path(@athanor_route, msg.id, &1)}
                    links={Threads.payload(msg)["links"] || []}
                  />
                  <button
                    :if={child = member_thread(@children, msg)}
                    id={@dom <> "-msg-" <> msg.id <> "-open"}
                    type="button"
                    phx-click="open_thread"
                    phx-value-id={child.id}
                    class="min-h-6 px-1 text-xs text-blue-400 hover:text-blue-300"
                  >
                    Open {msg.addressee}'s thread
                  </button>
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
                <% file_proposal?(msg) -> %>
                  <.file_proposal
                    id={@dom <> "-proposal-" <> msg.id}
                    msg={msg}
                    status={@proposals[msg.id]}
                  />
                <% proposal?(msg) -> %>
                  <.scroll_proposal
                    id={@dom <> "-proposal-" <> msg.id}
                    msg={msg}
                    status={@proposals[msg.id]}
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
                      content={shown_content(msg)}
                      author={author_label(msg, @members, @context)}
                      attachments={attachments(msg)}
                      attachment_href={&attachment_path(@athanor_route, msg.id, &1)}
                      links={Threads.payload(msg)["links"] || []}
                    />
                    <.choices_card
                      :if={Map.get(msg, :card)}
                      id={@dom <> "-choices-" <> msg.id}
                      card={msg.card}
                      athanor_route={@athanor_route}
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
            <.upload_refusal upload={@uploads.attachments} entry={entry} />
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
          <.upload_refusal upload={@uploads.attachments} />
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

  attr :label, :string, required: true
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
        {@label}
      </option>
      <%= for {provider, models} <- @models_by_provider, models != [] do %>
        <optgroup label={provider}>
          <option :for={m <- models} value={m} selected={@model_override == m}>{m}</option>
        </optgroup>
      <% end %>
    </select>
    """
  end

  # The model the turn ran when its usage names it (a program's), else the
  # assistant's own, else the default.
  defp model_label(_assistant, %{models: [_ | _] = models}), do: Enum.join(models, ", ")
  defp model_label(assistant, _usage), do: (assistant && assistant["model"]) || "default"

  # The turn's tokens as they were told: unknown when the program could
  # count none of them, and said to be partial when it counted only some.
  defp tokens(%{accounting: :unavailable}), do: "unknown"

  defp tokens(%{accounting: :partial} = usage),
    do: "#{usage.input} in · #{usage.output} out, partial"

  defp tokens(usage), do: "#{usage.input} in · #{usage.output} out"

  # The status line is drawn only while it says something.
  defp status?(assigns) do
    assigns.preparing? or assigns.roster == [] or assigns.queued > 0 or
      (assigns.running and assigns.turn_user != nil)
  end

  attr :id, :string, required: true
  attr :msg, :map, required: true
  attr :status, :any, default: nil

  # A file a turn proposed beside a scroll: its path, its size and the
  # digest of the text shown, what it replaces, the text whole, and the two
  # things true of a script, each by its one rule: the file will be
  # executable when it begins with `#!` (the own-pack rule), and a program
  # may run it when it is a script as the pack sheet counts one, said with
  # the sheet's sentence. Save file sends the digest of what it shows.
  defp file_proposal(assigns) do
    proposal = proposal(assigns.msg)

    assigns =
      assigns
      |> assign(:proposal, proposal)
      |> assign(:sha256, Prima.Digest.sha256(proposal["content"]))
      |> assign(:trust, PrismWeb.AquaLive.ScrollsComponent.trust())

    ~H"""
    <div id={@id} class="rounded border border-gray-800 bg-gray-950 p-3 space-y-1 text-xs">
      <p class="text-gray-400">
        {if @proposal["against"] == "none",
          do:
            "Aqua proposes a new file beside the scroll #{@proposal["name"]}. Nothing is kept until you save it.",
          else:
            "Aqua proposes a change to a file beside the scroll #{@proposal["name"]}. Nothing changes until you save it."}
      </p>
      <p id={@id <> "-path"} class="font-mono text-gray-200">{@proposal["path"]}</p>
      <p id={@id <> "-size"} class="text-gray-400">
        {byte_size(@proposal["content"])} bytes, {@sha256}
      </p>
      <p :if={@proposal["against"] != "none"} id={@id <> "-replaces"} class="text-gray-400">
        It replaces the file as Aqua read it: {@proposal["against_size"]} bytes, {@proposal[
          "against"
        ]}.
      </p>
      <p :if={@proposal["runs"] == true} id={@id <> "-executable"} class="text-amber-200">
        It begins with #!, so it will be executable.
      </p>
      <div :if={@proposal["script"] == true} id={@id <> "-script"} class="space-y-1 text-amber-200">
        <p>It is among the scroll's scripts: your programs may run it in their sessions.</p>
        <p>{@trust}</p>
      </div>
      <pre
        id={@id <> "-content"}
        class="whitespace-pre-wrap font-mono text-gray-300 max-h-64 overflow-y-auto"
      >{@proposal["content"]}</pre>
      <div class="flex flex-wrap items-center justify-end gap-2">
        <span :if={@status == :saved} id={@id <> "-saved"} class="text-green-400">
          Saved beside the scroll.
        </span>
        <span :if={match?({:refused, _}, @status)} id={@id <> "-refused"} class="text-red-300">
          {elem(@status, 1)}
        </span>
        <button
          :if={@status != :saved}
          id={@id <> "-save"}
          type="button"
          phx-click="save_file"
          phx-value-id={@msg.id}
          phx-value-sha256={@sha256}
          class="min-h-6 rounded bg-blue-600 hover:bg-blue-500 px-3 py-1 font-medium text-white"
        >
          Save file
        </button>
      </div>
    </div>
    """
  end

  # A scroll a turn proposed: exactly the name, description and body that
  # Save as scroll writes, and what came of a save.
  defp scroll_proposal(assigns) do
    assigns = assign(assigns, :proposal, proposal(assigns.msg))

    ~H"""
    <div id={@id} class="rounded border border-gray-800 bg-gray-950 p-3 space-y-1 text-xs">
      <p class="text-gray-400">
        {cond do
          @proposal["new_pack"] == true ->
            "Aqua proposes a new pack with this scroll as its first. Nothing is kept until you save it."

          @proposal["against"] == "none" ->
            "Aqua proposes a new scroll. Nothing is kept until you save it."

          true ->
            "Aqua proposes a change to a scroll. Nothing changes until you save it."
        end}
      </p>
      <p id={@id <> "-name"} class="font-mono text-gray-200">{@proposal["name"]}</p>
      <p id={@id <> "-description"} class="text-gray-300">{@proposal["description"]}</p>
      <pre
        id={@id <> "-content"}
        class="whitespace-pre-wrap font-mono text-gray-300 max-h-64 overflow-y-auto"
      >{@proposal["content"]}</pre>
      <div class="flex flex-wrap items-center justify-end gap-2">
        <span :if={@status == :saved} id={@id <> "-saved"} class="text-green-400">
          Saved as a scroll.
        </span>
        <span :if={match?({:refused, _}, @status)} id={@id <> "-refused"} class="text-red-300">
          {elem(@status, 1)}
        </span>
        <button
          :if={@status != :saved}
          id={@id <> "-save"}
          type="button"
          phx-click="save_scroll"
          phx-value-id={@msg.id}
          class="min-h-6 rounded bg-blue-600 hover:bg-blue-500 px-3 py-1 font-medium text-white"
        >
          Save as scroll
        </button>
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
        content={shown_content(@reply)}
        author={"#{agent_name(@reply.sent_by)} · #{outcome_words(@reply.outcome)}"}
        attachments={attachments(@reply)}
        attachment_href={&attachment_path(@athanor_route, @reply.id, &1)}
        links={@payload["links"] || []}
      />
      <.choices_card
        :if={Map.get(@reply, :card)}
        id={@dom <> "-choices-" <> @reply.id}
        card={@reply.card}
        athanor_route={@athanor_route}
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

  attr :id, :string, required: true
  attr :card, :map, required: true
  attr :athanor_route, :any, required: true

  # A question's choices, one button each, pressable while the card is
  # open and greyed once it is not; and its file, opened while Files has
  # it.
  defp choices_card(assigns) do
    ~H"""
    <div id={@id} data-open={to_string(@card.open?)} class="mt-1 space-y-1 px-1 text-xs">
      <div class="flex flex-wrap items-center gap-2">
        <button
          :for={{label, at} <- Enum.with_index(@card.choices)}
          id={@id <> "-" <> Integer.to_string(at)}
          type="button"
          phx-click="choose"
          phx-value-row={@card.row}
          phx-value-index={at}
          disabled={not @card.open?}
          class="min-h-6 rounded bg-blue-600 hover:bg-blue-500 px-3 py-1 font-medium text-white disabled:cursor-not-allowed disabled:opacity-40"
        >
          {label}
        </button>
      </div>
      <div :if={@card.file} id={@id <> "-file"} class="flex flex-wrap items-center gap-2">
        <span class="font-mono text-gray-400">{@card.file}</span>
        <%= case @card.file_state do %>
          <% :present -> %>
            <a
              id={@id <> "-open"}
              href={file_href(@athanor_route, @card.file)}
              target="_blank"
              rel="noopener"
              class="min-h-6 text-blue-400 hover:text-blue-300"
            >
              Open
            </a>
          <% :missing -> %>
            <span id={@id <> "-missing"} class="text-gray-500">This file is not in Files</span>
          <% _unavailable -> %>
            <span id={@id <> "-unread"} class="text-gray-500">
              Files could not be read just now
            </span>
        <% end %>
      </div>
    </div>
    """
  end

  # A card's reply shows its words before the block and its question; a
  # press shows what was chosen; any other row its text.
  defp shown_content(%{card: %{prose: prose, question: question}}),
    do: Enum.join(Enum.reject([prose, question], &(&1 == "")), "\n\n")

  defp shown_content(%{kind: "text", sent_by: "person"} = row) do
    case Threads.payload(row)["choice"] do
      %{"label" => label} when is_binary(label) -> "You chose «#{label}»"
      _ -> row.content
    end
  end

  defp shown_content(row), do: row.content

  # A file of the athanor's as the download route serves it, which shows
  # a text file in the browser.
  defp file_href(route, path) do
    encoded =
      path
      |> String.split("/")
      |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)

    PrismWeb.Focus.path(route, "/files/download/" <> encoded)
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

  # How a request stands as a person reads it: pending, then the outcome
  # of the reply that resolved it; answered, when that reply cannot be
  # read.
  defp request_state(%{outcome: outcome}) when is_binary(outcome), do: outcome_words(outcome)
  defp request_state(%{status: "answered"}), do: "answered"
  defp request_state(_pending), do: "pending"

  # A crew job's outcome (`Prima.OutboxRecord.reply_outcomes/0`) as a
  # person reads it.
  defp outcome_words("uncertain"), do: "outcome unknown"
  defp outcome_words(outcome), do: outcome

  # The menu closed for a host that names its toggle `toggle`: the toggle
  # back in reach and no longer expanded, and, on Escape, focus on it
  # again. The focus names the toggle while it still reads expanded, so
  # an Escape while the menu is closed moves nothing.
  defp close_menu(dom, toggle, focus \\ nil) do
    toggle = "#" <> toggle
    js = JS.remove_attribute("inert", to: toggle)
    js = if focus, do: JS.focus(js, to: toggle <> ~s([aria-expanded="true"])), else: js

    js
    |> JS.set_attribute({"aria-expanded", "false"}, to: toggle)
    |> JS.set_attribute({"hidden", ""}, to: "#" <> dom <> "-menu")
  end

  # What the menu's Delete asks before anything goes: what a delete
  # removes (`Arca.ThreadStorage.delete/3`) and what it leaves, the crew
  # threads under a room named, and the stop the pane makes first when it
  # sees work running.
  defp delete_question(children, running) do
    stops = if running, do: " The work running in it stops.", else: ""

    {under, of} =
      case Enum.map(children, &"#{&1.agent}'s") do
        [] -> {"", "it"}
        [one] -> {", with #{one} thread under it", "them"}
        many -> {", with #{and_list(many)} threads under it", "them"}
      end

    "Delete this thread?#{stops} Its posts, files and turns go#{under}, " <>
      "and any record a program keeps of #{of}. The records of what ran stay on the " <>
      "Executions page and in the logs, as do a program's sign-in and every other thread. " <>
      "This cannot be undone."
  end

  defp and_list(names) do
    {init, [last]} = Enum.split(names, -1)
    Enum.join(init, ", ") <> " and " <> last
  end

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

  # The one rule of what the pane draws, as a row lands and when the thread
  # is opened: a post, a line of the server's to the thread's Aqua
  # (`Aqua.Nudge`), which is drawn as the server's and is no post, the
  # line a stopped turn leaves (`turn_aborted`), and a scroll a turn
  # proposed, drawn as a card under its turn. What else a turn writes for
  # itself, its calls, their results and its compaction, is none.
  defp drawn?(row), do: row.kind in drawn_kinds() or proposal?(row)

  # A model's call's result that proposes a scroll or a file beside one
  # (`Aqua.Loop`): what Save would write and what it was made against. A
  # page proposes nothing: only a turn's own call does.
  defp proposal?(row), do: proposal(row) != nil

  defp file_proposal?(row), do: match?(%{"path" => _}, proposal(row))

  defp proposal(%{kind: "tool_result"} = row) do
    case Threads.payload(row)["proposal"] do
      %{"name" => name, "path" => path, "content" => content, "against" => _} = proposal
      when is_binary(name) and is_binary(path) and is_binary(content) ->
        proposal

      %{"name" => name, "description" => _, "content" => _, "against" => _} = proposal ->
        proposal
        |> Map.put("name", full_scroll_name(name))
        |> Map.put("bare", is_binary(name) and not String.contains?(name, ":"))

      _none ->
        nil
    end
  end

  defp proposal(_row), do: nil

  # What Save writes. A card made against none creates its scroll. A card
  # made before scrolls had packs, an update of a scroll the release did
  # not move into `mine` (an unedited shipped one, which `cyfr` holds),
  # carries the whole scroll as it would be stored, so Save makes it in
  # `mine`, new. Any other updates the scroll it was made against.
  defp save_action(_ctx, %{"against" => "none"}), do: {"skill_create", "none"}

  defp save_action(ctx, %{"bare" => true, "name" => name, "against" => against}) do
    case Compendium.skill(ctx, name) do
      {:error, :not_found} -> {"skill_create", "none"}
      _held -> {"skill_update", against}
    end
  end

  defp save_action(_ctx, %{"against" => against}), do: {"skill_update", against}

  # A card proposed before scrolls had packs names its scroll bare: such a
  # scroll is the person's first pack's, `mine`, where the release moved
  # every scroll an athanor made.
  defp full_scroll_name(name) when is_binary(name) do
    if String.contains?(name, ":"), do: name, else: Compendium.first_pack() <> ":" <> name
  end

  defp full_scroll_name(name), do: name

  defp drawn_kinds, do: Threads.post_kinds() ++ ["nudge", "turn_aborted"]

  defp role_of(%{kind: "error"}), do: "error"
  # The server's lines: a note, a nudge, and the line a stopped turn leaves.
  defp role_of(%{kind: kind}) when kind in ["system", "nudge", "turn_aborted"], do: "system"
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

  # Who the running turn is for, with the verb that agrees with them: the
  # person looking reads as "You".
  defp asking(_members, user_id, %{user_id: user_id}), do: "You are asking…"
  defp asking(members, user_id, ctx), do: "#{label_for(members, user_id, ctx)} is asking…"

  defp role_align("user"), do: "items-end"
  defp role_align(_), do: "items-start"

  defp role_class("user"), do: "bg-indigo-600 text-white"
  defp role_class("error"), do: "bg-red-900/40 text-red-300 border border-red-800"
  defp role_class("system"), do: "bg-gray-800/60 text-gray-400 border border-gray-800 italic"
  defp role_class("server"), do: "bg-sky-950/50 text-sky-100 border border-sky-900/60"
  defp role_class(_), do: "bg-gray-800 text-gray-200"
end
