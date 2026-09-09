# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ControlPlane.Claim do
  @moduledoc """
  The control-plane lease row: `{"owner": boot, "expires_at": iso8601}`
  under one key of `Arca.ServerMetaStorage`, written only by conditional
  statements so two boots cannot both believe they hold it.
  """

  @key "control_plane_owner"

  @doc """
  Take the lease for `me`: an absent row is recorded, an expired row or
  one already `me`'s is replaced, a live row held by another boot refuses
  with `{:error, {:held, owner, until}}`.
  """
  @spec claim(String.t(), pos_integer()) ::
          {:ok, DateTime.t()} | {:error, {:held, String.t(), DateTime.t()} | term()}
  def claim(me, lease_ms), do: claim(me, lease_ms, 2)

  defp claim(_me, _lease_ms, 0), do: {:error, :racing}

  defp claim(me, lease_ms, attempts) do
    {value, expires_at} = lease(me, lease_ms)

    case Arca.ServerMetaStorage.get(@key) do
      {:error, :not_found} ->
        case Arca.ServerMetaStorage.put_new(@key, value) do
          {:ok, :recorded} -> {:ok, expires_at}
          {:error, :exists} -> claim(me, lease_ms, attempts - 1)
          {:error, reason} -> {:error, reason}
        end

      {:ok, previous} ->
        case decode(previous) do
          {:ok, owner, until} ->
            if owner == me or DateTime.compare(DateTime.utc_now(), until) != :lt do
              replace(previous, value, expires_at, fn -> claim(me, lease_ms, attempts - 1) end)
            else
              {:error, {:held, owner, until}}
            end

          :error ->
            # An unreadable row is nobody's: replace it.
            replace(previous, value, expires_at, fn -> claim(me, lease_ms, attempts - 1) end)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Push `me`'s lease out; `:lost` when the row is no longer `me`'s."
  @spec renew(String.t(), pos_integer()) :: {:ok, DateTime.t()} | :lost
  def renew(me, lease_ms) do
    {value, expires_at} = lease(me, lease_ms)

    with {:ok, previous} <- Arca.ServerMetaStorage.get(@key),
         {:ok, ^me, _until} <- decode(previous),
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
          {:ok, ^me, _until} ->
            {value, _expired} = lease(me, -1)

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

  @doc "The current holder, for diagnostics."
  @spec holder() :: {:ok, String.t(), DateTime.t()} | :none
  def holder do
    with {:ok, raw} <- Arca.ServerMetaStorage.get(@key),
         {:ok, owner, until} <- decode(raw) do
      {:ok, owner, until}
    else
      _ -> :none
    end
  end

  defp replace(previous, value, expires_at, retry) do
    case Arca.ServerMetaStorage.compare_and_put(@key, previous, value) do
      :ok -> {:ok, expires_at}
      {:error, :stale} -> retry.()
      {:error, reason} -> {:error, reason}
    end
  end

  defp lease(me, lease_ms) do
    expires_at = DateTime.add(DateTime.utc_now(), lease_ms, :millisecond)
    {Jason.encode!(%{"owner" => me, "expires_at" => DateTime.to_iso8601(expires_at)}), expires_at}
  end

  defp decode(raw) do
    with {:ok, %{"owner" => owner, "expires_at" => iso}} when is_binary(owner) <-
           Jason.decode(raw),
         {:ok, until, _} <- DateTime.from_iso8601(iso) do
      {:ok, owner, until}
    else
      _ -> :error
    end
  end
end
