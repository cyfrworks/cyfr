# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.Tray do
  @moduledoc """
  The per-session tray: how many things happened in each athanor a person
  belongs to while they were not looking at it. One small map per browser
  session, kept in `Arca.Cache` under a hash of the session token, so it
  survives every page navigation (the topbar remounts on each) and dies
  with the session. Nothing is derived from tables here — the counts are
  the notifies the topbar saw; opening an athanor clears its count.
  """

  @ttl_ms :timer.hours(24)

  @type badges :: %{optional(String.t()) => pos_integer()}

  @doc "The badges of a session."
  @spec get(String.t() | nil) :: badges()
  def get(token) when is_binary(token) do
    case Arca.Cache.get(key(token)) do
      {:ok, %{} = badges} -> badges
      _ -> %{}
    end
  end

  def get(_), do: %{}

  @doc "One more thing happened in `athanor_id`; returns the badges."
  @spec bump(String.t() | nil, String.t()) :: badges()
  def bump(token, athanor_id) when is_binary(token) and is_binary(athanor_id) do
    badges = Map.update(get(token), athanor_id, 1, &(&1 + 1))
    Arca.Cache.put(key(token), badges, @ttl_ms)
    badges
  end

  def bump(_, _), do: %{}

  @doc "The person opened `athanor_id`: its count is gone; returns the badges."
  @spec clear(String.t() | nil, String.t() | nil) :: badges()
  def clear(token, athanor_id) when is_binary(token) and is_binary(athanor_id) do
    badges = Map.delete(get(token), athanor_id)
    Arca.Cache.put(key(token), badges, @ttl_ms)
    badges
  end

  def clear(token, _), do: get(token)

  # The token itself never sits in a cache key.
  defp key(token), do: {:tray, :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)}
end
