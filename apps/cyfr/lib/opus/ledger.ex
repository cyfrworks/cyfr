# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Ledger do
  @moduledoc """
  A run's source ledger as the host keeps it (`Arca.Execution.sources/2`):
  joined ahead of the bytes a read hands its guest.

  `join/3` is called before the host answers a guest with what it read —
  a storage read, a disclosed field, a dispensed token, a tool's answer,
  a pinned send's host — and the answer waits on it: a join that
  cannot be written refuses the read, so no byte reaches a guest whose
  ledger does not already hold its provenance. A join reaches every
  ancestor up the admission chain in the same transaction, so a child's
  provenance is its parent's before any byte the child hands up exists.
  """

  @doc """
  Join `sources` into the ledger of the run `execution_id` (and its
  ancestors) in `actor`'s athanor: `:ok`, or `{:error, :unavailable}`
  when the join could not be written, for the caller to refuse its read.
  """
  @spec join(Prima.Actor.t(), String.t(), [Prima.Source.t()]) :: :ok | {:error, :unavailable}
  def join(%Prima.Actor{} = actor, execution_id, sources) when is_list(sources) do
    case Arca.Execution.join_sources(actor, execution_id, sources) do
      :ok -> :ok
      {:error, _not_written} -> {:error, :unavailable}
    end
  end

  @doc """
  The ledger of the run `execution_id`: `{:ok, sources}`, `{:error,
  :not_found}` for a row retention may already have pruned, or
  `{:error, :unavailable}`.
  """
  @spec sources(Prima.Actor.t(), String.t()) ::
          {:ok, [Prima.Source.t()]} | {:error, :not_found | :unavailable}
  def sources(%Prima.Actor{} = actor, execution_id) when is_binary(execution_id) do
    case Arca.Execution.sources(actor, execution_id) do
      {:ok, sources} -> {:ok, sources}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _unread} -> {:error, :unavailable}
    end
  end
end
