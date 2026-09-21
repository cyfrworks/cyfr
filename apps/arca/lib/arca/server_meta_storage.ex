# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ServerMetaStorage do
  @moduledoc """
  The server's own facts, one row per key (`Arca.Schemas.ServerMeta`).

  No tenant and no cache: every reader wants the row as it is now, and
  the two writers that matter — the keyring fingerprint at boot, the
  control-plane claim — need the write to be conditional. `put_new/2`
  records a fact only if nobody has; `compare_and_put/3` replaces it only
  if it still reads what the caller saw. Both are one statement, so two
  boots racing the same row cannot both believe they wrote it.
  """

  import Ecto.Query

  alias Arca.Schemas.ServerMeta

  @doc "The value under `key`, or `{:error, :not_found}`."
  @spec get(String.t()) :: {:ok, String.t()} | {:error, :not_found | :database_error}
  def get(key) when is_binary(key) do
    Arca.Repo.Errors.with_db_rescue("Arca.ServerMetaStorage.get", fn ->
      case Arca.Repo.get(ServerMeta, key) do
        nil -> {:error, :not_found}
        %ServerMeta{value: value} -> {:ok, value}
      end
    end)
  end

  @doc "Record `value` under `key` only if no row exists yet."
  @spec put_new(String.t(), String.t()) :: {:ok, :recorded} | {:error, :exists | :database_error}
  def put_new(key, value) when is_binary(key) and is_binary(value) do
    Arca.Repo.Errors.with_db_rescue("Arca.ServerMetaStorage.put_new", fn ->
      row = %{key: key, value: value, updated_at: DateTime.utc_now()}

      case Arca.Repo.insert_all(ServerMeta, [row], on_conflict: :nothing) do
        {1, _} -> {:ok, :recorded}
        {0, _} -> {:error, :exists}
      end
    end)
  end

  @doc "Replace the value under `key` only if it still reads `expected`."
  @spec compare_and_put(String.t(), String.t(), String.t()) ::
          :ok | {:error, :stale | :database_error}
  def compare_and_put(key, expected, value)
      when is_binary(key) and is_binary(expected) and is_binary(value) do
    Arca.Repo.Errors.with_db_rescue("Arca.ServerMetaStorage.compare_and_put", fn ->
      now = DateTime.utc_now()

      {count, _} =
        from(m in ServerMeta, where: m.key == ^key and m.value == ^expected)
        |> Arca.Repo.update_all(set: [value: value, updated_at: now])

      if count == 1, do: :ok, else: {:error, :stale}
    end)
  end
end
