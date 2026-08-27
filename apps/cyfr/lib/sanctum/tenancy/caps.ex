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
  A private box needs none of them; a `*` server sets them — and a default
  install therefore has NO total-byte ceiling on authenticated guest
  writes (only the per-call `max_request_size` and the per-scope file
  backstop): an operator exposing the box sets
  `CYFR_ATHANOR_STORAGE_BYTES` deliberately.

  The byte cap counts the athanor's whole tree — every scope — on every
  write, which is what `CYFR_ATHANOR_STORAGE_BYTES` claims to bound.
  Seeded components and templates the athanor has not materialized live
  in the seed tree and cost it nothing; a copy-on-write materialization
  is charged at materialization time (`Arca.Overlay` consults this cap
  for the copied bytes). The check is check-then-write, deliberately
  unlocked: concurrent writers can overshoot by at most writers × the
  per-call size ceiling, because every successful write bumps the cached
  total before the next check reads it — a per-athanor reservation lock
  would serialize all tenant writes to close that sliver.
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

  # `Arca` keeps this current without re-walking: every successful tenant
  # write bumps the cached total by the bytes written (over-counting an
  # overwrite — the safe direction), and deletes drop it so reclaimed space
  # is recomputed. The TTL bounds the overwrite drift and backstops bytes
  # that arrive without passing through Arca at all.
  @athanor_usage_ttl_ms :timer.minutes(5)

  @doc """
  `:ok` while the athanor's storage, plus `incoming` bytes, stays under the
  `:athanor_storage_bytes` cap (or the cap is off). The one place the cap is
  computed — and, deliberately, enforced only at the user-ingress writers:
  authenticated WASM writes (`Opus.StorageHandler`), chat attachments
  (`Prism.Attachments`), and every unit commit that states
  `cap: {:checked, bytes}` — the `Compendium.Registry` publish paths
  (which the OCI pull rides, whole incoming unit counted) and the
  overlay's copy-on-write materialization (`Arca.Overlay.commit_unit/4`,
  where each ingress's policy is a required, visible argument).
  Cap-exempt writers — scaffold, fork, build-artifact stores — write
  uncapped by design: they move operator-shipped or build-derived bytes,
  and failing them half-completes a provision or a publish, which is
  worse than any over-cap state. Their bytes still count — usage
  accounting in `Arca` sees every tenant write.

  The count is one walk of the athanor's whole tree — components, guest
  files, attachments, because a cap that bounds one subtree is not a cap
  on the athanor; unmaterialized seed units are not in it — read from a
  cache that `Arca` keeps current per write (bytes bumped on writes,
  dropped on deletes), so the hot path pays no walk at all.
  """
  @spec check_storage(Sanctum.Context.t(), non_neg_integer()) ::
          :ok
          | {:error, {:limit_reached, :athanor_storage_bytes, pos_integer()}}
          | {:error, :storage_unverifiable}
  def check_storage(%Sanctum.Context{} = ctx, incoming) when is_integer(incoming) do
    case get(:athanor_storage_bytes) do
      nil ->
        :ok

      cap ->
        case athanor_bytes(ctx) do
          {:ok, bytes} when bytes + incoming > cap ->
            {:error, {:limit_reached, :athanor_storage_bytes, cap}}

          {:ok, _bytes} ->
            :ok

          {:error, :storage_unverifiable} = error ->
            error
        end
    end
  end

  defp athanor_bytes(%{athanor_id: id} = ctx) when is_binary(id) and id != "" do
    key = Arca.Cache.Keys.athanor_usage(id)

    case Arca.Cache.get(key) do
      {:ok, bytes} when is_integer(bytes) ->
        {:ok, bytes}

      _ ->
        case Arca.usage(ctx, []) do
          {:ok, %{bytes: bytes}} when is_integer(bytes) ->
            Arca.Cache.put(key, bytes, @athanor_usage_ttl_ms)
            {:ok, bytes}

          other ->
            # Fail CLOSED: this only runs with a cap configured, and a
            # walk that cannot answer must refuse the write — treating an
            # unreadable tree as empty would let writes march past the
            # ceiling. The failure is never cached: the next check walks
            # again.
            require Logger

            Logger.warning(
              "[Sanctum.Tenancy.Caps] usage walk failed for #{ctx.athanor_id}: " <>
                "#{inspect(other)}; refusing capped writes until it answers"
            )

            {:error, :storage_unverifiable}
        end
    end
  end

  defp athanor_bytes(_ctx), do: {:ok, 0}

  @doc "The keys, for config resolution."
  @spec keys() :: [key()]
  def keys, do: @keys
end
