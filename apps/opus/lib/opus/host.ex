# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Host do
  @moduledoc """
  What the runtime asks of the host: the seams where opus reaches into
  cyfr while a component runs.

  Every one of these is a delegate today — opus and cyfr are one release —
  but they are the whole of what a runtime needs from the platform: a
  root authority resolved from a consent, an in-chain tool call, a vault
  edge unsealed, a policy decision recorded, an execution row opened and
  closed. A worker on another node would implement exactly this surface
  against the wire (`Sanctum.Authority.to_wire/1`); the runtime code above
  it does not change.
  """

  alias Sanctum.Context

  @doc "Resolve the root Authority a profile grants — the consent loader."
  @spec load_root(Context.t(), map(), keyword()) :: {:ok, term(), term()} | {:error, term()}
  defdelegate load_root(ctx, profile, opts), to: Sanctum.Consent.Loader

  @doc "An in-chain tool call under a running component's authority."
  @spec tool_call(String.t(), Context.t(), map(), Sanctum.Authority.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defdelegate tool_call(name, ctx, args, authority, opts \\ []),
    to: Emissary.MCP.ToolRegistry,
    as: :call_in_chain

  @doc "The material a consented vault edge projects for this execution."
  @spec unseal(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate unseal(ctx, vault_resource), to: Sanctum.VaultReader, as: :fetch

  @doc "Record a policy decision (allowed or denied) for the audit trail."
  @spec enforce(map()) :: :ok
  defdelegate enforce(attrs), to: Sanctum.Policy.Enforcement, as: :record

  @doc "Open an execution's row before it runs."
  @spec record_start(Opus.ExecutionRecord.t()) :: :ok | {:error, term()}
  defdelegate record_start(record), to: Opus.ExecutionRecord, as: :write_started

  @doc "Close an execution's row as completed."
  @spec record_complete(Opus.ExecutionRecord.t()) :: :ok | {:error, term()}
  defdelegate record_complete(record), to: Opus.ExecutionRecord, as: :write_completed

  @doc "Close an execution's row as failed or cancelled."
  @spec record_failed(Opus.ExecutionRecord.t()) :: :ok | {:error, term()}
  defdelegate record_failed(record), to: Opus.ExecutionRecord, as: :write_failed

  @doc "Deliver an execution event to its subscribers and the replay buffer."
  @spec broadcast(String.t(), map(), non_neg_integer(), term(), keyword()) :: :ok
  defdelegate broadcast(execution_id, data, sequence, ctx, opts \\ []),
    to: Opus.ExecutionEventBuffer,
    as: :push
end
