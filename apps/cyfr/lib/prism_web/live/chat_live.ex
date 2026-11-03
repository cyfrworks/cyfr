# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ChatLive do
  @moduledoc """
  The chat — the person's own threads with AQUA and the threads they share
  with people, at `/chat`.

  The rail is the person's contact list: their athanor with its threads,
  then the threads they share with people — their pairs,
  each shown by the other person's name, and their shared threads by
  title (`shared_thread.list`). Opening an athanor's thread opens it in
  place as `PrismWeb.ThreadPaneLive`, a nested LiveView with a focused
  context of its own, so nothing here depends on which athanor the session
  happens to default to; opening a shared thread opens
  `PrismWeb.SharedThreadLive`, which no athanor holds. This page governs
  itself through its address: `?a=<route>` names the athanor, `?c=<thread_id>` its thread
  (without it the athanor's most recent, or a fresh one started by the
  first message), and `?s=<thread>` a shared thread.

  A pair opens from the rail: click a person you share a thread with and
  the pair of the two of you is found or made (`shared_thread.pair`) and
  opened here. "New thread with people" makes a shared thread with a
  title (`shared_thread.create`) and adds the people named
  (`shared_thread.add`). The session's default athanor does not move.

  The page owns what is the page's: the selection, the lists, whether the
  athanor's threads are unfolded, the phone drawer, the say-aloud
  picker, the selected athanor's own notifications, and the system layer
  (`PrismWeb.SystemLayer`), where a grant the pane's turn needs is asked
  under the page's context. The pane owns the thread. The shared thread
  in view is announced (`PrismWeb.RoomFeed`) for the person's own AQUA
  beside the page.

  The athanor is read once per change to the SET of athanors — a seat
  gained or lost. A message on the open thread or a rename touches the one
  row it concerns. The shared
  threads are read again on each change told to the person
  (`Cyfr.Bus.SharedThreadChanged`).
  """

  use PrismWeb, :live_view

  @behaviour PrismWeb.SystemLayer.Hook
  on_mount PrismWeb.SystemLayer.Hook

  alias Phoenix.LiveView.JS

  alias Arca.ThreadStorage, as: Threads
  alias PrismWeb.SystemLayer
  alias Sanctum.Tenancy.Athanors

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Cyfr.Bus.subscribe_global(Cyfr.Bus.shared_threads(socket.assigns.context.user_id))

    {:ok,
     socket
     # The session's own athanor, as the mount found it: where the chat
     # opens when the address names none. The page's context moves with
     # the athanor it has open.
     |> assign(:session_athanor_id, socket.assigns.context.athanor_id)
     |> assign(:mine, personal_athanor(socket.assigns.context))
     |> assign(:room_feed, PrismWeb.RoomFeed.topic(socket.id))
     |> assign(:room, nil)
     |> assign(:page_title, "Chat")
     |> assign(:active_nav, "chat")
     |> assign(:loading?, true)
     |> assign(:athanors, [])
     |> assign(:people, [])
     |> assign(:expanded, MapSet.new())
     |> assign(:rail_open?, false)
     |> assign(:focus, nil)
     |> assign(:athanor_label, nil)
     |> assign(:threads, [])
     |> assign(:thread, nil)
     |> assign(:pane, nil)
     |> assign(:shared_threads, [])
     |> assign(:shared, nil)
     |> assign(:with_people?, false)
     |> assign(:aloud_for, nil)
     |> assign(:notified, nil)}
  end

  @doc "The chat's address for an athanor, and optionally one of its threads."
  @spec chat_path(String.t() | nil, String.t() | nil) :: String.t()
  def chat_path(route, thread_id \\ nil) do
    query =
      [a: route, c: thread_id]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    if query == [], do: "/chat", else: "/chat?" <> URI.encode_query(query)
  end

  @doc "The chat's address for a shared thread."
  @spec shared_path(String.t()) :: String.t()
  def shared_path(thread_id) when is_binary(thread_id),
    do: "/chat?" <> URI.encode_query(s: thread_id)

  # The address decides everything: which athanor (a member's own default
  # without `a`), then which thread. The athanor is entered through
  # `Context.focus/2` — membership checked, an archived one refused — and
  # handed to `CyfrWeb.ContextGuard`, which keeps it current: that focused
  # context is what the lists and the pane run under.
  #
  # A shared thread (`s`) is opened under the person's own seat in it; the
  # athanor the page has open, if any, stays as it was behind it.
  @impl true
  def handle_params(params, _uri, socket) do
    cond do
      not connected?(socket) -> {:noreply, socket}
      params["s"] not in [nil, ""] -> open_shared(socket, params["s"])
      true -> open(socket, params)
    end
  end

  defp open(socket, params) do
    ctx = socket.assigns.context
    athanors = Sanctum.Tenancy.list_athanors(ctx)

    with {:ok, focus, athanor} <-
           focus_on(ctx, socket.assigns.session_athanor_id, params["a"], athanors),
         {:ok, refocused} <- CyfrWeb.ContextGuard.refocus(socket, focus) do
      open_athanor(refocused, athanor, athanors, params["c"])
    else
      {:error, :no_seat} ->
        # No seat anywhere: nothing to open, and nothing to patch to.
        {:noreply,
         socket
         |> assign(:loading?, false)
         |> assign(:athanor, nil)
         |> assign(:focus, nil)
         |> assign(:thread, nil)
         |> assign(:athanors, [])
         |> assign(:people, [])}

      {:error, :unavailable} ->
        {:noreply,
         put_flash(socket, :error, "That athanor cannot be opened just now. Try again shortly.")}

      {:error, reason} when reason in [:unauthenticated, :not_standing] ->
        {:noreply, redirect(socket, to: "/login")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "That athanor cannot be opened: #{error_message(reason)}")
         |> push_navigate(to: chat_path(nil))}
    end
  end

  # A shared thread, read under the person's own seat: one they do not sit
  # in answers as a missing one. The athanor behind it stays as it was;
  # on a first load the rail is read here, since no athanor opened it.
  defp open_shared(socket, thread_id) do
    socket =
      if socket.assigns.loading?,
        do: build_rail(socket, Sanctum.Tenancy.list_athanors(socket.assigns.context)),
        else: socket

    case PrismWeb.Ops.call_tool(socket, "shared_thread/get", %{"thread" => thread_id}) do
      {:ok, %{status: "active"} = thread} ->
        shared = %{id: thread.id, kind: thread.kind, label: shared_label(thread)}

        {:noreply,
         socket
         |> assign(:loading?, false)
         |> unsubscribe_current()
         |> assign(:thread, nil)
         |> assign(:pane, nil)
         |> assign(:shared, shared)
         |> announce(PrismWeb.RoomFeed.room(shared.id, shared.label))}

      {:ok, _archived} ->
        {:noreply,
         socket
         |> put_flash(:error, "That thread has been archived.")
         |> push_patch(to: chat_path(nil))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "That thread cannot be opened: #{error_message(reason)}")
         |> push_patch(to: chat_path(nil))}
    end
  end

  # The athanor this page has open, as the context the guard keeps current;
  # nil while none is.
  defp focused(%{assigns: %{focus: nil}}), do: nil
  defp focused(%{assigns: %{context: ctx}}), do: ctx

  # The row as it is now. Used after subscribing, so what the page renders
  # is never older than the topic it is listening to.
  defp reread(%{id: id} = athanor) do
    case Athanors.get(id) do
      {:ok, fresh} -> fresh
      _ -> athanor
    end
  end

  defp open_athanor(socket, athanor, athanors, thread_id) do
    ctx = socket.assigns.context
    threads = athanor_threads(ctx)

    case pick(threads, thread_id) do
      {:ok, target} ->
        {:noreply,
         socket
         |> assign(:loading?, false)
         |> assign(:shared, nil)
         |> subscribe_athanor(athanor)
         |> assign(:focus, ctx)
         # Re-read after subscribing, not before: a fill that completed
         # between the two would otherwise leave the setup banner up until
         # someone reloaded.
         |> assign(:athanor, reread(athanor))
         |> assign(:athanor_route, Athanors.route_slug(athanor))
         |> assign(:athanor_label, athanor_label(athanor, socket.assigns.mine, ctx))
         |> assign(:threads, threads)
         |> update(:expanded, &MapSet.put(&1, athanor.id))
         |> select(target)
         |> sync_rail(athanors)}

      # The address named a thread this athanor does not hold: say so, and
      # open the athanor's own default rather than a blank pane.
      :unseen ->
        {:noreply,
         socket
         |> put_flash(:error, "That thread isn't in this athanor.")
         |> push_patch(to: chat_path(Athanors.route_slug(athanor)))}
    end
  end

  # No athanor named: the session's default, or — when that seat is gone —
  # the first athanor the person still holds one in. Never a patch back to
  # the default, which is how a lost seat would loop. A store that cannot
  # answer stops the walk as unavailable: it says nothing about a seat,
  # and read as "no athanor" it would show a person with seats an empty
  # page.
  defp focus_on(ctx, default_id, route, athanors) when route in [nil, ""] do
    default =
      case default_id && Athanors.get(default_id) do
        {:ok, %{status: "active"} = athanor} -> [athanor]
        _ -> []
      end

    Enum.reduce_while(default ++ athanors, {:error, :no_seat}, fn athanor, none ->
      case Sanctum.Context.focus(ctx, athanor) do
        {:ok, focus} -> {:halt, {:ok, focus, athanor}}
        {:error, :unavailable} = unavailable -> {:halt, unavailable}
        {:error, _refused} -> {:cont, none}
      end
    end)
  end

  # `Context.focus/2` decides who may open the athanor named in the URL: a
  # member, and no one else — a platform admin with no seat there is
  # refused like anyone, so a URL naming another person's athanor opens
  # nothing for them.
  defp focus_on(ctx, _default_id, route, _athanors) when is_binary(route) do
    with {:ok, athanor} <- Athanors.by_route_slug(route),
         {:ok, focus} <- Sanctum.Context.focus(ctx, athanor) do
      {:ok, focus, athanor}
    end
  end

  # The thread the address names; `new` a blank pane, whatever the athanor
  # holds — the first message starts the thread; the most recent without
  # an address, or nothing in an empty athanor. `new` is not an id: ids are
  # prefixed (`thread_…`), so the word cannot name a thread.
  @blank "new"

  @doc "The address of a blank pane in an athanor: `+ New` goes here."
  @spec blank() :: String.t()
  def blank, do: @blank

  defp pick(_threads, @blank), do: {:ok, nil}

  defp pick(threads, id) when is_binary(id) and id != "" do
    case Enum.find(threads, &(&1.id == id)) do
      nil -> :unseen
      thread -> {:ok, thread}
    end
  end

  defp pick(threads, _id), do: {:ok, List.first(threads)}

  # A list that could not be read is an empty athanor for the rail's
  # purposes — the pane says what it could not do.
  defp athanor_threads(focus) do
    case Threads.list(Sanctum.Context.actor(focus)) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # The selected athanor's own notifications (a rename, an archive); the
  # previous athanor's are dropped with the selection.
  defp subscribe_athanor(socket, athanor) do
    case socket.assigns.notified do
      ^athanor ->
        socket

      previous ->
        if previous do
          left = Prima.Actor.in_athanor(previous.id)
          Cyfr.Bus.unsubscribe(left, Cyfr.Bus.notify(left))
        end

        # The page's context is focused on the athanor it opens.
        actor = Sanctum.Context.actor(socket.assigns.context)
        Cyfr.Bus.subscribe(actor, Cyfr.Bus.notify(actor))
        assign(socket, :notified, athanor)
    end
  end

  # The rail follows the open thread's rows (titles, last activity), so the
  # page listens on that thread too — for the message events alone; the
  # pane applies the rest in its own process. An athanor's thread is no
  # shared thread, so the person's own AQUA beside the page reads none.
  defp select(socket, target) do
    socket = unsubscribe_current(socket)
    if target, do: follow_thread(target.id, target.athanor_id)

    socket
    |> assign(:thread, target)
    |> announce(nil)
    |> switch_pane(target)
  end

  # The pane is one per athanor and turns to a thread by message; the pane
  # of another athanor, or one that has not reported in yet, is left to
  # mount on the thread the address names.
  defp switch_pane(
         %{assigns: %{pane: {athanor_id, pid}, athanor: %{id: athanor_id}}} = socket,
         target
       ) do
    send(pid, {:switch_thread, target && target.id})
    socket
  end

  defp switch_pane(socket, _target), do: socket

  # What the person's own AQUA beside the page reads: the shared thread in
  # view, by its title and id only, or nothing.
  defp announce(socket, room) do
    PrismWeb.RoomFeed.announce(socket.assigns.room_feed, room)
    assign(socket, :room, room)
  end

  defp unsubscribe_current(%{assigns: %{thread: %{id: id, athanor_id: athanor_id}}} = socket) do
    unfollow_thread(id, athanor_id)
    socket
  end

  defp unsubscribe_current(socket), do: socket

  # A thread's broadcasts: the bus topic its athanor's actor names.
  defp follow_thread(thread_id, athanor_id) do
    actor = Prima.Actor.in_athanor(athanor_id)
    Cyfr.Bus.subscribe(actor, Cyfr.Bus.thread(actor, thread_id))
  end

  defp unfollow_thread(thread_id, athanor_id) do
    actor = Prima.Actor.in_athanor(athanor_id)
    Cyfr.Bus.unsubscribe(actor, Cyfr.Bus.thread(actor, thread_id))
  end

  # ============================================================================
  # The rail
  # ============================================================================

  # Rebuilt only when the set of athanors differs from what is listed — a
  # seat gained or lost; otherwise the athanor in view has its row refreshed
  # from the lists `open/2` just read, and nothing else is queried.
  defp sync_rail(socket, athanors) do
    ids = MapSet.new(athanors, & &1.id)
    listed = MapSet.new(socket.assigns.athanors, & &1.athanor.id)

    if MapSet.equal?(ids, listed),
      do: patch_row(socket),
      else: build_rail(socket, athanors)
  end

  # The person's athanor, entered through `Context.focus/2` for its own
  # list, and the shared threads with the people in them, for a pair.
  defp build_rail(socket, athanors) do
    %{context: ctx, mine: mine} = socket.assigns

    rows =
      for athanor <- athanors,
          {:ok, focus} <- [Sanctum.Context.focus(ctx, athanor)] do
        %{
          athanor: athanor,
          route: Athanors.route_slug(athanor),
          label: athanor_label(athanor, mine, ctx),
          threads: athanor_threads(focus)
        }
      end

    socket
    |> assign(:athanors, rows)
    |> patch_row()
    |> load_shared()
  end

  # The athanor in view, from what the page already holds for it.
  defp patch_row(%{assigns: %{athanor: %{id: id}}} = socket) do
    %{threads: threads} = socket.assigns

    update(socket, :athanors, fn rows ->
      for row <- rows do
        if row.athanor.id == id, do: %{row | threads: threads}, else: row
      end
    end)
  end

  defp patch_row(socket), do: socket

  # The athanor in view was renamed or reconfigured: its row, re-labelled.
  defp patch_athanor(socket, athanor) do
    label = athanor_label(athanor, socket.assigns.mine, socket.assigns.context)

    socket
    |> assign(:athanor, athanor)
    |> assign(:athanor_label, label)
    |> update(:athanors, fn rows ->
      Enum.map(rows, fn row ->
        if row.athanor.id == athanor.id, do: %{row | athanor: athanor, label: label}, else: row
      end)
    end)
  end

  defp personal_athanor(%{user_id: user_id}) do
    case Sanctum.Tenancy.Users.personal_athanor_id(user_id) do
      {:ok, id} -> id
      :none -> nil
    end
  end

  # Your own athanor is "You" (`PrismWeb.Athanors.label/2`).
  defp athanor_label(athanor, _mine, ctx), do: PrismWeb.Athanors.label(athanor, ctx)

  # The active shared threads the person sits in, pairs first by the other
  # person's name, then the rest by title, and the people they share one
  # with: whom a click pairs with. A list that cannot be read is said once
  # and leaves the rail's shared rows as they were.
  defp load_shared(socket) do
    ctx = socket.assigns.context

    socket =
      case PrismWeb.Ops.fetch_list(socket, "shared_thread/list", :threads) do
        {:ok, threads} ->
          rows =
            for %{status: "active"} = thread <- threads do
              %{id: thread.id, kind: thread.kind, label: shared_label(thread)}
            end
            |> Enum.sort_by(&{&1.kind != "pair", String.downcase(&1.label)})

          assign(socket, :shared_threads, rows)

        {:error, message} ->
          put_flash(socket, :error, "Your shared threads could not be read: #{message}")
      end

    people =
      case Sanctum.SharedThreads.people_in_threads_with(ctx.user_id) do
        {:ok, people} ->
          for person <- people,
              do: %{user_id: person.user_id, label: PrismWeb.People.label(person, ctx)}

        {:error, _unread} ->
          socket.assigns.people
      end

    assign(socket, :people, people)
  end

  defp shared_label(%{kind: "pair", with: %{name: name}}), do: name
  defp shared_label(%{title: title}) when is_binary(title), do: title
  defp shared_label(_thread), do: "Thread"

  # Whether `id` names one of the open athanor's own threads.
  defp thread_here?(socket, id) when is_binary(id),
    do: Enum.any?(socket.assigns.threads, &(&1.id == id))

  defp thread_here?(_socket, _id), do: false

  defp toggle(socket, key) do
    update(socket, :expanded, fn expanded ->
      if MapSet.member?(expanded, key),
        do: MapSet.delete(expanded, key),
        else: MapSet.put(expanded, key)
    end)
  end

  # ============================================================================
  # Events
  # ============================================================================

  @impl true
  def handle_event("toggle_athanor", %{"id" => id}, socket) do
    {:noreply, toggle(socket, id)}
  end

  def handle_event("open_athanor", %{"route" => route}, socket) do
    {:noreply, push_patch(socket, to: chat_path(route))}
  end

  def handle_event("open_thread", %{"route" => route, "id" => id}, socket) do
    # Deliberately does NOT follow: reading a thread is not joining it.
    # On a phone the drawer gives way to the thread.
    {:noreply,
     socket
     |> assign(:rail_open?, false)
     |> push_patch(to: chat_path(route, id))}
  end

  def handle_event("new_thread", _params, socket) do
    {:noreply,
     socket
     |> assign(:rail_open?, false)
     |> push_patch(to: chat_path(socket.assigns.athanor_route, @blank))}
  end

  def handle_event("close_rail", _params, socket) do
    {:noreply, assign(socket, :rail_open?, false)}
  end

  def handle_event("open_shared", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:rail_open?, false)
     |> push_patch(to: shared_path(id))}
  end

  # Click a person → the pair of the two of you, found or made, and opened
  # here. The tool decides reachability ("someone you already share a
  # thread with").
  def handle_event("open_dm", %{"user-id" => user_id}, socket) do
    case call_tool(socket, "shared_thread/pair", %{"user" => user_id}) do
      {:ok, %{id: id}} ->
        {:noreply, socket |> assign(:rail_open?, false) |> push_patch(to: shared_path(id))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not open a pair: #{error_message(reason)}")}
    end
  end

  def handle_event("toggle_with_people", _params, socket) do
    {:noreply, update(socket, :with_people?, &(not &1))}
  end

  # A thread with people: its title, then each person named by their
  # handle. The thread is made first; a name that cannot be added is said,
  # and the thread opens with whoever could be.
  def handle_event("create_shared", %{"title" => title} = params, socket) do
    with {:ok, names} <- people_names(params["people"] || ""),
         {:ok, %{id: id}} <- call_tool(socket, "shared_thread/create", %{"title" => title}) do
      unadded =
        for name <- names,
            {:error, reason} <-
              [call_tool(socket, "shared_thread/add", %{"thread" => id, "handle" => name})],
            do: "#{name} (#{error_message(reason)})"

      socket =
        if unadded == [],
          do: socket,
          else: put_flash(socket, :error, "Not added: " <> Enum.join(unadded, "; "))

      {:noreply,
       socket
       |> assign(:with_people?, false)
       |> assign(:rail_open?, false)
       |> load_shared()
       |> push_patch(to: shared_path(id))}
    else
      {:error, sentence} when is_binary(sentence) ->
        {:noreply, put_flash(socket, :error, sentence)}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not make the thread: #{error_message(reason)}")}
    end
  end

  # A seeding that failed is retried by any member; the row says how it went.
  def handle_event("provision", _params, socket) do
    case call_tool(focused(socket), "athanor/provision", %{}) do
      {:ok, _} ->
        {:noreply, socket |> reload_athanor() |> put_flash(:info, "Set up — AQUA is ready.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> reload_athanor()
         |> put_flash(:error, "Still not set up: #{error_message(reason)}")}
    end
  end

  # Saying one of your own lines out loud: pick a shared thread you sit
  # in. The rules (author-only — or your own assistant's line in your own
  # athanor — your seat in the thread, byte-copied attachments) are
  # `Aqua.Aloud`'s — this UI drives the same `thread.aloud` verb a
  # headless client has.
  def handle_event("aloud_open", %{"id" => msg_id}, socket) do
    {:noreply, assign(socket, :aloud_for, msg_id)}
  end

  # The open thread may have gone between opening the picker and choosing
  # a thread — deleted by another member — so it is checked, not assumed.
  def handle_event("aloud_post", _params, %{assigns: %{thread: nil}} = socket) do
    {:noreply,
     socket
     |> assign(:aloud_for, nil)
     |> put_flash(:error, "That thread is gone — nothing to say aloud.")}
  end

  def handle_event("aloud_post", %{"thread" => thread_id}, socket) do
    %{thread: thread, aloud_for: msg_id} = socket.assigns
    focus = focused(socket)

    result =
      call_tool(focus, "thread/aloud", %{
        "thread" => thread.id,
        "message_ids" => [msg_id],
        "target_thread" => thread_id
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

  def handle_event("delete_thread", %{"id" => id}, socket) do
    focus = focused(socket)

    # The turn may be running in a thread this tab is not looking at: the
    # runner is the fact, not what this socket happens to be rendering.
    # The id comes off the wire, and only one of this athanor's own
    # threads may be named — the same guard the follow verbs hold.
    cond do
      not thread_here?(socket, id) ->
        {:noreply, put_flash(socket, :error, "That thread isn't in this athanor.")}

      true ->
        case PrismWeb.Ops.call_tool(focus, "thread/delete", %{"thread" => id}) do
          {:ok, _} ->
            current = socket.assigns.thread && socket.assigns.thread.id

            if current == id do
              {:noreply, push_patch(socket, to: chat_path(socket.assigns.athanor_route))}
            else
              {:noreply, socket |> assign(:threads, athanor_threads(focus)) |> patch_row()}
            end

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Delete failed: #{error_message(reason)}")}
        end
    end
  end

  # ============================================================================
  # Bus fan-in — the lists, and what the pane tells the page
  # ============================================================================

  # A message on the open thread: that row's title and last activity, and
  # nothing else — the pane holds the tape.
  @impl true
  def handle_info(
        %Cyfr.Bus.ThreadEvent{thread_id: id, kind: :message},
        %{assigns: %{thread: %{id: id}}} = socket
      ) do
    case Threads.get(Sanctum.Context.actor(focused(socket)), id) do
      {:ok, thread} -> {:noreply, socket |> put_thread(thread) |> patch_row()}
      _ -> {:noreply, socket}
    end
  end

  def handle_info(%Cyfr.Bus.ThreadEvent{}, socket), do: {:noreply, socket}

  # The pane is live: this is where a thread switch goes. A pane that
  # mounted on a thread the address has since left is turned at once.
  def handle_info({:pane, _pane, {:ready, pid, thread_id}}, socket) do
    case socket.assigns.athanor do
      %{id: athanor_id} ->
        socket = assign(socket, :pane, {athanor_id, pid})
        current = socket.assigns.thread && socket.assigns.thread.id

        if current != thread_id,
          do: {:noreply, switch_pane(socket, socket.assigns.thread)},
          else: {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

  # The pane's first message created the thread: the address is this page's.
  def handle_info({:pane, _pane, {:opened, thread}}, socket) do
    {:noreply, push_patch(socket, to: chat_path(socket.assigns.athanor_route, thread.id))}
  end

  # A line the pane offers to say aloud: the picker is this page's.
  def handle_info({:pane, _pane, {:aloud_open, msg_id}}, socket) do
    handle_event("aloud_open", %{"id" => msg_id}, socket)
  end

  # The pane's own "Chats" button on a phone: the drawer is this page's.
  def handle_info({:pane, _pane, :toggle_rail}, socket) do
    {:noreply, update(socket, :rail_open?, &(not &1))}
  end

  # A grant the pane's turn needs: asked in this page's layer, under the
  # page's context, which is focused on the pane's athanor; the outcome
  # goes back to the pane.
  def handle_info({:pane, _pane, {:grant, pid, prompt}}, socket) when is_pid(pid) do
    {:noreply, SystemLayer.relay(socket, pid, prompt)}
  end

  # A rename or a settings change re-reads the row; an archive sends the
  # page back to the default — the runner behind the thread has stopped.
  def handle_info(%Cyfr.Bus.Notify{kind: :athanor_changed}, socket) do
    case Athanors.get(socket.assigns.athanor.id) do
      {:ok, %{status: "archived"} = athanor} ->
        {:noreply,
         socket
         |> assign(:athanor, athanor)
         |> put_flash(:error, "This athanor has been archived.")
         |> push_navigate(to: chat_path(nil))}

      {:ok, athanor} ->
        {:noreply, patch_athanor(socket, athanor)}

      _ ->
        {:noreply, socket}
    end
  end

  # Someone joined or left the athanor in view: the people list is theirs.
  def handle_info(%Cyfr.Bus.Notify{kind: :member_changed}, socket) do
    {:noreply, build_rail(socket, Sanctum.Tenancy.list_athanors(socket.assigns.context))}
  end

  # This person's own seats changed — a group they were added to, a DM the
  # other person minted, a seat withdrawn. The guard (`CyfrWeb.ContextGuard`)
  # revalidates the page's context first and hands the message on: a seat
  # lost under the athanor this page has open ends the page there — nothing
  # else keeps anyone in it, an operator's capability included — so it goes
  # back to the default. Anything else re-reads the set of athanors.
  def handle_info(
        %Cyfr.Bus.Membership{athanor_id: id, change: :left},
        %{assigns: %{athanor: %{id: id}}} = socket
      ) do
    {:noreply,
     socket
     |> put_flash(:error, "You are no longer a member of that athanor.")
     |> push_navigate(to: chat_path(nil))}
  end

  def handle_info(%Cyfr.Bus.Membership{}, socket) do
    {:noreply, build_rail(socket, Sanctum.Tenancy.list_athanors(socket.assigns.context))}
  end

  # A shared thread of the person's changed: the rail reads them again, and
  # the one in view is read again under their seat — renamed, archived, or
  # no longer theirs.
  def handle_info(%Cyfr.Bus.SharedThreadChanged{kind: kind, thread_id: id}, socket) do
    socket = load_shared(socket)

    case socket.assigns.shared do
      %{id: ^id} when kind == :changed -> {:noreply, reread_shared(socket, id)}
      _other -> {:noreply, socket}
    end
  end

  # The athanor's other notifies are the pane's.
  def handle_info(%Cyfr.Bus.Notify{}, socket), do: {:noreply, socket}

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  defp reread_shared(socket, id) do
    case PrismWeb.Ops.call_tool(socket, "shared_thread/get", %{"thread" => id}) do
      {:ok, %{status: "active"} = thread} ->
        label = shared_label(thread)

        if label == socket.assigns.shared.label,
          do: socket,
          else:
            socket
            |> assign(:shared, %{socket.assigns.shared | label: label})
            |> announce(PrismWeb.RoomFeed.room(id, label))

      {:ok, _archived} ->
        socket
        |> put_flash(:error, "This thread has been archived.")
        |> push_patch(to: chat_path(nil))

      {:error, {:unavailable, _what}} ->
        socket

      {:error, _gone} ->
        socket
        |> put_flash(:error, "You are no longer in that thread.")
        |> push_patch(to: chat_path(nil))
    end
  end

  # The names a person typed, by handle, split on commas and spaces. A name
  # is lowercase letters and digits joined by single hyphens.
  defp people_names(text) do
    names =
      text
      |> String.split([",", " ", "\n"], trim: true)
      |> Enum.map(&String.trim_leading(&1, "@"))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case Enum.reject(names, &Prima.ComponentRef.valid_personal_slug?/1) do
      [] ->
        {:ok, names}

      [bad | _] ->
        {:error,
         "\"#{bad}\" is not a name: lowercase letters and digits joined by single hyphens, at most 39 characters."}
    end
  end

  defp reload_athanor(socket) do
    case Athanors.get(socket.assigns.athanor.id) do
      {:ok, athanor} -> assign(socket, :athanor, athanor)
      _ -> socket
    end
  end

  # The open thread's fresh row, in place and in order; the room is told
  # again only when its title moved (the first message names a thread).
  defp put_thread(socket, thread) do
    threads =
      socket.assigns.threads
      |> Enum.reject(&(&1.id == thread.id))
      |> List.insert_at(0, thread)
      |> Enum.sort_by(&(&1.last_message_at || &1.inserted_at), {:desc, DateTime})

    socket |> assign(:threads, threads) |> assign(:thread, thread)
  end

  defp provisioning_note(athanor) do
    case Athanors.provisioning_failure(athanor) do
      nil ->
        nil

      %{step: step, detail: detail} ->
        detail =
          if String.length(detail) > 120, do: String.slice(detail, 0, 120) <> "…", else: detail

        "— last attempt failed at #{step}: #{detail}"
    end
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div id="chat-root" class="flex h-full min-h-0">
      <%!-- The rail: your own athanor, your DMs, your groups and their
            threads, across every athanor you belong to — a column beside the
            chat, a drawer over it on a phone. --%>
      <aside
        id="thread-list"
        aria-label="Chats"
        aria-busy={to_string(@loading?)}
        class={[
          "flex w-64 shrink-0 flex-col border-r border-gray-800 bg-gray-900/40 max-md:fixed max-md:inset-y-12 max-md:bottom-0 max-md:left-0 max-md:z-30 max-md:bg-gray-900 max-md:shadow-xl md:flex",
          if(@rail_open?, do: "", else: "max-md:hidden")
        ]}
      >
        <div class="flex items-center justify-between px-3 py-2 border-b border-gray-800">
          <span class="text-xs font-semibold uppercase tracking-wider text-gray-500">Chats</span>
          <div class="flex items-center gap-1">
            <button
              type="button"
              phx-click="new_thread"
              disabled={is_nil(@athanor)}
              class="min-h-6 rounded px-2 py-1 text-xs uppercase tracking-wider text-gray-400 hover:bg-gray-800 hover:text-gray-200 disabled:opacity-50"
              title={
                if @athanor,
                  do: "Start a new thread in #{@athanor_label}",
                  else: "Start a new thread"
              }
            >
              + New
            </button>
            <button
              type="button"
              phx-click="close_rail"
              class="md:hidden rounded px-2 py-1 text-gray-400 hover:bg-gray-800 hover:text-gray-200"
              aria-label="Close the list"
            >
              ×
            </button>
          </div>
        </div>

        <div class="flex-1 overflow-y-auto">
          <.rail_skeleton :if={@loading?} />

          <section
            :for={row <- @athanors}
            id={"athanor-" <> row.athanor.id}
            class="border-b border-gray-800/60"
          >
            <% current? = @athanor && row.athanor.id == @athanor.id %>
            <% unfolded? = MapSet.member?(@expanded, row.athanor.id) %>
            <div class={[
              "flex items-center gap-1 pl-1 pr-3 py-1.5 text-xs uppercase tracking-wider",
              if(current?, do: "text-gray-200", else: "text-gray-500")
            ]}>
              <button
                type="button"
                phx-click="toggle_athanor"
                phx-value-id={row.athanor.id}
                aria-expanded={to_string(unfolded?)}
                aria-label={"Threads of " <> row.label}
                class="min-h-6 w-6 shrink-0 rounded text-center text-gray-600 hover:text-gray-300"
              >
                <span aria-hidden="true">{if unfolded?, do: "▾", else: "▸"}</span>
              </button>
              <button
                type="button"
                phx-click="open_athanor"
                phx-value-route={row.route}
                aria-current={current? && "true"}
                class="flex min-h-6 flex-1 min-w-0 items-center gap-2 text-left hover:text-gray-200"
              >
                <span class="truncate">{row.label}</span>
                <span class="ml-auto text-xs text-gray-600 normal-case">
                  {length(row.threads)}
                </span>
              </button>
            </div>
            <div :if={unfolded?} id={"athanor-threads-" <> row.athanor.id}>
              <div :if={row.threads == []} class="px-3 py-2 text-xs text-gray-600">
                No threads yet.
              </div>
              <ul :if={row.threads != []} class="divide-y divide-gray-800/60">
                <.thread_row
                  :for={thread <- row.threads}
                  thread={thread}
                  route={row.route}
                  current={@thread}
                  athanor_id={@athanor && @athanor.id}
                />
              </ul>
            </div>
          </section>

          <%!-- The threads you share with people: pairs by the other
                person's name, then shared threads by title. --%>
          <section id="shared-threads" class="border-b border-gray-800/60">
            <div class="flex items-center justify-between pl-3 pr-2 py-1.5">
              <span class="text-xs uppercase tracking-wider text-gray-500">With people</span>
              <button
                type="button"
                id="new-with-people"
                phx-click="toggle_with_people"
                aria-expanded={to_string(@with_people?)}
                class="min-h-6 rounded px-2 py-1 text-xs text-gray-400 hover:bg-gray-800 hover:text-gray-200"
              >
                + New thread with people
              </button>
            </div>
            <form
              :if={@with_people?}
              id="new-shared-thread"
              phx-submit="create_shared"
              class="space-y-2 px-3 pb-2"
            >
              <input
                type="text"
                name="title"
                required
                maxlength="200"
                placeholder="Title"
                aria-label="Title"
                class="w-full rounded border border-gray-700 bg-gray-950 px-2 py-1 text-xs text-white placeholder-gray-500"
              />
              <input
                type="text"
                name="people"
                placeholder="Names, separated by commas"
                aria-label="People, by name"
                class="w-full rounded border border-gray-700 bg-gray-950 px-2 py-1 text-xs text-white placeholder-gray-500"
              />
              <button
                type="submit"
                class="min-h-6 rounded bg-blue-600 px-2 py-1 text-xs text-white hover:bg-blue-500"
              >
                Start the thread
              </button>
            </form>
            <ul :if={@shared_threads != []} class="divide-y divide-gray-800/60">
              <li :for={row <- @shared_threads} id={"shared-thread-" <> row.id}>
                <% open? = @shared && @shared.id == row.id %>
                <button
                  type="button"
                  phx-click="open_shared"
                  phx-value-id={row.id}
                  aria-current={open? && "true"}
                  class={[
                    "flex w-full items-center gap-2 px-4 py-2 text-left text-xs hover:bg-gray-800/50",
                    if(open?, do: "bg-gray-800/80 text-gray-200", else: "text-gray-400")
                  ]}
                >
                  <span class="truncate">{row.label}</span>
                  <span :if={row.kind == "pair"} class="ml-auto text-xs text-gray-600">DM</span>
                </button>
              </li>
            </ul>
          </section>

          <%!-- People you share a thread with: a click is the pair of the
                two of you, found or made, opened here. --%>
          <div :if={@people != []} class="border-b border-gray-800/60">
            <p class="px-3 py-1.5 text-xs uppercase tracking-wider text-gray-500">People</p>
            <ul>
              <li :for={person <- @people}>
                <button
                  type="button"
                  phx-click="open_dm"
                  phx-value-user-id={person.user_id}
                  class="flex w-full items-center px-3 py-1.5 text-xs text-gray-400 hover:bg-gray-800/50 hover:text-gray-200"
                  title={"Message #{person.label}"}
                >
                  <span class="truncate">{person.label}</span>
                </button>
              </li>
            </ul>
          </div>
        </div>
      </aside>

      <div class="flex flex-1 min-w-0 flex-col">
        <%= cond do %>
          <% @loading? -> %>
            <.tape_skeleton />
          <% @shared -> %>
            <%!-- A shared thread, as its own LiveView under the person's
                  own seat: no athanor holds it. --%>
            {live_render(@socket, PrismWeb.SharedThreadLive,
              id: "shared-pane-" <> @shared.id,
              session: %{"thread_id" => @shared.id}
            )}
          <% @focus -> %>
            <div
              :if={is_nil(@athanor.provisioned_at)}
              class="flex items-center justify-between gap-3 border-b border-amber-900/60 bg-amber-950/40 px-4 py-2 text-xs text-amber-200"
            >
              <span class="min-w-0 truncate">
                This athanor is still being set up
                <span :if={note = provisioning_note(@athanor)} class="text-amber-300/80">
                  {note}
                </span>
              </span>
              <button
                type="button"
                phx-click="provision"
                class="min-h-6 shrink-0 rounded px-2 py-1 text-xs uppercase tracking-wider bg-amber-800/60 text-amber-100 hover:bg-amber-700/80"
              >
                Retry
              </button>
            </div>

            <%!-- The athanor's pane, as its own LiveView under its own focused
                  context: one per athanor, turned to the open thread by
                  message, so a thread switch re-reads the thread alone. --%>
            {live_render(@socket, PrismWeb.ThreadPaneLive,
              id: "pane-" <> @athanor.id,
              session: %{
                "athanor_id" => @athanor.id,
                "thread_id" => @thread && @thread.id,
                "ui_mode" => assigns[:ui_mode]
              }
            )}
          <% true -> %>
            <div class="flex flex-1 items-center justify-center px-6 text-center text-sm text-gray-500">
              You are not in any athanor yet — there is nowhere to chat.
            </div>
        <% end %>
      </div>

      <%!-- Say-aloud picker: which of the threads you share with people. --%>
      <.modal id="aloud-picker" show={not is_nil(@aloud_for)} on_cancel={JS.push("aloud_cancel")}>
        <div class="space-y-3">
          <h3 class="text-sm font-medium text-gray-200">Say aloud</h3>
          <p class="text-xs text-gray-500">
            A copy of the line lands on a thread you share with people, attributed to you.
            This thread keeps the original.
          </p>

          <div :if={@shared_threads == []} class="text-xs text-gray-500">
            You share no thread with anyone yet — there is nowhere to say it.
          </div>

          <div :if={@shared_threads != []} class="space-y-1">
            <button
              :for={row <- @shared_threads}
              type="button"
              phx-click="aloud_post"
              phx-value-thread={row.id}
              class="block w-full text-left rounded px-2 py-1 text-xs text-gray-300 hover:bg-gray-800/60"
            >
              {row.label}
              <span :if={row.kind == "pair"} class="text-xs text-gray-500 ml-1">DM</span>
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
      </.modal>

      <%!-- The page's system layer, under the page's context: what the
            athanor's pane asks for is asked here, and the person's
            confirmations are shown. --%>
      <.live_component
        module={SystemLayer}
        id={SystemLayer.layer_id()}
        context={@context}
        athanor_route={assigns[:athanor_route]}
        athanor_name={@athanor && @athanor.name}
      />
    </div>
    """
  end

  # What the page looks like before the athanor is in focus: the shape of a
  # rail and a tape, so the first paint is not a blank column.
  defp rail_skeleton(assigns) do
    ~H"""
    <div id="rail-skeleton" class="animate-pulse space-y-3 px-3 py-3" aria-hidden="true">
      <div :for={_ <- 1..3} class="space-y-2">
        <div class="h-2.5 w-24 rounded bg-gray-800"></div>
        <div class="h-2 w-full rounded bg-gray-800/70"></div>
        <div class="h-2 w-4/5 rounded bg-gray-800/70"></div>
      </div>
    </div>
    """
  end

  defp tape_skeleton(assigns) do
    ~H"""
    <div id="tape-skeleton" class="flex flex-1 flex-col animate-pulse" aria-hidden="true">
      <div class="flex items-center gap-3 border-b border-gray-800 px-4 py-3">
        <div class="h-3 w-20 rounded bg-gray-800"></div>
        <div class="h-3 w-32 rounded bg-gray-800/70"></div>
      </div>
      <div class="flex-1 space-y-4 px-4 py-6">
        <div class="h-3 w-1/2 rounded bg-gray-800/70"></div>
        <div class="h-3 w-2/3 rounded bg-gray-800/70"></div>
        <div class="h-3 w-1/3 rounded bg-gray-800/70"></div>
      </div>
      <div class="border-t border-gray-800 px-4 py-3">
        <div class="h-9 rounded bg-gray-800/70"></div>
      </div>
    </div>
    """
  end

  attr :thread, :map, required: true
  attr :route, :string, required: true
  attr :current, :any, default: nil
  attr :athanor_id, :string, default: nil

  # One thread in the rail. Its action shows on hover or focus at a desk,
  # and always on a phone, which has neither.
  defp thread_row(assigns) do
    assigns =
      assign(assigns, :open?, assigns.current && assigns.thread.id == assigns.current.id)

    ~H"""
    <li
      id={"thread-" <> @thread.id}
      class={[
        "group flex items-start gap-2 pl-4 pr-2 text-xs hover:bg-gray-800/50",
        if(@open?, do: "bg-gray-800/80", else: "")
      ]}
    >
      <button
        type="button"
        phx-click="open_thread"
        phx-value-route={@route}
        phx-value-id={@thread.id}
        aria-current={@open? && "true"}
        class="flex-1 min-w-0 py-2 text-left"
      >
        <p class="truncate text-gray-200">
          {@thread.title}
        </p>
        <p class="text-xs text-gray-600 mt-0.5">
          {Calendar.strftime(@thread.last_message_at || @thread.inserted_at, "%b %d %H:%M")}
        </p>
      </button>
      <button
        :if={@athanor_id && @thread.athanor_id == @athanor_id}
        type="button"
        phx-click="delete_thread"
        phx-value-id={@thread.id}
        class="min-w-6 shrink-0 py-2 text-gray-500 hover:text-red-400 md:opacity-0 md:group-hover:opacity-100 md:group-focus-within:opacity-100 md:focus-visible:opacity-100"
        data-confirm="Delete this thread?"
        aria-label="Delete"
      >
        ×
      </button>
    </li>
    """
  end
end
