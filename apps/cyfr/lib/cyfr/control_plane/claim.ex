# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ControlPlane.Claim do
  @moduledoc """
  The control-plane lease row:
  `{"owner": boot, "expires_at": iso8601, "generation": n}` under one key of
  `Arca.ServerMetaStorage`, written only by conditional statements so two
  boots cannot both believe they hold it.

  The generation rises by one with every claim — a boot taking the plane,
  or taking it back after its lease lapsed — and is kept by renewals and
  release, so whatever a holder issued under an earlier generation is
  recognisably older than what the current holder issues.
  """

  @key "control_plane_owner"

  @doc """
  Take the lease for `me` under the next generation: an absent row is
  recorded at generation 1, an expired row or one already `me`'s is
  replaced one generation up, a live row held by another boot refuses with
  `{:error, {:held, owner, until}}`.

  A row that cannot be read — the store fails, or what it holds does not
  decode — refuses with `{:error, :unavailable}` and writes nothing: its
  generation is unknown, and a claim at generation 1 would reissue a
  generation an earlier holder already used.
  """
  @spec claim(String.t(), pos_integer()) ::
          {:ok, DateTime.t(), pos_integer()}
          | {:error, {:held, String.t(), DateTime.t()} | :unavailable | :racing | term()}
  def claim(me, lease_ms), do: claim(me, lease_ms, 2)

  defp claim(_me, _lease_ms, 0), do: {:error, :racing}

  defp claim(me, lease_ms, attempts) do
    retry = fn -> claim(me, lease_ms, attempts - 1) end

    case Arca.ServerMetaStorage.get(@key) do
      {:error, :not_found} ->
        {value, expires_at} = lease(me, lease_ms, 1)

        case Arca.ServerMetaStorage.put_new(@key, value) do
          {:ok, :recorded} -> {:ok, expires_at, 1}
          {:error, :exists} -> retry.()
          {:error, reason} -> {:error, reason}
        end

      {:ok, previous} ->
        case decode(previous) do
          {:ok, owner, until, generation} ->
            if owner == me or DateTime.compare(DateTime.utc_now(), until) != :lt do
              replace(previous, me, lease_ms, generation + 1, retry)
            else
              {:error, {:held, owner, until}}
            end

          :error ->
            {:error, :unavailable}
        end

      {:error, _unreadable} ->
        {:error, :unavailable}
    end
  end

  @doc "Push `me`'s lease out; `:lost` when the row is no longer `me`'s."
  @spec renew(String.t(), pos_integer()) :: {:ok, DateTime.t()} | :lost
  def renew(me, lease_ms) do
    with {:ok, previous} <- Arca.ServerMetaStorage.get(@key),
         {:ok, ^me, _until, generation} <- decode(previous),
         {value, expires_at} = lease(me, lease_ms, generation),
         :ok <- Arca.ServerMetaStorage.compare_and_put(@key, previous, value) do
      {:ok, expires_at}
    else
      _ -> :lost
    end
  end

  @doc """
  Give `me`'s lease up: the row is left already expired, so the next boot
  claims it at once. `:not_held` when the row is no longer `me`'s.
  """
  @spec release(String.t()) :: :ok | :not_held | {:error, term()}
  def release(me) do
    case Arca.ServerMetaStorage.get(@key) do
      {:ok, previous} ->
        case decode(previous) do
          {:ok, ^me, _until, generation} ->
            {value, _expired} = lease(me, -1, generation)

            case Arca.ServerMetaStorage.compare_and_put(@key, previous, value) do
              :ok -> :ok
              {:error, :stale} -> :not_held
              {:error, reason} -> {:error, reason}
            end

          _ ->
            :not_held
        end

      {:error, :not_found} ->
        :not_held

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The current holder, for diagnostics: `:none` when no boot has recorded a
  claim, `{:error, :unavailable}` when the row cannot be read.
  """
  @spec holder() :: {:ok, String.t(), DateTime.t()} | :none | {:error, :unavailable}
  def holder do
    case Arca.ServerMetaStorage.get(@key) do
      {:ok, raw} ->
        case decode(raw) do
          {:ok, owner, until, _generation} -> {:ok, owner, until}
          :error -> {:error, :unavailable}
        end

      {:error, :not_found} ->
        :none

      {:error, _unreadable} ->
        {:error, :unavailable}
    end
  end

  defp replace(previous, me, lease_ms, generation, retry) do
    {value, expires_at} = lease(me, lease_ms, generation)

    case Arca.ServerMetaStorage.compare_and_put(@key, previous, value) do
      :ok -> {:ok, expires_at, generation}
      {:error, :stale} -> retry.()
      {:error, reason} -> {:error, reason}
    end
  end

  defp lease(me, lease_ms, generation) do
    expires_at = DateTime.add(DateTime.utc_now(), lease_ms, :millisecond)

    value = %{
      "owner" => me,
      "expires_at" => DateTime.to_iso8601(expires_at),
      "generation" => generation
    }

    {Jason.encode!(value), expires_at}
  end

  defp decode(raw) do
    with {:ok, %{"owner" => owner, "expires_at" => iso, "generation" => generation}}
         when is_binary(owner) and is_integer(generation) and generation > 0 <- Jason.decode(raw),
         {:ok, until, _} <- DateTime.from_iso8601(iso) do
      {:ok, owner, until, generation}
    else
      _ -> :error
    end
  end
end
