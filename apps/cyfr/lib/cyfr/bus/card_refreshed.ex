# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.CardRefreshed do
  @moduledoc """
  A placed card was refreshed, on `Cyfr.Bus.cards/2` of the person who
  placed it (`user_id`): the tincture it belongs to (`tincture`, the
  versionless reference), the card's name (`card`), the layout slot it
  sits in (`slot`) and the card as the desktop draws it (`data`,
  `Prima.Card.to_json/1`). Broadcast after the refresh completed.
  """

  alias Cyfr.Bus.Payload

  @kinds [:refreshed]
  @fields []

  @enforce_keys [:athanor_id, :kind, :tincture, :card, :slot, :user_id, :data]
  defstruct [:athanor_id, :kind, :tincture, :card, :slot, :user_id, :data | @fields]

  @type kind :: :refreshed

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          tincture: String.t(),
          card: String.t(),
          slot: String.t(),
          user_id: String.t(),
          data: map()
        }

  @doc "The closed union of what this payload says happened."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The payload for `actor`'s athanor: the card `card` of `tincture` in the
  slot `slot` of `user_id`'s layout, drawn as `data`.
  """
  @spec new(Prima.Actor.t(), %{
          tincture: String.t(),
          card: String.t(),
          slot: String.t(),
          user_id: String.t(),
          data: map()
        }) :: t()
  def new(%Prima.Actor{} = actor, %{} = refresh) do
    %{tincture: tincture, card: card, slot: slot, user_id: user_id, data: data} = refresh

    Payload.build(__MODULE__, @fields, %{}, %{
      athanor_id: Payload.athanor!(actor),
      kind: Payload.kind!(__MODULE__, :refreshed, @kinds),
      tincture: tincture,
      card: card,
      slot: slot,
      user_id: user_id,
      data: data
    })
  end
end
