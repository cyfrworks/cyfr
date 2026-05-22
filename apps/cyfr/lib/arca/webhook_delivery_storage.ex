# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.WebhookDeliveryStorage do
  @moduledoc """
  Storage for inbound webhook delivery deduplication.

  Each row records that a particular `(webhook_id, idempotency_key)` pair
  was seen at `first_seen_at`. The unique index makes concurrent duplicate
  inserts safe — the second one fails with a unique-constraint violation
  and the caller treats it as a duplicate.

  Rows are swept on the `Arca.RetentionScheduler` cadence when retention
  is enabled; otherwise the table grows (single-user volumes are negligible).
  """

  require Arca.Repo.Errors
  require Logger
  import Ecto.Query

  @doc """
  Attempt to record an inbound delivery. Returns:
    * `:fresh` if this is the first time we've seen `(webhook_id, key)`.
    * `{:duplicate, first_seen_at}` if a row already exists.
    * `{:error, reason}` for unexpected DB errors.
  """
  @spec record(String.t(), String.t()) ::
          :fresh | {:duplicate, DateTime.t() | binary()} | {:error, term()}
  def record(webhook_id, idempotency_key)
      when is_binary(webhook_id) and is_binary(idempotency_key) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row = %{
      id: Ecto.UUID.generate(),
      webhook_id: webhook_id,
      idempotency_key: idempotency_key,
      first_seen_at: now
    }

    case Arca.Repo.insert_all("webhook_deliveries", [row], on_conflict: :nothing) do
      {1, _} ->
        :fresh

      {0, _} ->
        # Conflict — fetch the existing row's timestamp.
        case lookup_first_seen(webhook_id, idempotency_key) do
          {:ok, ts} -> {:duplicate, ts}
          # Defensive: row vanished between insert and lookup. Treat as fresh.
          :missing -> :fresh
        end
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[WebhookDeliveryStorage] Database error in record: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  @doc """
  Delete delivery rows older than `older_than` (a `DateTime`). Returns the
  number of rows deleted, or `{:error, reason}` on failure.
  """
  @spec sweep(DateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep(%DateTime{} = older_than) do
    query = from d in "webhook_deliveries", where: d.first_seen_at < ^older_than
    {count, _} = Arca.Repo.delete_all(query)
    {:ok, count}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[WebhookDeliveryStorage] Database error in sweep: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  defp lookup_first_seen(webhook_id, key) do
    query =
      from d in "webhook_deliveries",
        where: d.webhook_id == ^webhook_id and d.idempotency_key == ^key,
        select: d.first_seen_at,
        limit: 1

    case Arca.Repo.one(query) do
      nil -> :missing
      ts -> {:ok, ts}
    end
  end
end