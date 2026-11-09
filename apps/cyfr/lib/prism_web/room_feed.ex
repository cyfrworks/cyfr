# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.RoomFeed do
  @moduledoc """
  The shared thread a page has open, told to the person's own AQUA
  beside it.

  The chat overlay (`PrismWeb.ChatOverlayLive`) shows the shared thread;
  the panel (`PrismWeb.AquaPanelLive`) and the pane inside it are nested
  LiveViews of the same desktop with mailboxes of their own. So the chat
  announces what it shows on a topic of the desktop's — one per desktop
  instance, named by the desktop's socket id (`PrismWeb.ShellLive`) — and
  whoever sits beside it listens. It travels as a plain map with string keys, `shared_thread_id`
  and `title`, the shape the `thread` tool's `send` takes as its `room`,
  because it also rides the session a nested view mounts with: that is
  how the panel knows the thread the moment it opens, before any
  announcement.

  One direction only: the shared thread is read into the person's own
  thread. The feed carries a title and an id, never a line of what was
  said — the excerpt is read at send time, under the person's own seat
  (`Aqua.room_excerpt/2`).
  """

  @typedoc "`shared_thread_id`, and for display `title`."
  @type room :: %{optional(String.t()) => String.t() | nil}

  @doc """
  The topic a page announces on — its own, so two tabs never cross
  (`Cyfr.Bus.room_feed/1`, page-local).
  """
  @spec topic(String.t()) :: String.t()
  def topic(host_id) when is_binary(host_id), do: Cyfr.Bus.room_feed(host_id)

  @doc "Listen on a page's feed; each announcement arrives as `%Cyfr.Bus.RoomInView{}`."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic) when is_binary(topic), do: Cyfr.Bus.subscribe_page(topic)

  @doc "Tell the listeners what the page shows now; `nil` when no thread is open."
  @spec announce(String.t(), room() | nil) :: :ok
  def announce(topic, room) when is_binary(topic),
    do: Cyfr.Bus.broadcast_page(topic, Cyfr.Bus.RoomInView.new(room))

  @doc "A shared thread as the page names it (`title`), for the session and the feed."
  @spec room(String.t(), String.t() | nil) :: room()
  def room(thread_id, title) when is_binary(thread_id),
    do: %{"shared_thread_id" => thread_id, "title" => title}

  @doc "How the shared thread is named to the person."
  @spec label(room() | nil) :: String.t()
  def label(%{"title" => title}) when is_binary(title), do: title
  def label(_), do: ""
end
