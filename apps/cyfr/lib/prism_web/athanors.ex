# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.Athanors do
  @moduledoc """
  How an athanor is named on the console, once, to the person looking.

  The person's OWN athanor reads as "You" — the one their row names as
  theirs. No one, an operator included, opens another person's athanor,
  so no one is shown one as theirs; any other reads as its name.
  `PrismWeb.People.label/2` is the sibling for people.
  """

  alias Sanctum.Tenancy.Users

  @doc "The label for an athanor, to the person `ctx` names."
  @spec label(map(), Sanctum.Context.t() | nil) :: String.t()
  def label(%{id: id, name: name}, %{user_id: user_id}) when is_binary(user_id) do
    if Users.own_athanor?(user_id, id), do: "You", else: name
  end

  def label(%{name: name}, _ctx), do: name

  @doc "Whether the athanor is the person's own — the one their panel opens onto."
  @spec own?(map(), Sanctum.Context.t() | nil) :: boolean()
  def own?(%{id: id}, %{user_id: user_id}) when is_binary(user_id),
    do: Users.own_athanor?(user_id, id)

  def own?(_athanor, _ctx), do: false
end
