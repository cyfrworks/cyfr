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

  Until its receipt, a consumer's try of a record that puts bytes
  records where (`place/4`, `Arca.Schemas.DeliveryCopy`), written and
  committed before the first byte, so a try that dies leaves its place
  known and a later try discards there first (`placed/3`). A place is
  where the bytes are, under `threads/<thread_id>/<message_id>` of the
  athanor's storage, not a thread row: it stays known whatever became of
  that thread. The receipt clears it in its own transaction (`put!/2`).

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
  alias Arca.Schemas.{ConsumerReceipt, DeliveryCopy}

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
  — the one that did the work, under the consumer's claim — and clear the
  place its tries of that record put bytes under (`place/4`), which a
  receipted record no longer has. Answers `:ok`,
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
      {1, _} -> unplaced!(athanor_id, row)
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
  then the claim's lease judged again on the database's clock read after
  that wait, and the receipt written only while both stand.

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
      Arca.Repo.locking_transaction(fn -> record!(actor, claim, slot, receipt) end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, lost} when lost in [:taken, :lapsed] -> lost
        {:error, reason} when reason in [:not_owner, :receipted] -> {:error, reason}
      end
    end)
  end

  def record(%Prima.Actor{}, _claim, _slot, _receipt), do: {:error, :no_athanor}

  @doc """
  `record/4` as a step of the caller's locking transaction, the one that
  does the consumer's work: the same holds in the same order, and a
  claim lost, a slot lost or a receipt already written rolls the whole
  transaction back with `:taken`, `:lapsed`, `:not_owner` or
  `:receipted`.
  """
  @spec record!(Prima.Actor.t(), Arca.JobClaims.held(), map() | :none, receipt()) :: :ok
  # arca:db-raise-ok a step inside the consumer's transaction; a refusal rolls it back.
  def record!(%Prima.Actor{athanor_id: athanor_id} = actor, %{} = claim, slot, %{} = receipt)
      when is_binary(athanor_id) and athanor_id != "" do
    # The claim is asked again after the lease row's lock is won: a
    # claim that ran out while this waited on the member's lease is
    # judged on the clock read after the wait, and writes nothing.
    with {:ok, _held} <- Arca.JobClaims.hold(claim),
         :ok <- Arca.ControlPlane.verify_held(slot),
         {:ok, _still} <- Arca.JobClaims.hold(claim),
         :ok <- put!(actor, receipt) do
      :ok
    else
      lost when lost in [:taken, :lapsed] -> Arca.Repo.rollback(lost)
      :lost -> Arca.Repo.rollback(:not_owner)
      {:error, :receipted} -> Arca.Repo.rollback(:receipted)
    end
  end

  def record!(%Prima.Actor{}, _claim, _slot, _receipt),
    do: Arca.QueryHelpers.no_athanor!("Arca.ConsumerReceipts.record!/4")

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

  @typedoc "Where a try puts bytes."
  @type place :: %{thread_id: String.t(), message_id: String.t()}

  @doc """
  Record that `consumer`'s try of `source` in the actor's athanor is
  putting bytes under `thread_id`'s message `message_id`, in a
  transaction of its own that commits before the caller writes a byte,
  replacing an earlier try's place in that athanor and no other's.
  """
  @spec place(Prima.Actor.t(), String.t(), Prima.OutboxRecord.source(), place()) ::
          :ok | {:error, :no_athanor | :database_error}
  def place(
        %Prima.Actor{athanor_id: athanor_id},
        consumer,
        %{source_kind: kind, source_id: id, source_revision: revision},
        %{thread_id: thread_id, message_id: message_id}
      )
      when is_binary(athanor_id) and athanor_id != "" and is_binary(consumer) and
             is_binary(thread_id) and is_binary(message_id) do
    Errors.with_db_rescue("Arca.ConsumerReceipts.place", fn ->
      row = %{
        consumer: consumer,
        source_kind: kind,
        source_id: id,
        source_revision: revision,
        athanor_id: athanor_id,
        thread_id: thread_id,
        message_id: message_id,
        inserted_at: DateTime.utc_now()
      }

      {1, _} =
        Arca.Repo.insert_all(DeliveryCopy, [row],
          on_conflict: {:replace, [:thread_id, :message_id, :inserted_at]},
          conflict_target: [:athanor_id, :consumer, :source_kind, :source_id, :source_revision]
        )

      :ok
    end)
  end

  def place(%Prima.Actor{}, _consumer, _source, _place), do: {:error, :no_athanor}

  @doc "Where an earlier try of `consumer` for `source` put bytes, or `:none`."
  @spec placed(Prima.Actor.t(), String.t(), Prima.OutboxRecord.source()) ::
          {:ok, place()} | :none | {:error, :no_athanor | :database_error}
  def placed(
        %Prima.Actor{athanor_id: athanor_id},
        consumer,
        %{source_kind: kind, source_id: id, source_revision: revision}
      )
      when is_binary(athanor_id) and athanor_id != "" and is_binary(consumer) do
    Errors.with_db_rescue("Arca.ConsumerReceipts.placed", fn ->
      from(c in DeliveryCopy,
        where: c.athanor_id == ^athanor_id and c.consumer == ^consumer,
        where: c.source_kind == ^kind and c.source_id == ^id and c.source_revision == ^revision,
        select: %{thread_id: c.thread_id, message_id: c.message_id}
      )
      |> Arca.Repo.one()
      |> case do
        nil -> :none
        place -> {:ok, place}
      end
    end)
  end

  def placed(%Prima.Actor{}, _consumer, _source), do: {:error, :no_athanor}

  # The place of the record a receipt names, cleared in the receipt's
  # transaction.
  # arca:db-raise-ok inside the caller's transaction
  defp unplaced!(athanor_id, %{consumer: consumer} = row) do
    from(c in DeliveryCopy,
      where: c.athanor_id == ^athanor_id and c.consumer == ^consumer,
      where: c.source_kind == ^row.source_kind and c.source_id == ^row.source_id,
      where: c.source_revision == ^row.source_revision
    )
    |> Arca.Repo.delete_all()

    :ok
  end
end
