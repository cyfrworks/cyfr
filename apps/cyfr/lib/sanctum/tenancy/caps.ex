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

  @doc """
  `:ok` while the athanor's storage, plus `incoming` bytes, stays under the
  `:athanor_storage_bytes` cap (or the cap is off). The one place the cap is
  computed: authenticated WASM writes, chat attachments and published
  component bytes all come here.

  An athanor's bytes live under two roots — `data/{athanor}` and
  `components/{athanor}` — and `roots:` says which to measure. The default
  `[:data]` is the writing hot path, where a second directory walk per write
  would be felt; publishing a component (rare, and the larger sink) measures
  `[:data, :components]`, so the cap bounds the whole athanor where it
  matters. The seeded bundle counts toward it.
  """
  @spec check_storage(Sanctum.Context.t(), non_neg_integer(), keyword()) ::
          :ok | {:error, {:limit_reached, :athanor_storage_bytes, pos_integer()}}
  def check_storage(%Sanctum.Context{} = ctx, incoming, opts \\ []) when is_integer(incoming) do
    case get(:athanor_storage_bytes) do
      nil ->
        :ok

      cap ->
        used = opts |> Keyword.get(:roots, [:data]) |> Enum.map(&used(ctx, &1)) |> Enum.sum()

        if used + incoming > cap,
          do: {:error, {:limit_reached, :athanor_storage_bytes, cap}},
          else: :ok
    end
  end

  defp used(ctx, :data), do: bytes_under(ctx, [])

  defp used(%{athanor_id: id} = ctx, :components) when is_binary(id) and id != "",
    do: bytes_under(ctx, ["components", id])

  defp used(_ctx, _root), do: 0

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
