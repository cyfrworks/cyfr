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

  Every verb takes an opaque session hash from `session_hash/1`.
  LiveView assigns must not retain the raw bearer token.
  """

  @ttl_ms :timer.hours(24)

  @type badges :: %{optional(String.t()) => pos_integer()}

  @doc "The per-session tray name derived from a session token."
  @spec session_hash(String.t() | nil) :: String.t() | nil
  def session_hash(token) when is_binary(token), do: Cyfr.Digest.sha256_hex(token)
  def session_hash(_), do: nil

  @doc "The badges of a session."
  @spec get(String.t() | nil) :: badges()
  def get(hash) when is_binary(hash) do
    case Arca.Cache.get(key(hash)) do
      {:ok, %{} = badges} -> badges
      _ -> %{}
    end
  end

  def get(_), do: %{}

  @doc "One more thing happened in `athanor_id`; returns the badges."
  @spec bump(String.t() | nil, String.t()) :: badges()
  def bump(hash, athanor_id) when is_binary(hash) and is_binary(athanor_id) do
    badges = Map.update(get(hash), athanor_id, 1, &(&1 + 1))
    Arca.Cache.put(key(hash), badges, @ttl_ms)
    badges
  end

  def bump(_, _), do: %{}

  @doc "The person opened `athanor_id`: its count is gone; returns the badges."
  @spec clear(String.t() | nil, String.t() | nil) :: badges()
  def clear(hash, athanor_id) when is_binary(hash) and is_binary(athanor_id) do
    badges = Map.delete(get(hash), athanor_id)
    Arca.Cache.put(key(hash), badges, @ttl_ms)
    badges
  end

  def clear(hash, _), do: get(hash)

  defp key(hash), do: {:tray, hash}
end
