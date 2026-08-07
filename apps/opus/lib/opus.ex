# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus do
  @moduledoc """
  WASM execution engine for CYFR.

  Opus provides sandboxed execution of WebAssembly components with:
  - Crash-resilient execution records
  - Telemetry integration
  - Policy-based resource limits
  - Signature verification (Sigstore)
  - Forensic replay capability

  ## Quick Start

      ctx = Sanctum.TestContext.local()
      reference = "catalyst:local.my-tool:0.1.0"
      input = %{"a" => 5, "b" => 10}

      {:ok, result} = Opus.run(ctx, reference, input)

  ## Component Types

  - `:reagent` - Pure sandboxed compute, no I/O (default)
  - `:catalyst` - WASI enabled with HTTP/filesystem access
  - `:formula` - Composition of other components

  ## References

  Components are resolved by name from the local Compendium registry.
  All components must be registered (`cyfr register`) or pulled
  (`cyfr pull`) before execution.
  """

  alias Sanctum.Context
  alias Opus.ExecutionRecord

  @doc """
  Execute a WASM component.

  ## Options

  - `:type` - Component type: `:catalyst`, `:reagent`, or `:formula`
  - `:verify` - Signature verification requirements
  - `:max_memory_bytes` - Memory limit (default: 64MB)
  - `:fuel_limit` - CPU instruction limit (default: 100M)

  ## Examples

      ctx = Sanctum.TestContext.local()
      {:ok, result} = Opus.run(ctx, "reagent:local.my-tool:0.1.0", %{"a" => 1})
      result.status  # => :completed

  """
  @spec run(Context.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  defdelegate run(ctx, reference, input, opts \\ []), to: Opus.Executor

  @doc """
  Root an execution chain under a profile's consent — the external-ingress
  entry of the root/child split. See `Opus.Chain.run_root/5`.
  """
  @spec run_root(Context.t(), String.t() | nil, String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate run_root(ctx, profile_selector, reference, input, opts \\ []), to: Opus.Chain

  @doc """
  Advance a running chain's authority through one invocation and execute
  the target — the in-chain entry. See `Opus.Chain.run_child/5`.
  """
  @spec run_child(Sanctum.Authority.t(), String.t(), String.t() | nil, map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate run_child(authority, reference, need, input, opts), to: Opus.Chain

  @doc """
  List execution records for the current user.

  ## Options

  - `:limit` - Maximum records to return (default: 20)
  - `:status` - Filter by status (:running, :completed, :failed, :all)

  ## Examples

      ctx = Sanctum.TestContext.local()
      {:ok, records} = Opus.list(ctx, limit: 10)

  """
  @spec list(Context.t(), keyword()) :: {:ok, [ExecutionRecord.t()]} | {:error, term()}
  defdelegate list(ctx, opts \\ []), to: ExecutionRecord

  @doc """
  Get an execution record by ID.

  ## Examples

      ctx = Sanctum.TestContext.local()
      {:ok, record} = Opus.get(ctx, "exec_abc123")

  """
  @spec get(Context.t(), String.t()) :: {:ok, ExecutionRecord.t()} | {:error, term()}
  defdelegate get(ctx, execution_id), to: ExecutionRecord

  @doc """
  Cancel a running execution.

  Only running executions can be cancelled.

  ## Examples

      ctx = Sanctum.TestContext.local()
      {:ok, record} = Opus.cancel(ctx, "exec_abc123")

  """
  @spec cancel(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate cancel(ctx, execution_id), to: Opus.Executor

  @doc """
  Terminate a running execution because its consent changed underneath it.

  The delta revision applies to future roots; this one ends carrying
  `restart_required` so its surface can say "approved — re-run to
  continue" (§4.4).
  """
  @spec cancel_for_restart(Context.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate cancel_for_restart(ctx, execution_id, payload), to: Opus.Executor
end
