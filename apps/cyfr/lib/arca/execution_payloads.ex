# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionPayloads do
  @moduledoc """
  An execution's retained input and result: the bytes under the athanor's
  `payloads/` root, and the `execution_payloads` row that references
  them by digest, size and retention class.

  Written once per execution and kind; read by a member of the athanor
  through the record tool; pruned by age per retention class
  (`Cyfr.Retention.Payloads`), and released before the execution rows
  that name them go (`release/2`). The row is the reference and the bytes
  are the payload — an `executions` row carries digests and sizes, never
  the bytes.

  The bytes are immutable: an object is named by the digest of its
  content, so two writers for one `(execution, kind)` never overwrite
  each other — the row decides which object is the payload, and a loser's
  object is removed. A read verifies the bytes against the row's digest
  and refuses a mismatch as corruption rather than serving foreign bytes
  under a trusted digest. The root is reserved
  (`Arca.Storage.reserved_roots/0`): only this module's own writes, under
  the overlay's internal-write scope, change it.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Arca.Schemas.ExecutionPayload
  alias Sanctum.Context

  @kinds ["input", "result"]
  @root "payloads"

  @doc "Keep `bytes` as the execution's `kind` payload under `retention_class`."
  @spec put(Context.t(), String.t(), String.t(), binary(), String.t()) ::
          {:ok, ExecutionPayload.t()} | {:error, :exists | :no_execution | term()}
  def put(%Context{} = ctx, execution_id, kind, bytes, retention_class)
      when is_binary(execution_id) and kind in @kinds and is_binary(bytes) and
             is_binary(retention_class) do
    athanor_id = Context.athanor!(ctx)
    digest = Cyfr.Digest.sha256(bytes)
    segments = object_segments(execution_id, kind, digest)
    blob_ref = Enum.join(segments, "/")

    with :ok <- execution_known(athanor_id, execution_id),
         :none <- existing(athanor_id, execution_id, kind),
         :ok <- internal(fn -> Arca.put(ctx, segments, bytes) end) do
      attrs = %{
        id: Cyfr.UUID7.generate_id("pay"),
        athanor_id: athanor_id,
        execution_id: execution_id,
        kind: kind,
        digest: digest,
        bytes: byte_size(bytes),
        blob_ref: blob_ref,
        retention_class: retention_class,
        inserted_at: DateTime.utc_now()
      }

      case insert_row(attrs) do
        {:ok, row} ->
          {:ok, row}

        {:error, reason} ->
          # Another writer's row won the unique key. The object written
          # here is removed unless it is that row's own — same bytes, same
          # name — so the winner's payload is never touched.
          case existing(athanor_id, execution_id, kind) do
            {:exists, %{blob_ref: ^blob_ref}} -> :ok
            _ -> internal(fn -> Arca.delete(ctx, segments) end)
          end

          {:error, reason}
      end
    else
      {:exists, _row} -> {:error, :exists}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The execution's `kind` payload: its row and its bytes, verified against
  the row's digest.
  """
  @spec get(Context.t(), String.t(), String.t()) ::
          {:ok, ExecutionPayload.t(), binary()} | {:error, :not_found | :payload_corrupt | term()}
  def get(%Context{} = ctx, execution_id, kind) when is_binary(execution_id) and kind in @kinds do
    athanor_id = Context.athanor!(ctx)

    with {:ok, row} <- fetch_row(athanor_id, execution_id, kind),
         {:ok, bytes} <- Arca.get(ctx, String.split(row.blob_ref, "/")) do
      if Cyfr.Digest.sha256(bytes) == row.digest do
        {:ok, row, bytes}
      else
        Logger.error(
          "[Arca.ExecutionPayloads] payload #{row.id} of #{execution_id} does not match " <>
            "its digest #{row.digest} — refusing to serve it"
        )

        {:error, :payload_corrupt}
      end
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

  @doc """
  Delete the context's athanor's payloads older than `days`: the bytes,
  then the rows. A row whose bytes could not be deleted stays, so the
  next sweep finds them again; bytes already gone are not a failure.
  """
  @spec delete_older_than_days(Context.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def delete_older_than_days(%Context{} = ctx, days) when is_integer(days) and days > 0 do
    athanor_id = Context.athanor!(ctx)

    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionPayloads.delete_older_than_days", fn ->
      {:ok, delete_rows(ctx, Arca.Repo.all(aged(athanor_id, days)))}
    end)
  end

  @doc """
  Release the payloads of the named executions — bytes, then rows — before
  their `executions` rows go. Answers the ids whose payloads are still
  held because their bytes could not be deleted; those executions are
  kept with them, and the next sweep tries again.
  """
  @spec release(Context.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def release(_ctx, []), do: {:ok, []}

  def release(%Context{} = ctx, execution_ids) when is_list(execution_ids) do
    athanor_id = Context.athanor!(ctx)

    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionPayloads.release", fn ->
      rows =
        Arca.Repo.all(
          from(p in ExecutionPayload,
            where: p.athanor_id == ^athanor_id and p.execution_id in ^execution_ids
          )
        )

      {gone, kept} = delete_bytes(ctx, rows)
      _ = delete_row_ids(athanor_id, Enum.map(gone, & &1.id))
      {:ok, kept |> Enum.map(& &1.execution_id) |> Enum.uniq()}
    end)
  end

  defp delete_rows(ctx, rows) do
    {gone, _kept} = delete_bytes(ctx, rows)
    delete_row_ids(Context.athanor!(ctx), Enum.map(gone, & &1.id))
  end

  defp delete_bytes(ctx, rows) do
    Enum.split_with(rows, fn row ->
      case internal(fn -> Arca.delete(ctx, String.split(row.blob_ref, "/")) end) do
        :ok ->
          true

        {:error, :not_found} ->
          true

        {:error, reason} ->
          Logger.warning(
            "[Arca.ExecutionPayloads] payload #{row.id} of #{row.execution_id} not deleted " <>
              "(#{inspect(reason)}); its row stays for the next sweep"
          )

          false
      end
    end)
  end

  defp delete_row_ids(_athanor_id, []), do: 0

  defp delete_row_ids(athanor_id, ids) do
    {count, _} =
      Arca.Repo.delete_all(
        from(p in ExecutionPayload, where: p.athanor_id == ^athanor_id and p.id in ^ids)
      )

    count
  end

  defp aged(athanor_id, days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    from(p in ExecutionPayload,
      where: p.athanor_id == ^athanor_id and p.inserted_at < ^cutoff
    )
  end

  # `payloads/<execution_id>/<kind>.<digest>` — the object's name is its
  # content's, so a second write of different bytes lands beside, never
  # over, the first.
  defp object_segments(execution_id, kind, "sha256:" <> hex),
    do: [@root, execution_id, "#{kind}.#{hex}"]

  # A payload references an execution the athanor holds; the database
  # constrains the pair too, but names no constraint an adapter could map
  # to a typed refusal, so the store asks first.
  defp execution_known(athanor_id, execution_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionPayloads.put", fn ->
      known? =
        Arca.Repo.exists?(
          from(e in Arca.Execution, where: e.id == ^execution_id and e.athanor_id == ^athanor_id)
        )

      if known?, do: :ok, else: {:error, :no_execution}
    end)
  end

  defp existing(athanor_id, execution_id, kind) do
    case fetch_row(athanor_id, execution_id, kind) do
      {:ok, row} -> {:exists, row}
      {:error, :not_found} -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  # arca:unscoped-ok the row inserted carries the context's athanor_id in `attrs`
  defp insert_row(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionPayloads.put", fn ->
      %ExecutionPayload{}
      |> Ecto.Changeset.change(attrs)
      |> Ecto.Changeset.unique_constraint([:execution_id, :kind])
      |> Arca.Repo.insert()
    end)
  end

  # The root is reserved: its bytes change only under the overlay's
  # internal-write scope, which is what makes a member's write refused.
  defp internal(fun), do: Arca.Overlay.with_internal_writes(fun)

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
