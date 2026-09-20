# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Retention.ExecutionRows do
  @moduledoc """
  How a retention kind deletes execution rows: the payloads they reference
  are released first — bytes, then rows — and an execution whose payload
  bytes could not be deleted is kept with them for the next sweep. The
  two kinds that bound executions (by count and by age) differ only in
  which ids they select.
  """

  alias Sanctum.Context

  # Ids travel as query parameters; a batch keeps a large sweep under any
  # adapter's parameter limit.
  @batch 500

  @doc "Delete the executions `select` names, less those whose payloads are still held."
  @spec delete(Context.t(), (-> {:ok, [String.t()]} | {:error, term()}), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def delete(%Context{} = ctx, select, opts) when is_function(select, 0) and is_list(opts) do
    with {:ok, ids} <- select.() do
      ids
      |> Enum.chunk_every(@batch)
      |> Enum.reduce_while({:ok, 0}, fn batch, {:ok, deleted} ->
        with {:ok, held} <- Arca.ExecutionPayloads.release(Sanctum.Context.actor(ctx), batch),
             {:ok, count} <- Arca.Execution.delete_ids(batch -- held, opts) do
          {:cont, {:ok, deleted + count}}
        else
          error -> {:halt, error}
        end
      end)
    end
  end
end
