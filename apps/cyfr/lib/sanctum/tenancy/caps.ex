# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.Caps do
  @moduledoc """
  The public-door caps: how many athanors a server holds, how many groups a
  person may create, how many members a group may hold, how many personal
  athanors may be minted per hour, and how many bytes an athanor may store.

  Read from `config :cyfr, :caps` (`CYFR_MAX_ATHANORS`,
  `CYFR_MAX_GROUPS_PER_PERSON`, `CYFR_MAX_MEMBERS_PER_GROUP`,
  `CYFR_MINT_PER_HOUR`, `CYFR_ATHANOR_STORAGE_BYTES`). A `nil` cap is off.
  A private box needs none of them; a `*` server sets them.

  The byte cap counts both of an athanor's subtrees — its data and its
  components, the seeded copies included — on every write, which is what
  `CYFR_ATHANOR_STORAGE_BYTES` claims to bound.
  """

  @type key ::
          :max_athanors
          | :max_groups_per_person
          | :max_members_per_group
          | :mint_per_hour
          | :athanor_storage_bytes

  @keys [
    :max_athanors,
    :max_groups_per_person,
    :max_members_per_group,
    :mint_per_hour,
    :athanor_storage_bytes
  ]

  @doc "The configured cap for `key`, or `nil` when off."
  @spec get(key()) :: pos_integer() | nil
  def get(key) when key in @keys do
    case Keyword.get(Application.get_env(:cyfr, :caps, []), key) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  @doc "`:ok` while `current` is below the cap (or the cap is off)."
  @spec check(key(), non_neg_integer()) :: :ok | {:error, {:limit_reached, key(), pos_integer()}}
  def check(key, current) when key in @keys and is_integer(current) do
    case get(key) do
      nil -> :ok
      cap when current < cap -> :ok
      cap -> {:error, {:limit_reached, key, cap}}
    end
  end

  # The component tree changes only when something writes to it, and
  # `Arca` invalidates this on every such write, so the walk happens once
  # per change rather than once per guest write. The TTL is a backstop for
  # bytes that arrive without passing through Arca at all.
  @components_usage_ttl_ms :timer.minutes(5)

  @doc """
  `:ok` while the athanor's storage, plus `incoming` bytes, stays under the
  `:athanor_storage_bytes` cap (or the cap is off). The one place the cap is
  computed: authenticated WASM writes, chat attachments and published
  component bytes all come here.

  An athanor's bytes live in two subtrees — its data and its components —
  and both are counted, the seeded copies included, because a cap that
  bounds one subtree is not a cap on the athanor. Data is walked live;
  components are read from a cache Arca invalidates on write, so the hot
  path pays for one walk, not two.
  """
  @spec check_storage(Sanctum.Context.t(), non_neg_integer()) ::
          :ok | {:error, {:limit_reached, :athanor_storage_bytes, pos_integer()}}
  def check_storage(%Sanctum.Context{} = ctx, incoming) when is_integer(incoming) do
    case get(:athanor_storage_bytes) do
      nil ->
        :ok

      cap ->
        if data_bytes(ctx) + components_bytes(ctx) + incoming > cap,
          do: {:error, {:limit_reached, :athanor_storage_bytes, cap}},
          else: :ok
    end
  end

  defp data_bytes(ctx), do: bytes_under(ctx, [])

  defp components_bytes(%{athanor_id: id} = ctx) when is_binary(id) and id != "" do
    key = Arca.Cache.Keys.components_usage(id)

    case Arca.Cache.get(key) do
      {:ok, bytes} when is_integer(bytes) ->
        bytes

      _ ->
        bytes = bytes_under(ctx, ["components", id])
        Arca.Cache.put(key, bytes, @components_usage_ttl_ms)
        bytes
    end
  end

  defp components_bytes(_ctx), do: 0

  defp bytes_under(ctx, segments) do
    case Arca.usage(ctx, segments) do
      {:ok, %{bytes: bytes}} when is_integer(bytes) -> bytes
      _ -> 0
    end
  end

  @doc "The keys, for config resolution."
  @spec keys() :: [key()]
  def keys, do: @keys
end
