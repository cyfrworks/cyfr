# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaPanelLive do
  @moduledoc """
  The person's own AQUA, on every page: a floating button and, opened, a
  panel over the page onto their own athanor — the threads of You, one of
  them open as `PrismWeb.ConversationPaneLive` focused on You, whatever
  estate the page is on.

  Opened beside a room (the chat page tells it what is in view through
  `PrismWeb.RoomFeed`), a send from here carries a bounded excerpt of the
  room's tape as context for the turn — read under the person's own
  membership, into the private thread only, never kept — and an answer
  can be pasted onto the room, attributed to the person. The pane does
  both; the panel names the room and holds the list.

  Nested in the app layout, so it rides every authenticated page. Nothing
  here reads the page's focus: the panel establishes the session itself
  and narrows to the person's own athanor. A person with no athanor of
  their own has no panel.
  """

  use PrismWeb, :live_view

  alias Arca.ConversationStorage, as: Conversations
  alias Sanctum.Tenancy.Athanors

  @impl true
  def mount(_params, session, socket) do
    token = session[to_string(PrismWeb.SignInResponse.session_key())]
    room_feed = session["room_feed"]

    if connected?(socket) and is_binary(room_feed), do: PrismWeb.RoomFeed.subscribe(room_feed)

    socket =
      socket
      |> assign(:context, nil)
      |> assign(:athanor, nil)
      |> assign(:open, false)
      |> assign(:conversations, [])
      |> assign(:conversation, nil)
      |> assign(:room, session["room"])
      |> assign(:room_feed, room_feed)
      |> assign(:ui_mode, session["ui_mode"])

    {:ok, own(socket, token), layout: false}
  end

  # Your own athanor, focused. The session's default is whatever page this
  # is on; the panel is always You.
  defp own(socket, token) do
    with {:ok, ctx} <- PrismWeb.AuthHelpers.authenticate_session(token),
         {:ok, %{personal_athanor_id: id}} when is_binary(id) <-
           Sanctum.Tenancy.Users.get(ctx.user_id),
         {:ok, %{status: "active"} = athanor} <- Athanors.get(id),
         {:ok, focused} <- Sanctum.Context.focus(ctx, athanor) do
      socket |> assign(:context, focused) |> assign(:athanor, athanor)
    else
      _ -> socket
    end
  end

  # ============================================================================
  # Events
  # ============================================================================

  @impl true
  def handle_event("toggle", _params, %{assigns: %{open: true}} = socket) do
    {:noreply, assign(socket, :open, false)}
  end

  # The list is read when the panel opens, not on every page: closed, the
  # panel costs the page nothing.
  def handle_event("toggle", _params, socket) do
    conversations = Conversations.list(socket.assigns.context)

    {:noreply,
     socket
     |> assign(:open, true)
     |> assign(:conversations, conversations)
     |> assign(:conversation, List.first(conversations))}
  end

  def handle_event("select", %{"id" => ""}, socket) do
    {:noreply, assign(socket, :conversation, nil)}
  end

  def handle_event("select", %{"id" => id}, socket) do
    conversations = Conversations.list(socket.assigns.context)

    {:noreply,
     socket
     |> assign(:conversations, conversations)
     |> assign(:conversation, Enum.find(conversations, &(&1.id == id)))}
  end

  # ============================================================================
  # What the page shows, and what the pane tells the panel
  # ============================================================================

  @impl true
  def handle_info({:room_in_view, room}, socket), do: {:noreply, assign(socket, :room, room)}

  # The pane's first message created the thread: it is the open one now.
  def handle_info({:pane, _pane, {:opened, conv}}, socket) do
    {:noreply,
     socket
     |> assign(:conversations, Conversations.list(socket.assigns.context))
     |> assign(:conversation, conv)}
  end

  def handle_info({:pane, _pane, _message}, socket), do: {:noreply, socket}

  def handle_info(msg, socket) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(%{context: nil} = assigns) do
    ~H"""
    <div id="aqua-panel-root"></div>
    """
  end

  def render(assigns) do
    ~H"""
    <div id="aqua-panel-root">
      <button
        id="aqua-panel-button"
        type="button"
        phx-click="toggle"
        aria-expanded={to_string(@open)}
        aria-controls="aqua-panel-sheet"
        title="Your own AQUA — on your own athanor, wherever you are"
        class="fixed bottom-4 right-4 z-40 rounded-full bg-indigo-600 px-4 py-2 text-sm font-medium text-white shadow-lg hover:bg-indigo-500"
      >
        AQUA
      </button>

      <aside
        :if={@open}
        id="aqua-panel-sheet"
        role="dialog"
        aria-label="Your AQUA"
        class="fixed top-12 bottom-0 right-0 z-40 flex w-[28rem] max-w-full flex-col border-l border-gray-800 bg-gray-950 shadow-2xl"
      >
        <header class="flex items-center gap-2 border-b border-gray-800 px-3 py-2">
          <span class="shrink-0 text-sm font-medium text-gray-200">AQUA · You</span>
          <select
            id="aqua-panel-threads"
            name="id"
            phx-change="select"
            title="Your threads"
            class="min-w-0 flex-1 truncate rounded border border-gray-800 bg-gray-900 px-2 py-1 text-xs text-gray-300"
          >
            <option value="" selected={is_nil(@conversation)}>New thread</option>
            <option
              :for={conv <- @conversations}
              value={conv.id}
              selected={@conversation && conv.id == @conversation.id}
            >
              {conv.title}
            </option>
          </select>
          <button
            type="button"
            phx-click="toggle"
            aria-label="Close"
            class="rounded px-2 py-1 text-gray-400 hover:bg-gray-800 hover:text-gray-200"
          >
            ×
          </button>
        </header>

        <p
          :if={@room}
          id="aqua-panel-room"
          title="What your AQUA reads with each message you send here"
          class="truncate border-b border-gray-800 px-3 py-1 text-[11px] text-gray-500"
        >
          Reading {PrismWeb.RoomFeed.label(@room)}
        </p>

        {live_render(@socket, PrismWeb.ConversationPaneLive,
          id: "aqua-panel-pane-" <> ((@conversation && @conversation.id) || "new"),
          session: %{
            "athanor_id" => @athanor.id,
            "conversation_id" => @conversation && @conversation.id,
            "ui_mode" => @ui_mode,
            "panel" => true,
            "room_feed" => @room_feed,
            "room" => @room
          }
        )}
      </aside>
    </div>
    """
  end
end
