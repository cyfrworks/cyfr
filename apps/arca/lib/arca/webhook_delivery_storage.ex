# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.WebhookDeliveryStorage do
  @moduledoc """
  Storage for inbound webhook delivery deduplication.

  Each row records that a particular `(webhook_id, idempotency_key)` pair
  was seen at `first_seen_at`. The unique index makes concurrent duplicate
  inserts safe — the second one fails with a unique-constraint violation
  and the caller treats it as a duplicate.

  The claim status tracks work that outlives the HTTP response. Tasks
  call `settle/3`: success retains the claim, while failure permits retry.

  Rows are swept UNCONDITIONALLY on the `Cyfr.RetentionScheduler` cadence
  (its sweep roster runs whether or not per-kind retention policy is set),
  past `:webhook_idempotency_ttl_seconds` — an authenticated sender cannot
  grow this table without bound.
  """

  import Ecto.Query

  alias Arca.Schemas.WebhookDelivery

  @doc """
  Attempt to claim an inbound delivery. Returns:
    * `:fresh` if this is the first time we've seen `(webhook_id, key)`,
      or if the previous attempt is recorded `failed` and may be retried.
    * `{:duplicate, first_seen_at}` if a live claim already exists —
      `claimed` (in flight) or `succeeded` (already ran).
    * `{:error, reason}` for unexpected DB errors.
  """
  @spec record(String.t(), String.t()) ::
          :fresh | {:duplicate, DateTime.t() | binary()} | {:error, term()}
  def record(webhook_id, idempotency_key)
      when is_binary(webhook_id) and is_binary(idempotency_key) do
    Arca.Repo.Errors.with_db_rescue("WebhookDeliveryStorage.record", fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      row = %{
        id: Cyfr.UUID7.generate_id("whd"),
        webhook_id: webhook_id,
        idempotency_key: idempotency_key,
        first_seen_at: now
      }

      case Arca.Repo.insert_all(WebhookDelivery, [row], on_conflict: :nothing) do
        {1, _} ->
          :fresh

        {0, _} ->
          # Conflict — the outcome depends on how the previous attempt ended.
          case lookup_existing(webhook_id, idempotency_key) do
            # Re-deliverable: the sender is retrying something that did not
            # run. Re-stake rather than answering "duplicate" to a delivery
            # that never happened.
            {:ok, %{status: "failed"}} ->
              reclaim(webhook_id, idempotency_key, now)

            {:ok, %{first_seen_at: ts}} ->
              {:duplicate, ts}

            # Defensive: row vanished between insert and lookup. Treat as fresh.
            :missing ->
              :fresh
          end
      end
    end)
    |> Arca.Data.project()
  end

  @doc """
  Record how a claimed delivery ended.

  `:succeeded` keeps the claim — the sender's retry is a genuine
  duplicate. `:failed` makes the delivery re-deliverable: the row stays,
  so the sweep still bounds the table, but `record/2` will re-claim it,
  because a delivery that did not run is one the sender is entitled to
  retry.

  The controller returns 200 when it spawns the task. The task must
  report its own failure to release the claim for retry.
  """
  @spec settle(String.t(), String.t(), :succeeded | :failed) :: :ok | {:error, term()}
  def settle(webhook_id, idempotency_key, outcome)
      when is_binary(webhook_id) and is_binary(idempotency_key) and
             outcome in [:succeeded, :failed] do
    Arca.Repo.Errors.with_db_rescue("WebhookDeliveryStorage.settle", fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      query =
        from(d in WebhookDelivery,
          where:
            d.webhook_id == ^webhook_id and d.idempotency_key == ^idempotency_key and
              d.status == "claimed"
        )

      Arca.Repo.update_all(query, set: [status: Atom.to_string(outcome), settled_at: now])

      :ok
    end)
    |> Arca.Data.project()
  end

  @doc """
  Drop the claim `record/2` staked, so the sender's retry is not treated as a
  duplicate of a delivery that never happened.

  The row is written *before* the target runs — that is what makes two
  concurrent deliveries of the same key resolve to one execution. It therefore
  has to be given back when the delivery turns out to have failed, or the
  first failed attempt would permanently answer every retry with
  `{"status": "duplicate"}` and the target would never run at all.
  """
  @spec release(String.t(), String.t()) :: :ok | {:error, term()}
  def release(webhook_id, idempotency_key)
      when is_binary(webhook_id) and is_binary(idempotency_key) do
    Arca.Repo.Errors.with_db_rescue("WebhookDeliveryStorage.release", fn ->
      query =
        from(d in WebhookDelivery,
          where: d.webhook_id == ^webhook_id and d.idempotency_key == ^idempotency_key
        )

      Arca.Repo.delete_all(query)
      :ok
    end)
    |> Arca.Data.project()
  end

  @doc """
  Delete delivery rows older than `older_than` (a `DateTime`). Returns the
  number of rows deleted, or `{:error, reason}` on failure.
  """
  @spec sweep(DateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep(%DateTime{} = older_than) do
    Arca.Repo.Errors.with_db_rescue("WebhookDeliveryStorage.sweep", fn ->
      query = from(d in WebhookDelivery, where: d.first_seen_at < ^older_than)
      {count, _} = Arca.Repo.delete_all(query)
      {:ok, count}
    end)
    |> Arca.Data.project()
  end

  defp lookup_existing(webhook_id, key) do
    query =
      from(d in WebhookDelivery,
        where: d.webhook_id == ^webhook_id and d.idempotency_key == ^key,
        select: %{first_seen_at: d.first_seen_at, status: d.status},
        limit: 1
      )

    case Arca.Repo.one(query) do
      nil -> :missing
      row -> {:ok, row}
    end
  end

  # Only from `failed` — a concurrent claimer that already won leaves the
  # row `claimed`, and this must not steal it.
  defp reclaim(webhook_id, idempotency_key, now) do
    query =
      from(d in WebhookDelivery,
        where:
          d.webhook_id == ^webhook_id and d.idempotency_key == ^idempotency_key and
            d.status == "failed"
      )

    case Arca.Repo.update_all(query,
           set: [status: "claimed", first_seen_at: now, settled_at: nil]
         ) do
      {1, _} ->
        :fresh

      # Someone else re-claimed it between the lookup and here.
      {0, _} ->
        case lookup_existing(webhook_id, idempotency_key) do
          {:ok, %{first_seen_at: ts}} -> {:duplicate, ts}
          :missing -> :fresh
        end
    end
  end
end
