# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionPayloads do
  @moduledoc """
  An execution's retained input and result: the bytes under the athanor's
  `payloads/` root, and the `execution_payloads` row that references
  them by digest, size, retention class and the attempt that produced
  them.

  A payload is kept in two steps so its row can join the transaction
  that admits or ends the execution: `stage/5` writes the bytes and
  answers a `Staged`; `commit!/2` inserts the row inside the caller's
  transaction, for the attempt that owns the execution; `discard/1`
  removes staged bytes no row names. `put/6` does both in a transaction
  of its own. A row exists only once its transaction committed, so a
  reader never meets bytes the execution did not keep.

  One row per `(execution, kind, attempt)`: a successor attempt keeps
  payloads of its own, and `get/4` serves the current attempt's unless
  another is named. Pruned by age per retention class
  (`Cyfr.Retention.Payloads` and its siblings), and released before the
  execution rows that name them go (`release/2`). The row is the
  reference and the bytes are the payload — an `executions` row carries
  digests and sizes, never the bytes.

  The bytes are immutable: an object is named by the digest of its
  content, so two writers for one `(execution, kind, attempt)` never
  overwrite each other — the row decides which object is the payload,
  and a loser's object is removed. A read verifies the bytes against the
  row's digest and refuses a mismatch as corruption rather than serving
  foreign bytes under a trusted digest. The bytes go through the
  configured store (`Arca.ExecutionPayloads.Store`); the root is reserved
  (`Arca.Storage.reserved_roots/0`) and only the store's own writes
  change it.
  """

  import Ecto.Query, only: [from: 2, where: 3]

  require Logger

  alias Arca.ExecutionPayloads.Store
  alias Arca.Schemas.ExecutionPayload
  alias Sanctum.Context

  defmodule Staged do
    @moduledoc """
    Bytes kept for a payload row not yet inserted: what `commit!/2`
    needs to write the row and `discard/1` to remove the object.
    """

    @type t :: %__MODULE__{}

    defstruct [
      :ctx,
      :athanor_id,
      :execution_id,
      :kind,
      :digest,
      :bytes,
      :blob_ref,
      :segments,
      :retention_class
    ]
  end

  @kinds ["input", "result"]
  @root "payloads"

  @doc """
  Write `bytes` as the execution's `kind` payload under `retention_class`
  without a row: the object is named by its digest and answers a
  `Staged` for `commit!/2` or `discard/1`. The execution need not exist
  yet — admission commits the input it was given.
  """
  @spec stage(Context.t(), String.t(), String.t(), binary(), String.t()) ::
          {:ok, Staged.t()} | {:error, term()}
  def stage(%Context{} = ctx, execution_id, kind, bytes, retention_class)
      when is_binary(execution_id) and kind in @kinds and is_binary(bytes) and
             is_binary(retention_class) do
    athanor_id = Context.athanor!(ctx)
    digest = Cyfr.Digest.sha256(bytes)
    segments = object_segments(execution_id, kind, digest)

    with :ok <- Store.impl().put(ctx, segments, bytes) do
      {:ok,
       %Staged{
         ctx: ctx,
         athanor_id: athanor_id,
         execution_id: execution_id,
         kind: kind,
         digest: digest,
         bytes: byte_size(bytes),
         blob_ref: Enum.join(segments, "/"),
         segments: segments,
         retention_class: retention_class
       }}
    end
  end

  @doc """
  Insert the row for staged bytes as `attempt`'s payload, inside the
  caller's transaction; a row that already exists for the execution,
  kind and attempt raises, and the transaction rolls back.
  """
  @spec commit!(Staged.t(), String.t() | nil) :: ExecutionPayload.t()
  # arca:db-raise-ok inside the caller's transaction
  # arca:unscoped-ok the row inserted carries the staged athanor_id
  def commit!(%Staged{} = staged, attempt) when is_binary(attempt) or is_nil(attempt) do
    %ExecutionPayload{}
    |> Ecto.Changeset.change(row_attrs(staged, attempt))
    |> Ecto.Changeset.unique_constraint([:execution_id, :kind, :attempt])
    |> Arca.Repo.insert!()
  end

  @doc """
  Remove staged bytes no row names. An object a row already references
  — the same bytes committed by another writer — is left as it is.
  """
  @spec discard(Staged.t()) :: :ok | {:error, term()}
  def discard(%Staged{} = staged) do
    case referenced?(staged) do
      {:ok, true} -> :ok
      {:ok, false} -> delete_object(staged.ctx, staged.segments)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Keep `bytes` as the execution's `kind` payload under `retention_class`,
  for `opts[:attempt]` — the execution's current attempt by default — in
  one transaction: the bytes, then the row.
  """
  @spec put(Context.t(), String.t(), String.t(), binary(), String.t(), keyword()) ::
          {:ok, ExecutionPayload.t()} | {:error, :exists | :no_execution | term()}
  def put(%Context{} = ctx, execution_id, kind, bytes, retention_class, opts \\ [])
      when is_binary(execution_id) and kind in @kinds and is_binary(bytes) and
             is_binary(retention_class) and is_list(opts) do
    athanor_id = Context.athanor!(ctx)

    with {:ok, current} <- current_attempt(athanor_id, execution_id),
         attempt = Keyword.get(opts, :attempt, current),
         :none <- existing(athanor_id, execution_id, kind, attempt),
         {:ok, staged} <- stage(ctx, execution_id, kind, bytes, retention_class) do
      case insert_row(staged, attempt) do
        {:ok, row} ->
          {:ok, row}

        {:error, reason} ->
          # Another writer's row won the unique key. The object written
          # here is removed unless it is that row's own — same bytes, same
          # name — so the winner's payload is never touched.
          _ = discard(staged)
          {:error, reason}
      end
    else
      {:exists, _row} -> {:error, :exists}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The execution's `kind` payload — its row and its bytes, verified
  against the row's digest — for `opts[:attempt]`, the execution's
  current attempt by default.
  """
  @spec get(Context.t(), String.t(), String.t(), keyword()) ::
          {:ok, ExecutionPayload.t(), binary()} | {:error, :not_found | :payload_corrupt | term()}
  def get(ctx, execution_id, kind, opts \\ [])

  def get(%Context{} = ctx, execution_id, kind, opts)
      when is_binary(execution_id) and kind in @kinds and is_list(opts) do
    athanor_id = Context.athanor!(ctx)

    with {:ok, row} <- fetch_row(athanor_id, execution_id, kind, Keyword.get(opts, :attempt)),
         {:ok, bytes} <- Store.impl().get(ctx, String.split(row.blob_ref, "/")) do
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

  def get(_ctx, _execution_id, _kind, _opts), do: {:error, :not_found}

  @doc "How many of the context's athanor's payloads in `classes` are older than `days`."
  @spec count_older_than_days(Context.t(), pos_integer(), [String.t()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_older_than_days(%Context{} = ctx, days, classes)
      when is_integer(days) and days > 0 and is_list(classes) do
    athanor_id = Context.athanor!(ctx)

    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionPayloads.count_older_than_days", fn ->
      {:ok, Arca.Repo.aggregate(aged(athanor_id, days, classes), :count)}
    end)
  end

  @doc """
  Delete the context's athanor's payloads in `classes` older than `days`:
  the bytes, then the rows. A row whose bytes could not be deleted stays,
  so the next sweep finds them again; bytes already gone are not a
  failure.
  """
  @spec delete_older_than_days(Context.t(), pos_integer(), [String.t()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def delete_older_than_days(%Context{} = ctx, days, classes)
      when is_integer(days) and days > 0 and is_list(classes) do
    athanor_id = Context.athanor!(ctx)

    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionPayloads.delete_older_than_days", fn ->
      {:ok, delete_rows(ctx, Arca.Repo.all(aged(athanor_id, days, classes)))}
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
      case delete_object(ctx, String.split(row.blob_ref, "/")) do
        :ok ->
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

  defp delete_object(ctx, segments) do
    case Store.impl().delete(ctx, segments) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_row_ids(_athanor_id, []), do: 0

  defp delete_row_ids(athanor_id, ids) do
    {count, _} =
      Arca.Repo.delete_all(
        from(p in ExecutionPayload, where: p.athanor_id == ^athanor_id and p.id in ^ids)
      )

    count
  end

  defp aged(athanor_id, days, classes) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    from(p in ExecutionPayload,
      where:
        p.athanor_id == ^athanor_id and p.retention_class in ^classes and
          p.inserted_at < ^cutoff
    )
  end

  # `payloads/<execution_id>/<kind>.<digest>` — the object's name is its
  # content's, so a second write of different bytes lands beside, never
  # over, the first.
  defp object_segments(execution_id, kind, "sha256:" <> hex),
    do: [@root, execution_id, "#{kind}.#{hex}"]

  defp row_attrs(%Staged{} = staged, attempt) do
    %{
      id: Cyfr.UUID7.generate_id("pay"),
      athanor_id: staged.athanor_id,
      execution_id: staged.execution_id,
      kind: staged.kind,
      attempt: attempt,
      digest: staged.digest,
      bytes: staged.bytes,
      blob_ref: staged.blob_ref,
      retention_class: staged.retention_class,
      inserted_at: DateTime.utc_now()
    }
  end

  # A payload references an execution the athanor holds, and by default
  # its current attempt; the database constrains the pair too, but names
  # no constraint an adapter could map to a typed refusal, so the store
  # asks first.
  defp current_attempt(athanor_id, execution_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionPayloads.put", fn ->
      case Arca.Repo.one(
             from(e in Arca.Execution,
               where: e.id == ^execution_id and e.athanor_id == ^athanor_id,
               select: {e.id, e.current_attempt}
             )
           ) do
        nil -> {:error, :no_execution}
        {_id, attempt} -> {:ok, attempt}
      end
    end)
  end

  defp referenced?(%Staged{} = staged) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionPayloads.discard", fn ->
      {:ok,
       Arca.Repo.exists?(
         from(p in ExecutionPayload,
           where: p.athanor_id == ^staged.athanor_id and p.blob_ref == ^staged.blob_ref
         )
       )}
    end)
  end

  defp existing(athanor_id, execution_id, kind, attempt) do
    case fetch_row(athanor_id, execution_id, kind, attempt) do
      {:ok, row} -> {:exists, row}
      {:error, :not_found} -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  # arca:unscoped-ok the row inserted carries the context's athanor_id in `attrs`
  defp insert_row(%Staged{} = staged, attempt) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionPayloads.put", fn ->
      %ExecutionPayload{}
      |> Ecto.Changeset.change(row_attrs(staged, attempt))
      |> Ecto.Changeset.unique_constraint([:execution_id, :kind, :attempt])
      |> Arca.Repo.insert()
      |> case do
        {:ok, row} -> {:ok, row}
        {:error, %Ecto.Changeset{errors: [execution_id: _]}} -> {:error, :exists}
        {:error, changeset} -> {:error, changeset}
      end
    end)
  end

  # The row of the named attempt, or of the execution's current attempt
  # when none is named: a successor's read never answers a predecessor's
  # payload.
  defp fetch_row(athanor_id, execution_id, kind, attempt) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionPayloads.get", fn ->
      base =
        from(p in ExecutionPayload,
          where:
            p.athanor_id == ^athanor_id and p.execution_id == ^execution_id and p.kind == ^kind
        )

      query =
        case attempt do
          nil ->
            from(p in base,
              join: e in Arca.Execution,
              on: e.id == p.execution_id and e.athanor_id == p.athanor_id,
              where:
                p.attempt == e.current_attempt or
                  (is_nil(p.attempt) and is_nil(e.current_attempt))
            )

          attempt ->
            where(base, [p], p.attempt == ^attempt)
        end

      case Arca.Repo.one(query) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
  end
end
