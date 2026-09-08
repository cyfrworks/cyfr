# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.Estates do
  @moduledoc """
  How an estate is named on the console, once, to the person looking.

  The person's OWN athanor reads as "You" — theirs, not any person-kind
  athanor: an operator opening someone else's estate must never be told
  it is theirs. A DM (a frozen pair) reads as the other person's name, a
  group as its own. `PrismWeb.People.label/2` is the sibling for people.
  """

  alias Sanctum.Tenancy.Members
  alias Sanctum.Tenancy.Users

  @doc "The label for an athanor, to the person `ctx` names."
  @spec label(map(), Sanctum.Context.t() | nil) :: String.t()
  def label(%{id: id} = athanor, %{user_id: user_id} = ctx) when is_binary(user_id) do
    cond do
      Users.own_athanor?(user_id, id) -> "You"
      athanor.roster == "frozen" -> pair_label(athanor, ctx)
      true -> athanor.name
    end
  end

  def label(%{name: name}, _ctx), do: name

  # A DM reads as the other person, named the way every person on the
  # console is named (`PrismWeb.People.label/2`) — one ladder, not a
  # second one for pairs. A pair the viewer is not in (an operator's open)
  # keeps its stored name.
  defp pair_label(%{id: id, name: name}, %{user_id: user_id} = ctx) do
    with {:ok, rows} <- Members.list_by_athanor(id),
         %{user_id: other} <- Enum.find(rows, &(&1.user_id != user_id and &1.status == "active")) do
      PrismWeb.People.label(other, ctx)
    else
      _ -> name
    end
  end

  @doc "Whether the athanor is the person's own — the one their panel opens onto."
  @spec own?(map(), Sanctum.Context.t() | nil) :: boolean()
  def own?(%{id: id}, %{user_id: user_id}) when is_binary(user_id),
    do: Users.own_athanor?(user_id, id)

  def own?(_athanor, _ctx), do: false
end
