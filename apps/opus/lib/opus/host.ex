# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Host do
  @moduledoc """
  The **consent and record plane**: the seams a running component crosses
  into the platform — a root authority resolved from a consent, an in-chain
  tool call, a vault edge unsealed, a policy decision recorded, an execution
  row opened and closed, an event delivered.

  Delegates selected host operations within the combined Opus/CYFR release.
  This module is not the complete dependency interface; Opus also calls
  CYFR storage, policy, scheduling and utility modules directly.

  The honest statement is narrower and still useful: **this is the plane a
  component's execution crosses, and it is the one that would go over the
  wire** (`Sanctum.Authority.to_wire/1`). The rest — storage, cache, the
  row plane, network policy, the shared primitives under `Cyfr.` — is
  infrastructure a worker would need a real client for, not a behaviour it
  would implement. `Opus.HostSurfaceTest` keeps that list from growing
  quietly.
  """

  alias Sanctum.Context

  @doc "Resolve the root Authority a profile grants — the consent loader."
  @spec load_root(Context.t(), map(), keyword()) :: {:ok, term(), term()} | {:error, term()}
  defdelegate load_root(ctx, profile, opts), to: Sanctum.Consent.Loader

  @doc "An in-chain tool call under a running component's authority."
  @spec tool_call(String.t(), Context.t(), map(), Sanctum.Authority.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defdelegate tool_call(name, ctx, args, authority, opts \\ []),
    to: Cyfr.Ops.Catalog,
    as: :call_in_chain

  @doc "Whether the host, not the catalog, runs `tool.action` for a chain."
  @spec host_intercepted?(String.t(), String.t() | nil) :: boolean()
  defdelegate host_intercepted?(name, action), to: Cyfr.Ops.Catalog

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
