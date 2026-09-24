# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.RoomFeed do
  @moduledoc """
  The room a page has open, told to the person's own AQUA beside it.

  The chat page hosts the room; the panel (`PrismWeb.AquaPanelLive`) and
  the pane inside it are nested LiveViews with mailboxes of their own. So
  the page announces what it shows on a topic of its own — one per page
  instance, named by the page's socket id — and whoever sits beside it
  listens. The room travels as a plain map with string keys, because it
  also rides the session a nested view mounts with: that is how the panel
  knows the room the moment it opens, before any announcement.

  One direction only: the room is read into the person's own thread. The
  feed carries a name and two ids, never a line of the tape — the excerpt
  is read at send time, under the person's own membership
  (`Aqua.RoomExcerpt`).
  """

  @typedoc "`athanor_id`, `thread_id`, and for display `title` and `estate`."
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

  @doc "A room as the page names it, for the session and the feed."
  @spec room(map(), map(), String.t() | nil) :: room()
  def room(%{id: athanor_id}, %{id: thread_id, title: title}, estate) do
    %{
      "athanor_id" => athanor_id,
      "thread_id" => thread_id,
      "title" => title,
      "estate" => estate
    }
  end

  @doc "How a room is named to the person: the estate, then the thread."
  @spec label(room() | nil) :: String.t()
  def label(%{} = room) do
    [room["estate"], room["title"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  def label(_), do: ""

  @doc "The room as `Aqua.RoomExcerpt.read/2` takes it."
  @spec excerpt_room(map()) :: Aqua.RoomExcerpt.room()
  def excerpt_room(%{"athanor_id" => athanor_id, "thread_id" => thread_id} = room) do
    %{
      athanor_id: athanor_id,
      thread_id: thread_id,
      title: room["title"],
      estate: room["estate"]
    }
  end
end
