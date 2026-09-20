# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ChatLive do
  @moduledoc """
  The chat — one zone across every estate the person belongs to, at
  `/chat`.

  The rail is the person's contact list: their own athanor, their DMs (the
  frozen pairs, shown by the other person's name), their groups and each
  group's threads — membership IS the list. Opening a row opens that thread
  in place as `PrismWeb.ThreadPaneLive`, a nested LiveView with a
  focused context of its own, so nothing here depends on which estate the
  session happens to default to. The workbench's switcher governs the
  workbench; this page governs itself through its address:
  `?a=<route>` names the estate, `?c=<thread_id>` the thread (without
  it the estate's most recent, or a fresh one started by the first message).

  A DM opens from the rail: click a person you share an estate with and
  the frozen pair of the two of you is found or minted (`athanor.pair`) and
  selected here — the session's default athanor does not move.

  The page owns what is the page's: the selection, the lists and what is
  followed, which estates are unfolded, the phone drawer, the say-aloud
  picker, and the selected estate's own notifications. The pane owns the
  thread. What is in view is announced (`PrismWeb.RoomFeed`) for the
  person's own AQUA beside the page, and told to the bar over it
  (`PrismWeb.TopbarLive.viewing/2`) so the tray follows.

  The rail is read once per change to the SET of estates — a seat gained
  or lost. Moving between estates, a message on the open thread, a follow
  or a rename each touch the one row they concern.
  """

  use PrismWeb, :live_view

  alias Phoenix.LiveView.JS

  alias Arca.ThreadStorage, as: Threads
  alias Aqua.Runner
  alias Sanctum.Tenancy.Athanors

  @impl true
  def mount(_params, session, socket) do
    # The tray is the session's (`Prism.Tray`): opening an estate here is
    # looking at it, so its badge is read the same as focusing the bench.
    token = session[to_string(PrismWeb.SignInResponse.session_key())]

    {:ok,
     socket
     |> assign(:tray_key, token && Prism.Tray.session_hash(token))
     |> assign(:mine, personal_athanor(socket.assigns.context))
     |> assign(:room_feed, PrismWeb.RoomFeed.topic(socket.id))
     |> assign(:room, nil)
     |> assign(:page_title, "Chat")
     |> assign(:active_nav, "chat")
     |> assign(:loading?, true)
     |> assign(:estates, [])
     |> assign(:people, [])
     |> assign(:expanded, MapSet.new())
     |> assign(:rail_open?, false)
     |> assign(:focus, nil)
     |> assign(:athanor_label, nil)
     |> assign(:threads, [])
     |> assign(:followed, MapSet.new())
     |> assign(:thread, nil)
     |> assign(:pane, nil)
     |> assign(:aloud_for, nil)
     |> assign(:aloud_targets, [])
     |> assign(:aloud_estate, nil)
     |> assign(:aloud_threads, [])
     |> assign(:notified, nil)}
  end

  @doc "The chat's address for an estate, and optionally one of its threads."
  @spec chat_path(String.t() | nil, String.t() | nil) :: String.t()
  def chat_path(route, thread_id \\ nil) do
    query =
      [a: route, c: thread_id]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    if query == [], do: "/chat", else: "/chat?" <> URI.encode_query(query)
  end

  # The address decides everything: which estate (a member's own default
  # without `a`), then which thread. The estate is entered through
  # `Context.focus/2` — membership checked, an archived one refused — and
  # that focused context is what the lists and the pane run under.
  @impl true
  def handle_params(params, _uri, socket) do
    if connected?(socket), do: open(socket, params), else: {:noreply, socket}
  end

  defp open(socket, params) do
    ctx = socket.assigns.context
    athanors = Sanctum.Tenancy.list_athanors(ctx)

    case focus_on(ctx, params["a"], athanors) do
      {:ok, focus, athanor} ->
        open_estate(socket, focus, athanor, athanors, params["c"])

      {:error, :no_estate} ->
        # No seat anywhere: nothing to open, and nothing to patch to.
        {:noreply,
         socket
         |> assign(:loading?, false)
         |> assign(:athanor, nil)
         |> assign(:focus, nil)
         |> assign(:thread, nil)
         |> assign(:estates, [])
         |> assign(:people, [])}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "That estate cannot be opened (#{reason}).")
         |> push_navigate(to: chat_path(nil))}
    end
  end

  # The row as it is now. Used after subscribing, so what the page renders
  # is never older than the topic it is listening to.
  defp reread(%{id: id} = athanor) do
    case Athanors.get(id) do
      {:ok, fresh} -> fresh
      _ -> athanor
    end
  end

  defp open_estate(socket, focus, athanor, athanors, thread_id) do
    ctx = socket.assigns.context
    threads = estate_threads(focus)

    case pick(threads, thread_id) do
      {:ok, target} ->
        if socket.assigns.tray_key, do: Prism.Tray.clear(socket.assigns.tray_key, athanor.id)
        PrismWeb.TopbarLive.viewing(self(), athanor.id)

        {:noreply,
         socket
         |> assign(:loading?, false)
         |> subscribe_estate(athanor)
         |> assign(:focus, focus)
         # Re-read after subscribing, not before: a fill that completed
         # between the two would otherwise leave the setup banner up until
         # someone reloaded.
         |> assign(:athanor, reread(athanor))
         |> assign(:athanor_route, Athanors.route_slug(athanor))
         |> assign(:athanor_label, estate_label(athanor, socket.assigns.mine, ctx))
         |> assign(:threads, threads)
         |> assign(
           :followed,
           Arca.ThreadSubscriptionStorage.followed(Sanctum.Context.actor(focus), ctx.user_id)
         )
         |> update(:expanded, &MapSet.put(&1, athanor.id))
         |> select(target)
         |> sync_rail(athanors)}

      # The address named a thread this estate does not hold: say so, and
      # open the estate's own default rather than a blank pane.
      :unseen ->
        {:noreply,
         socket
         |> put_flash(:error, "That thread isn't in this estate.")
         |> push_patch(to: chat_path(Athanors.route_slug(athanor)))}
    end
  end

  # No estate named: the session's default, or — when that seat is gone —
  # the first estate the person still holds one in. Never a patch back to
  # the default, which is how a lost seat would loop.
  defp focus_on(ctx, route, athanors) when route in [nil, ""] do
    default =
      case ctx.athanor_id && Athanors.get(ctx.athanor_id) do
        {:ok, %{status: "active"} = athanor} -> [athanor]
        _ -> []
      end

    Enum.find_value(default ++ athanors, {:error, :no_estate}, fn athanor ->
      case Sanctum.Context.focus(ctx, athanor) do
        {:ok, focus} -> {:ok, focus, athanor}
        {:error, _} -> nil
      end
    end)
  end

  # `Context.focus/2` decides who may open the estate named in the URL: a
  # member, or a platform admin through the audited operator open. That
  # the operator's open is reachable from this global address — not only
  # from a workbench page — is deliberate: the audit event is the
  # safeguard, wherever the open is made from.
  defp focus_on(ctx, route, _athanors) when is_binary(route) do
    with {:ok, athanor} <- Athanors.by_route_slug(route),
         {:ok, focus} <- Sanctum.Context.focus(ctx, athanor) do
      {:ok, focus, athanor}
    end
  end

  # The thread the address names; `new` a blank pane, whatever the estate
  # holds — the first message starts the thread; the most recent without
  # an address, or nothing in an empty estate. `new` is not an id: ids are
  # prefixed (`thread_…`), so the word cannot name a thread.
  @blank "new"

  @doc "The address of a blank pane in an estate: `+ New` goes here."
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

  # A list that could not be read is an empty estate for the rail's
  # purposes — the pane says what it could not do.
  defp estate_threads(focus) do
    case Threads.list(Sanctum.Context.actor(focus)) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # The selected estate's own notifications (a rename, an archive); the
  # previous estate's are dropped with the selection.
  defp subscribe_estate(socket, athanor) do
    case socket.assigns.notified do
      ^athanor ->
        socket

      previous ->
        if previous,
          do: Phoenix.PubSub.unsubscribe(Emissary.PubSub, Sanctum.Notify.topic(previous.id))

        Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Notify.topic(athanor.id))
        assign(socket, :notified, athanor)
    end
  end

  # The rail follows the open thread's rows (titles, last activity), so the
  # page listens on that thread too — for the message events alone; the
  # pane applies the rest in its own process. The thread in view is told
  # to the person's own AQUA beside the page, by name and id only.
  defp select(socket, target) do
    socket = unsubscribe_current(socket)
    if target, do: Runner.subscribe(target.id, target.athanor_id)

    socket
    |> assign(:thread, target)
    |> announce(target)
    |> switch_pane(target)
  end

  # The pane is one per estate and turns to a thread by message; the pane
  # of another estate, or one that has not reported in yet, is left to
  # mount on the thread the address names.
  defp switch_pane(
         %{assigns: %{pane: {athanor_id, pid}, athanor: %{id: athanor_id}}} = socket,
         target
       ) do
    send(pid, {:switch_thread, target && target.id})
    socket
  end

  defp switch_pane(socket, _target), do: socket

  defp announce(socket, target) do
    %{athanor: athanor, athanor_label: label} = socket.assigns
    room = target && PrismWeb.RoomFeed.room(athanor, target, label)
    PrismWeb.RoomFeed.announce(socket.assigns.room_feed, room)
    assign(socket, :room, room)
  end

  defp unsubscribe_current(%{assigns: %{thread: %{id: id, athanor_id: athanor_id}}} = socket) do
    Runner.unsubscribe(id, athanor_id)
    socket
  end

  defp unsubscribe_current(socket), do: socket

  # ============================================================================
  # The rail
  # ============================================================================

  # Rebuilt only when the set of estates differs from what is listed — a
  # seat gained or lost; otherwise the estate in view has its row refreshed
  # from the lists `open/2` just read, and nothing else is queried.
  defp sync_rail(socket, athanors) do
    ids = MapSet.new(athanors, & &1.id)
    listed = MapSet.new(socket.assigns.estates, & &1.athanor.id)

    if MapSet.equal?(ids, listed),
      do: patch_row(socket),
      else: build_rail(socket, athanors)
  end

  # Every estate the person holds a seat in, each entered through
  # `Context.focus/2` for its own list, sorted own athanor, DMs, groups;
  # and the people they share an estate with, for a DM.
  defp build_rail(socket, athanors) do
    %{context: ctx, mine: mine} = socket.assigns

    estates =
      for athanor <- athanors,
          {:ok, focus} <- [Sanctum.Context.focus(ctx, athanor)] do
        %{
          athanor: athanor,
          route: Athanors.route_slug(athanor),
          kind: estate_kind(athanor, mine),
          label: estate_label(athanor, mine, ctx),
          threads: estate_threads(focus),
          followed:
            Arca.ThreadSubscriptionStorage.followed(Sanctum.Context.actor(focus), ctx.user_id)
        }
      end
      |> Enum.sort_by(&{kind_rank(&1.kind), String.downcase(&1.label)})

    people =
      estates
      |> Enum.filter(&(&1.kind == :group))
      |> Enum.flat_map(fn %{athanor: athanor} -> members_of(athanor, ctx) end)
      |> Enum.reject(&(&1.user_id == ctx.user_id))
      |> Enum.uniq_by(& &1.user_id)
      |> Enum.sort_by(&String.downcase(&1.label))

    # An estate with nothing followed has only its other threads to show, so
    # they start unfolded — once, when the estate first joins the rail. A
    # later toggle is the person's and stands through every rebuild.
    listed = MapSet.new(socket.assigns.estates, & &1.athanor.id)

    expanded =
      Enum.reduce(estates, socket.assigns.expanded, fn estate, acc ->
        cond do
          MapSet.member?(listed, estate.athanor.id) -> acc
          Enum.any?(estate.threads, &MapSet.member?(estate.followed, &1.id)) -> acc
          true -> MapSet.put(acc, other_key(estate.athanor.id))
        end
      end)

    socket
    |> assign(:estates, estates)
    |> assign(:people, people)
    |> assign(:expanded, expanded)
    |> patch_row()
  end

  # The estate in view, from what the page already holds for it.
  defp patch_row(%{assigns: %{athanor: %{id: id}}} = socket) do
    %{threads: threads, followed: followed} = socket.assigns

    update(socket, :estates, fn estates ->
      for row <- estates do
        if row.athanor.id == id, do: %{row | threads: threads, followed: followed}, else: row
      end
    end)
  end

  defp patch_row(socket), do: socket

  # The estate in view was renamed or reconfigured: its row, re-labelled.
  defp patch_athanor(socket, athanor) do
    label = estate_label(athanor, socket.assigns.mine, socket.assigns.context)

    socket
    |> assign(:athanor, athanor)
    |> assign(:athanor_label, label)
    |> update(:estates, fn estates ->
      estates
      |> Enum.map(fn row ->
        if row.athanor.id == athanor.id, do: %{row | athanor: athanor, label: label}, else: row
      end)
      |> Enum.sort_by(&{kind_rank(&1.kind), String.downcase(&1.label)})
    end)
  end

  defp personal_athanor(%{user_id: user_id}) do
    case Sanctum.Tenancy.Users.personal_athanor_id(user_id) do
      {:ok, id} -> id
      :none -> nil
    end
  end

  defp estate_kind(%{id: id}, mine) when id == mine, do: :mine
  defp estate_kind(%{roster: "frozen"}, _mine), do: :dm
  defp estate_kind(_athanor, _mine), do: :group

  defp kind_rank(:mine), do: 0
  defp kind_rank(:dm), do: 1
  defp kind_rank(:group), do: 2

  # Your own estate is "You"; a DM is the other person, never the pair
  # row's own name; a group is its name (`Athanors.pair_label/2`).
  defp estate_label(athanor, _mine, ctx), do: PrismWeb.Estates.label(athanor, ctx)

  defp members_of(athanor, ctx) do
    case Sanctum.Tenancy.Members.list_by_athanor(athanor.id) do
      {:ok, rows} ->
        for m <- rows, is_binary(m.user_id), m.status == "active" do
          %{user_id: m.user_id, label: PrismWeb.People.label(m, ctx)}
        end

      {:error, _} ->
        []
    end
  end

  defp other_key(athanor_id), do: athanor_id <> ":other"

  # Whether `id` names one of the open estate's own threads.
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
  def handle_event("toggle_estate", %{"id" => id}, socket) do
    {:noreply, toggle(socket, id)}
  end

  def handle_event("toggle_other", %{"id" => id}, socket) do
    {:noreply, toggle(socket, other_key(id))}
  end

  def handle_event("open_estate", %{"route" => route}, socket) do
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

  # Click a person → the frozen pair of the two of you, found or minted,
  # and selected here. The session's default athanor does not move; the
  # tool decides reachability ("you already share an active estate").
  def handle_event("open_dm", %{"user-id" => user_id}, socket) do
    with {:ok, %{id: id}} <- call_tool(socket, "athanor/pair", %{"user" => user_id}),
         {:ok, pair} <- Athanors.get(id) do
      {:noreply, push_patch(socket, to: chat_path(Athanors.route_slug(pair)))}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not open a DM: #{error_message(reason)}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not open a DM.")}
    end
  end

  # A seeding that failed is retried by any member; the row says how it went.
  def handle_event("provision", _params, socket) do
    case call_tool(socket.assigns.focus, "athanor/provision", %{}) do
      {:ok, _} ->
        {:noreply, socket |> reload_athanor() |> put_flash(:info, "Set up — AQUA is ready.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> reload_athanor()
         |> put_flash(:error, "Still not set up: #{error_message(reason)}")}
    end
  end

  # Saying one of your own lines out loud: pick an estate you belong to,
  # then one of its threads. The rules (author-only — or your own assistant's
  # line in your own athanor — membership on both sides, byte-copied
  # attachments) are `Aqua.Aloud`'s — this UI drives the same
  # `thread.aloud` verb a headless client has.
  def handle_event("aloud_open", %{"id" => msg_id}, socket) do
    targets =
      socket.assigns.estates
      |> Enum.reject(&(&1.athanor.id == socket.assigns.athanor.id))
      |> Enum.map(&%{id: &1.athanor.id, name: &1.label, kind: &1.kind})

    {:noreply,
     socket
     |> assign(:aloud_for, msg_id)
     |> assign(:aloud_targets, targets)
     |> assign(:aloud_estate, nil)
     |> assign(:aloud_threads, [])}
  end

  def handle_event("aloud_pick_estate", %{"athanor" => athanor_id}, socket) do
    case Sanctum.Context.focus(socket.assigns.context, athanor_id) do
      {:ok, focused} ->
        {:noreply,
         socket
         |> assign(:aloud_estate, athanor_id)
         |> assign(:aloud_threads, estate_threads(focused))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "You are not a member of that estate.")}
    end
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
    %{thread: thread, aloud_for: msg_id, aloud_estate: estate, focus: focus} = socket.assigns

    result =
      call_tool(focus, "thread/aloud", %{
        "thread" => thread.id,
        "message_ids" => [msg_id],
        "target_athanor" => estate,
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

  # Following decides emphasis and notification, never visibility. The
  # write is the fact; the page's own set follows it without a re-read.
  # The id comes off the wire and the row is written under the estate in
  # focus, so only one of that estate's own threads may be named.
  def handle_event("follow_thread", %{"id" => id}, socket) do
    focus = socket.assigns.focus

    with true <- thread_here?(socket, id),
         {:ok, _} <-
           PrismWeb.Ops.call_tool(focus, "thread/follow", %{"thread" => id}) do
      {:noreply, socket |> update(:followed, &MapSet.put(&1, id)) |> patch_row()}
    else
      false -> {:noreply, put_flash(socket, :error, "That thread isn't in this estate.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not follow — try again.")}
    end
  end

  def handle_event("unfollow_thread", %{"id" => id}, socket) do
    focus = socket.assigns.focus

    with true <- thread_here?(socket, id),
         {:ok, _} <-
           PrismWeb.Ops.call_tool(focus, "thread/unfollow", %{"thread" => id}) do
      {:noreply, socket |> update(:followed, &MapSet.delete(&1, id)) |> patch_row()}
    else
      false -> {:noreply, put_flash(socket, :error, "That thread isn't in this estate.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not unfollow — try again.")}
    end
  end

  def handle_event("delete_thread", %{"id" => id}, socket) do
    focus = socket.assigns.focus

    # The turn may be running in a thread this tab is not looking at: the
    # runner is the fact, not what this socket happens to be rendering.
    # The id comes off the wire, and only one of this estate's own
    # threads may be named — the same guard the follow verbs hold.
    cond do
      not thread_here?(socket, id) ->
        {:noreply, put_flash(socket, :error, "That thread isn't in this estate.")}

      true ->
        case PrismWeb.Ops.call_tool(focus, "thread/delete", %{"thread" => id}) do
          {:ok, _} ->
            current = socket.assigns.thread && socket.assigns.thread.id

            if current == id do
              {:noreply, push_patch(socket, to: chat_path(socket.assigns.athanor_route))}
            else
              {:noreply, socket |> assign(:threads, estate_threads(focus)) |> patch_row()}
            end

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Delete failed: #{error_message(reason)}")}
        end
    end
  end

  # ============================================================================
  # PubSub fan-in — the lists, and what the pane tells the page
  # ============================================================================

  # A message on the open thread: that row's title and last activity, and
  # nothing else — the pane holds the tape.
  @impl true
  def handle_info(
        {:thread, id, {:message, _row}},
        %{assigns: %{thread: %{id: id}}} = socket
      ) do
    case Threads.get(Sanctum.Context.actor(socket.assigns.focus), id) do
      {:ok, thread} -> {:noreply, socket |> put_thread(thread) |> patch_row()}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:thread, _id, _event}, socket), do: {:noreply, socket}

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

  # A rename or a settings change re-reads the row; an archive sends the
  # page back to the default — the runner behind the thread has stopped.
  def handle_info({:notify, _athanor_id, :athanor_changed, _payload}, socket) do
    case Athanors.get(socket.assigns.athanor.id) do
      {:ok, %{status: "archived"} = athanor} ->
        {:noreply,
         socket
         |> assign(:athanor, athanor)
         |> put_flash(:error, "This estate has been archived.")
         |> push_navigate(to: chat_path(nil))}

      {:ok, athanor} ->
        {:noreply, patch_athanor(socket, athanor)}

      _ ->
        {:noreply, socket}
    end
  end

  # Someone joined or left the estate in view: the people list is theirs.
  def handle_info({:notify, _athanor_id, :member_changed, _payload}, socket) do
    {:noreply, build_rail(socket, Sanctum.Tenancy.list_athanors(socket.assigns.context))}
  end

  # This person's own seats changed — a group they were added to, a DM the
  # other person minted, a seat withdrawn. The gate (`PrismWeb.LiveAuth`)
  # subscribes the page, settles the caller and hands the message on: a
  # seat lost under the session's own estate never reaches here. One lost
  # under the estate this page has open sends it back to the default;
  # anything else re-reads the set of estates.
  def handle_info(
        {:membership_changed, %{athanor_id: id, change: :left}},
        %{assigns: %{athanor: %{id: id}}} = socket
      ) do
    {:noreply,
     socket
     |> put_flash(:error, "You are no longer a member of that estate.")
     |> push_navigate(to: chat_path(nil))}
  end

  def handle_info({:membership_changed, _change}, socket) do
    {:noreply, build_rail(socket, Sanctum.Tenancy.list_athanors(socket.assigns.context))}
  end

  # The estate's other notifies are the bar's (the tray) and the pane's.
  def handle_info({:notify, _athanor_id, _kind, _payload}, socket), do: {:noreply, socket}

  def handle_info(msg, socket) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg, :debug)
    {:noreply, socket}
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

    socket = assign(socket, :threads, threads)

    case socket.assigns.thread do
      %{title: title} when title == thread.title -> assign(socket, :thread, thread)
      _ -> socket |> assign(:thread, thread) |> announce(thread)
    end
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
            threads, across every estate you belong to — a column beside the
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
              class="rounded px-2 py-1 text-[11px] uppercase tracking-wider text-gray-400 hover:bg-gray-800 hover:text-gray-200 disabled:opacity-50"
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
            :for={estate <- @estates}
            id={"estate-" <> estate.athanor.id}
            class="border-b border-gray-800/60"
          >
            <% current? = @athanor && estate.athanor.id == @athanor.id %>
            <% unfolded? = MapSet.member?(@expanded, estate.athanor.id) %>
            <div class={[
              "flex items-center gap-1 pl-1 pr-3 py-1.5 text-[11px] uppercase tracking-wider",
              if(current?, do: "text-gray-200", else: "text-gray-500")
            ]}>
              <button
                type="button"
                phx-click="toggle_estate"
                phx-value-id={estate.athanor.id}
                aria-expanded={to_string(unfolded?)}
                aria-label={"Threads of " <> estate.label}
                class="w-5 shrink-0 rounded text-center text-gray-600 hover:text-gray-300"
              >
                <span aria-hidden="true">{if unfolded?, do: "▾", else: "▸"}</span>
              </button>
              <button
                type="button"
                phx-click="open_estate"
                phx-value-route={estate.route}
                aria-current={current? && "true"}
                class="flex flex-1 min-w-0 items-center gap-2 text-left hover:text-gray-200"
              >
                <span class="truncate">{estate.label}</span>
                <span :if={estate.kind == :dm} class="text-[9px] text-gray-600 normal-case">
                  DM
                </span>
                <span class="ml-auto text-[10px] text-gray-600 normal-case">
                  {length(estate.threads)}
                </span>
              </button>
            </div>
            <div :if={unfolded?} id={"estate-threads-" <> estate.athanor.id}>
              <div :if={estate.threads == []} class="px-3 py-2 text-xs text-gray-600">
                No threads yet.
              </div>
              <% {following, other} =
                Enum.split_with(estate.threads, &MapSet.member?(estate.followed, &1.id)) %>
              <ul :if={following != []} class="divide-y divide-gray-800/60">
                <.thread_row
                  :for={thread <- following}
                  thread={thread}
                  route={estate.route}
                  current={@thread}
                  estate_id={@athanor && @athanor.id}
                  followed
                />
              </ul>
              <% other_open? = MapSet.member?(@expanded, other_key(estate.athanor.id)) %>
              <div :if={other != []} class="border-t border-gray-800/60">
                <button
                  type="button"
                  phx-click="toggle_other"
                  phx-value-id={estate.athanor.id}
                  aria-expanded={to_string(other_open?)}
                  class="w-full px-4 py-1 text-left text-[10px] uppercase tracking-wider text-gray-600 hover:text-gray-400"
                >
                  Other threads ({length(other)})
                </button>
                <ul
                  :if={other_open?}
                  id={"estate-other-" <> estate.athanor.id}
                  class="divide-y divide-gray-800/60"
                >
                  <.thread_row
                    :for={thread <- other}
                    thread={thread}
                    route={estate.route}
                    current={@thread}
                    estate_id={@athanor && @athanor.id}
                    followed={false}
                  />
                </ul>
              </div>
            </div>
          </section>

          <%!-- People you share an estate with: a click is a DM, found or
                minted, opened here — the estate switcher does not move. --%>
          <div :if={@people != []} class="border-b border-gray-800/60">
            <p class="px-3 py-1.5 text-[11px] uppercase tracking-wider text-gray-500">People</p>
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
          <% @focus -> %>
            <div
              :if={is_nil(@athanor.provisioned_at)}
              class="flex items-center justify-between gap-3 border-b border-amber-900/60 bg-amber-950/40 px-4 py-2 text-xs text-amber-200"
            >
              <span class="min-w-0 truncate">
                This estate is still being set up
                <span :if={note = provisioning_note(@athanor)} class="text-amber-300/80">
                  {note}
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

            <%!-- The estate's pane, as its own LiveView under its own focused
                  context: one per estate, turned to the open thread by
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
              You are not in any estate yet — there is nowhere to chat.
            </div>
        <% end %>
      </div>

      <%!-- Say-aloud picker: which estate, then which of its threads. --%>
      <.modal id="aloud-picker" show={not is_nil(@aloud_for)} on_cancel={JS.push("aloud_cancel")}>
        <div class="space-y-3">
          <h3 class="text-sm font-medium text-gray-200">Say aloud</h3>
          <p class="text-[11px] text-gray-500">
            A copy of the line lands on an estate's thread, attributed to you.
            This thread keeps the original.
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
              phx-value-athanor={t.id}
              class={[
                "block w-full text-left rounded px-2 py-1 text-xs",
                if(@aloud_estate == t.id,
                  do: "bg-gray-800 text-white",
                  else: "text-gray-300 hover:bg-gray-800/60"
                )
              ]}
            >
              {t.name}
              <span :if={t.kind == :dm} class="text-[10px] text-gray-500 ml-1">DM</span>
            </button>
          </div>

          <div :if={@aloud_estate} class="space-y-1">
            <p class="text-[10px] uppercase tracking-wider text-gray-500">Thread</p>
            <div :if={@aloud_threads == []} class="text-xs text-gray-500">
              That estate has no threads yet.
            </div>
            <button
              :for={thread <- @aloud_threads}
              type="button"
              phx-click="aloud_post"
              phx-value-thread={thread.id}
              class="block w-full text-left rounded px-2 py-1 text-xs text-gray-300 hover:bg-gray-800/60"
            >
              {thread.title}
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
    </div>
    """
  end

  # What the page looks like before the estate is in focus: the shape of a
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
  attr :estate_id, :string, default: nil
  attr :followed, :boolean, required: true

  # One thread in the rail. Follow/unfollow is a word, not a glyph — the
  # action must read as what it does. Following decides emphasis and
  # notification, never access: every row opens on a click. The actions
  # show on hover or focus at a desk, and always on a phone, which has
  # neither.
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
        <p class={["truncate", if(@followed, do: "text-gray-200", else: "text-gray-400")]}>
          {@thread.title}
        </p>
        <p class="text-[10px] text-gray-600 mt-0.5">
          {Calendar.strftime(@thread.last_message_at || @thread.inserted_at, "%b %d %H:%M")}
        </p>
      </button>
      <button
        :if={@estate_id && @thread.athanor_id == @estate_id}
        type="button"
        phx-click={if @followed, do: "unfollow_thread", else: "follow_thread"}
        phx-value-id={@thread.id}
        class="shrink-0 py-2 text-[10px] text-gray-500 hover:text-gray-200 md:opacity-0 md:group-hover:opacity-100 md:group-focus-within:opacity-100 md:focus-visible:opacity-100"
      >
        {if @followed, do: "Unfollow", else: "Follow"}
      </button>
      <button
        :if={@estate_id && @thread.athanor_id == @estate_id}
        type="button"
        phx-click="delete_thread"
        phx-value-id={@thread.id}
        class="shrink-0 py-2 text-gray-500 hover:text-red-400 md:opacity-0 md:group-hover:opacity-100 md:group-focus-within:opacity-100 md:focus-visible:opacity-100"
        data-confirm="Delete this thread for everyone?"
        aria-label="Delete"
      >
        ×
      </button>
    </li>
    """
  end
end
