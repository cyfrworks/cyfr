# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.People do
  @moduledoc """
  How a person is named on the console, once.

  A member row (`Sanctum.Tenancy.Members.list_by_athanor/1`, or the
  `member.list` verb's rows — atom or string keys) reads as its display
  name, else its email, else a shortened id; a bare user id reads the same
  way from the `users` row. The person looking reads as "You", the way the
  console already names their own estate — pass `nil` for `ctx` where no
  one in particular is looking (a log column, a table of who did what).
  """

  import PrismWeb.DisplayHelpers, only: [f: 2, truncate: 2]

  alias Sanctum.Tenancy.Users

  @id_width 24

  @doc "The label for a member row or a user id, to the person `ctx` names."
  @spec label(map() | String.t() | nil, Sanctum.Context.t() | nil) :: String.t()
  def label(%{} = member, ctx) do
    id = f(member, :user_id)

    if viewer?(id, ctx) do
      "You"
    else
      case first_present([f(member, :display_name), f(member, :email)]) do
        nil -> fallback(id)
        name -> name
      end
    end
  end

  def label(user_id, ctx) when is_binary(user_id) do
    case Users.get(user_id) do
      {:ok, user} ->
        label(%{user_id: user.id, display_name: user.display_name, email: user.email}, ctx)

      _ ->
        label(%{user_id: user_id}, ctx)
    end
  end

  def label(nil, _ctx), do: Users.display_name(nil)

  defp viewer?(id, %{user_id: user_id}) when is_binary(id), do: id == user_id
  defp viewer?(_id, _ctx), do: false

  # Nothing to call the person by but their id — shortened — or, with no
  # id at all, the one word the tenancy uses for nobody in particular.
  @spec fallback(term()) :: String.t()
  defp fallback(id) when is_binary(id), do: truncate(id, @id_width)
  defp fallback(_id), do: Users.display_name(nil)

  # The first non-empty string, matched rather than tested for truth, so
  # the type of what comes back is the type of what was found.
  @spec first_present([term()]) :: String.t() | nil
  defp first_present([value | _rest]) when is_binary(value) and value != "", do: value
  defp first_present([_other | rest]), do: first_present(rest)
  defp first_present([]), do: nil
end
