# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ChatOverlayLive do
  @moduledoc """
  The chat: CYFR's own overlay of the threads a person shares with people,
  beside AQUA's (`PrismWeb.AquaPanelLive`), which is the person with their
  assistant. A nested LiveView of the desktop (`PrismWeb.ShellLive`), so it
  stays while the person moves between the pages drawn over the desktop.

  Its control stands at the shelf's right end (`#chat-button`, in the
  shelf's chrome) with the number of the person's shared threads that hold
  a message someone else posted after the person last had that thread
  open here (`#chat-unread`). Opened, it is a panel on the desk and a sheet
  that fills the screen in the hand (`#chat-sheet`): the list of the
  person's pairs, each by the other person's name, then their shared
  threads by title (`shared_thread.list`), each with its unread count;
  the people they share a thread with, a click on whom finds or makes the
  pair of the two of them (`shared_thread.pair`); and "New thread with
  people", which makes a thread with a title (`shared_thread.create`) and
  adds the people named (`shared_thread.add`). A thread opens in place as
  `PrismWeb.SharedThreadLive`, under the person's own seat, which holds
  every sharing act as a plain click in CYFR's code: the invitation link,
  adding a person, removing one, leaving and archiving. On the desk the
  list stands beside the open thread; in the hand the thread takes the
  sheet, with a way back to the list.

  While the overlay shows a thread, the person's read mark in it is moved
  to its newest message (`Sanctum.SharedThreads.mark_read/2`), on opening
  it and on each message posted to it while it is shown; the mark is the
  thread owner's, on the person's seat, and `threads.changes` reads it as
  `unread`. The counts are read again on every change of the person's
  shared threads (`Cyfr.Bus.SharedThreadChanged`, their mark's own moves
  included), never polled.

  The thread the overlay shows is told to the person's own AQUA beside it
  on the desktop's own topic (`PrismWeb.RoomFeed`, the session's
  `room_feed`), by its id and title only, and `nil` once the overlay is
  closed or shows none. No frame is opened here and no message body
  leaves CYFR's code: the overlay is the desktop's own page code, given no
  frame port and no bridge hook. Escape from inside the sheet and its ×
  close it; a click elsewhere leaves it open.
  """

  use PrismWeb, :live_view

  on_mount {CyfrWeb.ContextGuard, :protected}

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(:room_feed, session["room_feed"])
      |> assign(:open, false)
      |> assign(:threads, [])
      |> assign(:people, [])
      |> assign(:unread, %{})
      |> assign(:shared, nil)
      |> assign(:with_people?, false)
      |> assign(:error, nil)

    if connected?(socket) do
      Cyfr.Bus.subscribe_global(Cyfr.Bus.shared_threads(socket.assigns.context.user_id))
      {:ok, load(socket), layout: false}
    else
      {:ok, socket, layout: false}
    end
  end

  # ============================================================================
  # What the overlay lists
  # ============================================================================

  # The active shared threads the person sits in, pairs first by the other
  # person's name, then the rest by title; how many of each hold a message
  # posted after the person's read mark; and the people they share a
  # thread with. A list that cannot be read is said once and the rows stay
  # as they were.
  defp load(socket) do
    ctx = socket.assigns.context

    socket =
      case PrismWeb.Ops.fetch_list(socket, "shared_thread/list", :threads) do
        {:ok, threads} ->
          rows =
            for %{status: "active"} = thread <- threads do
              %{id: thread.id, kind: thread.kind, label: shared_label(thread)}
            end
            |> Enum.sort_by(&{&1.kind != "pair", String.downcase(&1.label)})

          socket |> assign(:threads, rows) |> assign(:error, nil)

        {:error, message} ->
          assign(socket, :error, "Your shared threads could not be read: #{message}")
      end

    socket =
      case Sanctum.SharedThreads.listed(ctx.user_id) do
        {:ok, listings} -> assign(socket, :unread, Map.new(listings, &{&1.id, &1.unread || 0}))
        {:error, _unread} -> socket
      end

    case Sanctum.SharedThreads.people_in_threads_with(ctx.user_id) do
      {:ok, people} ->
        assign(
          socket,
          :people,
          for(person <- people, do: %{user_id: person.user_id, label: PrismWeb.People.label(person, ctx)})
        )

      {:error, _unread} ->
        socket
    end
  end

  defp shared_label(%{kind: "pair", with: %{name: name}}), do: name
  defp shared_label(%{title: title}) when is_binary(title), do: title
  defp shared_label(_thread), do: "Thread"

  # How many of the person's threads hold a message they have not had open.
  defp unread_threads(%{threads: threads, unread: unread}),
    do: Enum.count(threads, &(Map.get(unread, &1.id, 0) > 0))

  # ============================================================================
  # Opening a thread, and the read mark
  # ============================================================================

  # A thread, read under the person's own seat: one they do not sit in
  # answers as a missing one. Shown, its read mark moves to its newest
  # message and AQUA beside the desktop is told what is open.
  defp open_shared(socket, thread_id) do
    case PrismWeb.Ops.call_tool(socket, "shared_thread/get", %{"thread" => thread_id}) do
      {:ok, %{status: "active"} = thread} ->
        socket
        |> assign(:shared, %{id: thread.id, kind: thread.kind, label: shared_label(thread)})
        |> assign(:error, nil)
        |> mark_read()
        |> announce()

      {:ok, _archived} ->
        assign(socket, :error, "That thread has been archived.")

      {:error, reason} ->
        assign(socket, :error, "That thread cannot be opened: #{error_message(reason)}")
    end
  end

  # The person has the thread open in front of them: everything in it is
  # read. A mark that cannot move is left for the next showing; the count
  # stays as the store last said.
  defp mark_read(%{assigns: %{open: true, shared: %{id: id}}} = socket) do
    case Sanctum.SharedThreads.mark_read(socket.assigns.context.user_id, id) do
      :ok -> update(socket, :unread, &Map.put(&1, id, 0))
      {:error, _not_marked} -> socket
    end
  end

  defp mark_read(socket), do: socket

  # What AQUA beside the desktop reads: the thread the overlay shows, by
  # its id and title, or nothing while it is closed or shows none.
  defp announce(%{assigns: %{room_feed: feed}} = socket) when is_binary(feed) do
    room =
      case socket.assigns do
        %{open: true, shared: %{id: id, label: label}} -> PrismWeb.RoomFeed.room(id, label)
        _none -> nil
      end

    PrismWeb.RoomFeed.announce(feed, room)
    socket
  end

  defp announce(socket), do: socket

  # ============================================================================
  # Events
  # ============================================================================

  @impl true
  def handle_event("toggle", _params, %{assigns: %{open: true}} = socket),
    do: handle_event("close", %{}, socket)

  def handle_event("toggle", _params, socket) do
    {:noreply, socket |> assign(:open, true) |> load() |> mark_read() |> announce()}
  end

  def handle_event("close", _params, socket) do
    {:noreply, socket |> assign(:open, false) |> announce()}
  end

  def handle_event("open_shared", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, open_shared(socket, id)}
  end

  # Back to the list, in the hand, where the thread took the sheet.
  def handle_event("back", _params, socket) do
    {:noreply, socket |> assign(:shared, nil) |> announce()}
  end

  # Click a person → the pair of the two of you, found or made, and opened
  # here. The tool decides reachability ("someone you already share a
  # thread with").
  def handle_event("open_dm", %{"user-id" => user_id}, socket) do
    case call_tool(socket, "shared_thread/pair", %{"user" => user_id}) do
      {:ok, %{id: id}} -> {:noreply, socket |> load() |> open_shared(id)}
      {:error, reason} -> {:noreply, assign(socket, :error, "Could not open a pair: #{error_message(reason)}")}
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
        socket
        |> assign(:with_people?, false)
        |> load()
        |> open_shared(id)

      if unadded == [],
        do: {:noreply, socket},
        else: {:noreply, assign(socket, :error, "Not added: " <> Enum.join(unadded, "; "))}
    else
      {:error, sentence} when is_binary(sentence) ->
        {:noreply, assign(socket, :error, sentence)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Could not make the thread: #{error_message(reason)}")}
    end
  end

  def handle_event("dismiss_error", _params, socket), do: {:noreply, assign(socket, :error, nil)}

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

  # ============================================================================
  # The person's shared threads moved
  # ============================================================================

  # A message posted to the thread the overlay shows is read as it lands;
  # any other change, the person's own mark moving included, reads the
  # lists and the counts again, and the thread in view again under their
  # seat — renamed, archived, or no longer theirs.
  @impl true
  def handle_info(%Cyfr.Bus.SharedThreadChanged{kind: kind, thread_id: id}, socket) do
    socket =
      case socket.assigns.shared do
        %{id: ^id} when kind == :posted -> socket |> load() |> mark_read()
        %{id: ^id} when kind == :changed -> socket |> load() |> reread(id)
        _other -> load(socket)
      end

    {:noreply, socket}
  end

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  defp reread(socket, id) do
    case PrismWeb.Ops.call_tool(socket, "shared_thread/get", %{"thread" => id}) do
      {:ok, %{status: "active"} = thread} ->
        label = shared_label(thread)

        if label == socket.assigns.shared.label,
          do: socket,
          else: socket |> update(:shared, &%{&1 | label: label}) |> announce()

      {:ok, _archived} ->
        socket
        |> assign(:shared, nil)
        |> assign(:error, "That thread has been archived.")
        |> announce()

      {:error, {:unavailable, _what}} ->
        socket

      {:error, _gone} ->
        socket
        |> assign(:shared, nil)
        |> assign(:error, "You are no longer in that thread.")
        |> announce()
    end
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :unread_threads, unread_threads(assigns))

    ~H"""
    <div id="chat-overlay-root" class="contents">
      <button
        id="chat-button"
        type="button"
        phx-click="toggle"
        aria-expanded={to_string(@open)}
        aria-controls={@open && "chat-sheet"}
        title="Your threads with people"
        class="shelf-end-button"
      >
        Chat
        <span
          :if={@unread_threads > 0}
          id="chat-unread"
          class="shelf-end-count"
          aria-label={"#{@unread_threads} with unread messages"}
        >
          {@unread_threads}
        </span>
      </button>

      <aside
        :if={@open}
        id="chat-sheet"
        role="dialog"
        aria-label="Chat"
        tabindex="-1"
        phx-keydown="close"
        phx-key="Escape"
        data-showing={if @shared, do: "thread", else: "list"}
        class="chat-sheet z-[70] flex flex-col text-text-primary focus:outline-none"
      >
        <header class="flex h-[42px] shrink-0 items-center gap-2 border-b border-border-default pl-3 pr-2">
          <button
            :if={@shared}
            type="button"
            id="chat-back"
            phx-click="back"
            class="chat-back aqua-panel-ghost text-sm"
            aria-label="Back to your threads"
            title="Back to your threads"
          >
            ‹
          </button>
          <span class="shrink-0 text-sm font-semibold">Chat</span>
          <span :if={@shared} class="min-w-0 truncate text-xs text-text-secondary">
            {@shared.label}
          </span>
          <span class="flex-1"></span>
          <button
            id="chat-close"
            type="button"
            phx-click={Phoenix.LiveView.JS.push("close") |> Phoenix.LiveView.JS.focus(to: "#chat-button")}
            aria-label="Close"
            title="Close (Esc)"
            class="aqua-panel-ghost text-sm"
          >
            ×
          </button>
        </header>

        <p
          :if={@error}
          id="chat-error"
          role="alert"
          phx-click="dismiss_error"
          class="shrink-0 cursor-pointer border-b border-border-default bg-red-950/40 px-3 py-1.5 text-xs text-red-200"
        >
          {@error}
        </p>

        <div class="flex min-h-0 flex-1">
          <nav id="chat-list" class="chat-list flex flex-col overflow-y-auto" aria-label="Your threads">
            <section id="chat-threads">
              <div class="flex items-center justify-between pl-3 pr-2 py-1.5">
                <span class="text-xs uppercase tracking-wider text-text-muted">With people</span>
                <button
                  type="button"
                  id="new-with-people"
                  phx-click="toggle_with_people"
                  aria-expanded={to_string(@with_people?)}
                  class="min-h-6 rounded px-2 py-1 text-xs text-text-secondary hover:bg-surface-overlay hover:text-text-primary"
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
                  class="w-full rounded border border-border-default bg-surface-base px-2 py-1 text-xs text-text-primary placeholder-text-muted"
                />
                <input
                  type="text"
                  name="people"
                  placeholder="Names, separated by commas"
                  aria-label="People, by name"
                  class="w-full rounded border border-border-default bg-surface-base px-2 py-1 text-xs text-text-primary placeholder-text-muted"
                />
                <button
                  type="submit"
                  class="min-h-6 rounded bg-accent-primary px-2 py-1 text-xs text-white hover:bg-accent-hover"
                >
                  Start the thread
                </button>
              </form>
              <p :if={@threads == []} class="px-3 py-2 text-xs text-text-muted">
                You share no thread with anyone yet.
              </p>
              <ul :if={@threads != []}>
                <li :for={row <- @threads} id={"shared-thread-" <> row.id}>
                  <% open? = @shared && @shared.id == row.id %>
                  <% count = Map.get(@unread, row.id, 0) %>
                  <button
                    type="button"
                    phx-click="open_shared"
                    phx-value-id={row.id}
                    aria-current={open? && "true"}
                    class={[
                      "flex min-h-8 w-full items-center gap-2 px-3 py-1.5 text-left text-xs hover:bg-surface-overlay",
                      if(open?, do: "bg-surface-overlay text-text-primary", else: "text-text-secondary")
                    ]}
                  >
                    <span class={["truncate", count > 0 && "font-semibold text-text-primary"]}>
                      {row.label}
                    </span>
                    <span :if={row.kind == "pair"} class="text-[10px] text-text-muted">DM</span>
                    <span
                      :if={count > 0}
                      data-unread={count}
                      class="shelf-end-count ml-auto"
                      aria-label={"#{count} unread"}
                    >
                      {count}
                    </span>
                  </button>
                </li>
              </ul>
            </section>

            <section :if={@people != []} id="chat-people" class="border-t border-border-default">
              <p class="px-3 py-1.5 text-xs uppercase tracking-wider text-text-muted">People</p>
              <ul>
                <li :for={person <- @people}>
                  <button
                    type="button"
                    phx-click="open_dm"
                    phx-value-user-id={person.user_id}
                    class="flex min-h-8 w-full items-center px-3 py-1.5 text-xs text-text-secondary hover:bg-surface-overlay hover:text-text-primary"
                    title={"Message #{person.label}"}
                  >
                    <span class="truncate">{person.label}</span>
                  </button>
                </li>
              </ul>
            </section>
          </nav>

          <div id="chat-thread" class="chat-thread flex min-w-0 flex-1 flex-col">
            <%= if @shared do %>
              {live_render(@socket, PrismWeb.SharedThreadLive,
                id: "chat-thread-" <> @shared.id,
                container: {:div, class: "flex min-h-0 flex-1 flex-col"},
                session: %{"thread_id" => @shared.id}
              )}
            <% else %>
              <div class="flex flex-1 items-center justify-center px-6 text-center text-xs text-text-muted">
                Open a thread to read it here.
              </div>
            <% end %>
          </div>
        </div>
      </aside>
    </div>
    """
  end
end
