# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.RoomInView do
  @moduledoc """
  The room a page has open, told to the person's own assistant beside it
  on the page-local `Cyfr.Bus.room_feed/1`. `room` is the page's plain
  map (`PrismWeb.RoomFeed`) — a name and two ids, never a line of the
  tape — or nil when no thread is open.
  """

  alias Cyfr.Bus.Payload

  @kinds [:room]

  @enforce_keys [:kind]
  defstruct [:kind, :room]

  @type kind :: :room
  @type t :: %__MODULE__{kind: kind(), room: %{optional(String.t()) => String.t() | nil} | nil}

  @doc "The closed union: the room in view."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "`room` is in view; nil when no thread is open."
  @spec new(map() | nil) :: t()
  def new(room) when is_map(room) or is_nil(room),
    do: %__MODULE__{kind: Payload.kind!(__MODULE__, :room, @kinds), room: room}
end
