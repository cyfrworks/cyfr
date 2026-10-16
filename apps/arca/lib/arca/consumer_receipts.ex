# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ConsumerReceipts do
  @moduledoc """
  What one consumer did with one outbox record (`Arca.Outbox`,
  `Arca.Schemas.ConsumerReceipt`): one row per consumer, source and
  source revision, written once, in the transaction that did it.

  The outcomes are closed (`outcomes/0`):

    * `applied` — the consumer did its work for the record;
    * `superseded` — a later source's work already stood there, so this
      one's was not done over it;
    * `conflict` — someone other than the source changed what the work
      would have replaced since the source read it, and it was kept;
    * `refused` — the authority the record was recorded under is gone.

  A receipt is written by a consumer that holds its job claim
  (`Arca.JobClaims`) and its member slot: `put!/2` inside a transaction
  that already holds both, `record/4` in a transaction of its own that
  takes them first. Either way a consumer whose claim was taken or ran
  out, or whose member lost its slot, writes nothing.

  Every function that names an athanor takes the `Prima.Actor` first and
  matches it in its head; an actor whose athanor is nil or the empty
  string is refused before any query.
  """

  import Ecto.Query, only: [from: 2]

  alias Arca.Repo.Errors
  alias Arca.Schemas.ConsumerReceipt

  @outcomes ~w(applied superseded conflict refused)

  @typedoc "One receipt: the consumer, the source and revision, and what it did."
  @type receipt :: %{
          required(:consumer) => String.t(),
          required(:source_kind) => String.t(),
          required(:source_id) => String.t(),
          required(:source_revision) => String.t(),
          required(:outcome) => String.t()
        }

  @doc "Every outcome a receipt may record."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc """
  Write `receipt` in the actor's athanor, inside the caller's transaction
  — the one that did the work, under the consumer's claim. Answers `:ok`,
  or `{:error, :receipted}` when the consumer already holds a receipt for
  that source and revision, which writes nothing and is the caller's to
  roll back on.

  Raises for a consumer no record kind declares, an outcome outside
  `outcomes/0`, and on a store that cannot answer, so the transaction
  rolls back.
  """
  @spec put!(Prima.Actor.t(), receipt()) :: :ok | {:error, :receipted}
  # arca:db-raise-ok a step inside the consumer's transaction; a raise rolls it back.
  def put!(
        %Prima.Actor{athanor_id: athanor_id},
        %{outcome: outcome, consumer: consumer} = receipt
      )
      when is_binary(athanor_id) and athanor_id != "" and outcome in @outcomes do
    unless consumer in Arca.Outbox.all_consumers() do
      raise ArgumentError,
            "no outbox kind declares the consumer #{Prima.LoggerContext.shape(consumer)}"
    end

    row = %{
      consumer: consumer,
      source_kind: Map.fetch!(receipt, :source_kind),
      source_id: Map.fetch!(receipt, :source_id),
      source_revision: Map.fetch!(receipt, :source_revision),
      athanor_id: athanor_id,
      outcome: outcome,
      inserted_at: Arca.ServerMetaStorage.now!()
    }

    case Arca.Repo.insert_all(ConsumerReceipt, [row], on_conflict: :nothing) do
      {1, _} -> :ok
      {0, _} -> {:error, :receipted}
    end
  end

  def put!(%Prima.Actor{athanor_id: athanor_id}, %{outcome: outcome})
      when is_binary(athanor_id) and athanor_id != "",
      do:
        raise(
          ArgumentError,
          "a receipt's outcome is one of #{Enum.join(@outcomes, ", ")}, got " <>
            Prima.LoggerContext.shape(outcome)
        )

  def put!(%Prima.Actor{}, %{}), do: Arca.QueryHelpers.no_athanor!("Arca.ConsumerReceipts.put!/2")

  @doc """
  Write `receipt` in a transaction of its own, under `claim` and the
  writer's member `slot`: the claim's row is held at its owner and fence
  (`Arca.JobClaims.hold/1`), then the slot verified live
  (`Arca.ControlPlane.verify_held/1`, `:none` where no claimant runs),
  and the receipt written only while both stand on the database's clock.

  Answers `:ok`, `:taken` or `:lapsed` (the claim is no longer this
  consumer's to act under), `{:error, :not_owner}` (the member no longer
  owns its slot) — each with nothing written — `{:error, :receipted}` or
  `{:error, :database_error}`.
  """
  @spec record(Prima.Actor.t(), Arca.JobClaims.held(), map() | :none, receipt()) ::
          :ok
          | Arca.JobClaims.lost()
          | {:error, :receipted | :not_owner | :no_athanor | :database_error}
  def record(%Prima.Actor{athanor_id: athanor_id} = actor, %{} = claim, slot, %{} = receipt)
      when is_binary(athanor_id) and athanor_id != "" do
    Errors.with_db_rescue("Arca.ConsumerReceipts.record", fn ->
      Arca.Repo.locking_transaction(fn ->
        with {:ok, _held} <- Arca.JobClaims.hold(claim),
             :ok <- Arca.ControlPlane.verify_held(slot),
             :ok <- put!(actor, receipt) do
          :ok
        else
          lost when lost in [:taken, :lapsed] -> Arca.Repo.rollback(lost)
          :lost -> Arca.Repo.rollback(:not_owner)
          {:error, :receipted} -> Arca.Repo.rollback(:receipted)
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, lost} when lost in [:taken, :lapsed] -> lost
        {:error, reason} when reason in [:not_owner, :receipted] -> {:error, reason}
      end
    end)
  end

  def record(%Prima.Actor{}, _claim, _slot, _receipt), do: {:error, :no_athanor}

  @doc """
  The outcome `consumer` recorded for `source` in the actor's athanor, or
  `:none`.
  """
  @spec outcome(Prima.Actor.t(), String.t(), Prima.OutboxRecord.source()) ::
          {:ok, String.t()} | :none | {:error, :no_athanor | :database_error}
  def outcome(%Prima.Actor{athanor_id: athanor_id}, consumer, %{} = source)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(consumer) do
    Errors.with_db_rescue("Arca.ConsumerReceipts.outcome", fn ->
      from(c in ConsumerReceipt,
        where: c.athanor_id == ^athanor_id and c.consumer == ^consumer,
        where: c.source_kind == ^source.source_kind and c.source_id == ^source.source_id,
        where: c.source_revision == ^source.source_revision,
        select: c.outcome
      )
      |> Arca.Repo.one()
      |> case do
        nil -> :none
        outcome -> {:ok, outcome}
      end
    end)
  end

  def outcome(%Prima.Actor{}, _consumer, _source), do: {:error, :no_athanor}
end
