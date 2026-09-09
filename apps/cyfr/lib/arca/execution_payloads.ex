# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionPayloads do
  @moduledoc """
  An execution's retained input and result: the bytes under the athanor's
  `payloads/` root, and the `execution_payloads` row that references
  them by digest, size and retention class.

  Written once per execution and kind; read by a member of the athanor
  through the record tool; pruned by age per retention class
  (`Cyfr.Retention.Payloads`). The row is the reference and the bytes
  are the payload — an `executions` row carries digests and sizes, never
  the bytes.
  """

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.ExecutionPayload
  alias Sanctum.Context

  @kinds ["input", "result"]
  @root "payloads"

  @doc "Keep `bytes` as the execution's `kind` payload under `retention_class`."
  @spec put(Context.t(), String.t(), String.t(), binary(), String.t()) ::
          {:ok, ExecutionPayload.t()} | {:error, term()}
  def put(%Context{} = ctx, execution_id, kind, bytes, retention_class)
      when is_binary(execution_id) and kind in @kinds and is_binary(bytes) and
             is_binary(retention_class) do
    athanor_id = Context.athanor!(ctx)
    segments = [@root, execution_id, kind]

    with :ok <- Arca.put(ctx, segments, bytes) do
      Arca.Repo.Errors.with_db_rescue("Arca.ExecutionPayloads.put", fn ->
        %ExecutionPayload{}
        |> Ecto.Changeset.change(%{
          id: Cyfr.UUID7.generate_id("pay"),
          athanor_id: athanor_id,
          execution_id: execution_id,
          kind: kind,
          digest: Cyfr.Digest.sha256(bytes),
          bytes: byte_size(bytes),
          blob_ref: Enum.join(segments, "/"),
          retention_class: retention_class,
          inserted_at: DateTime.utc_now()
        })
        |> Ecto.Changeset.unique_constraint([:execution_id, :kind])
        |> Arca.Repo.insert()
      end)
    end
  end

  @doc "The execution's `kind` payload: its row and its bytes."
  @spec get(Context.t(), String.t(), String.t()) ::
          {:ok, ExecutionPayload.t(), binary()} | {:error, :not_found | term()}
  def get(%Context{} = ctx, execution_id, kind) when is_binary(execution_id) and kind in @kinds do
    athanor_id = Context.athanor!(ctx)

    with {:ok, row} <- fetch_row(athanor_id, execution_id, kind),
         {:ok, bytes} <- Arca.get(ctx, String.split(row.blob_ref, "/")) do
      {:ok, row, bytes}
    end
  end

  def get(_ctx, _execution_id, _kind), do: {:error, :not_found}

  @doc "How many of the context's athanor's payloads are older than `days`."
  @spec count_older_than_days(Context.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_older_than_days(%Context{} = ctx, days) when is_integer(days) and days > 0 do
    athanor_id = Context.athanor!(ctx)

    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionPayloads.count_older_than_days", fn ->
      {:ok, Arca.Repo.aggregate(aged(athanor_id, days), :count)}
    end)
  end

  @doc "Delete the context's athanor's payloads older than `days`: the bytes, then the rows."
  @spec delete_older_than_days(Context.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def delete_older_than_days(%Context{} = ctx, days) when is_integer(days) and days > 0 do
    athanor_id = Context.athanor!(ctx)

    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionPayloads.delete_older_than_days", fn ->
      rows = Arca.Repo.all(aged(athanor_id, days))

      Enum.each(rows, fn row ->
        # A blob already gone is not a failure to delete it.
        _ = Arca.delete(ctx, String.split(row.blob_ref, "/"))
      end)

      ids = Enum.map(rows, & &1.id)

      {count, _} =
        Arca.Repo.delete_all(
          from(p in ExecutionPayload, where: p.athanor_id == ^athanor_id and p.id in ^ids)
        )

      {:ok, count}
    end)
  end

  defp aged(athanor_id, days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    from(p in ExecutionPayload,
      where: p.athanor_id == ^athanor_id and p.inserted_at < ^cutoff
    )
  end

  defp fetch_row(athanor_id, execution_id, kind) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionPayloads.get", fn ->
      case Arca.Repo.get_by(ExecutionPayload,
             athanor_id: athanor_id,
             execution_id: execution_id,
             kind: kind
           ) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
  end
end
