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

      {:ok, result} = Opus.run_root(ctx, nil, reference, input)

  ## Component Types

  - `:reagent` - Pure sandboxed compute, no I/O (default)
  - `:catalyst` - WASI enabled with HTTP/filesystem access
  - `:formula` - Composition of other components

  ## References

  Components are resolved by name from the local Compendium registry.
  All components must be registered (`cyfr register`) or pulled
  (`cyfr pull`) before execution.
  """

  # The engine is cyfr's execution port: cyfr calls it through
  # `Cyfr.Execution`, never by name, so a headless build or a stubbed test
  # needs no engine on the path.
  @behaviour Cyfr.Execution

  alias Sanctum.Context
  alias Opus.ExecutionRecord

  @doc """
  Root an execution chain under a profile's consent — the external-ingress
  entry of the root/child split. See `Opus.Chain.run_root/5`.
  """
  @spec run_root(Context.t(), String.t() | nil, String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  @impl Cyfr.Execution
  defdelegate run_root(ctx, profile_selector, reference, input, opts \\ []), to: Opus.Chain

  @doc """
  Root an execution chain from a tincture (edge) ingress — the third entry
  shape alongside `run_root`/`run_child`. The facade carries it precisely so
  every way an execution can start is enumerable here. See
  `Opus.Chain.run_root_edge/5`.
  """
  @spec run_root_edge(Context.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  @impl Cyfr.Execution
  defdelegate run_root_edge(ctx, source_ref, reference, input, opts \\ []), to: Opus.Chain

  @doc """
  Derive (without executing) the authority a `run_root` for this selector
  and reference would run under. See `Opus.Chain.authority_for/4`.
  """
  @spec authority_for(Context.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, Sanctum.Authority.t()} | {:error, term()}
  @impl Cyfr.Execution
  defdelegate authority_for(ctx, profile_selector, reference, opts \\ []), to: Opus.Chain

  @doc """
  Subscribe the calling process to an execution's event stream. Pass the
  execution's own record/context so the topic resolves to the OWNING athanor —
  and pass the same value to `unsubscribe_events/2`, or the unsubscribe
  targets a different topic and silently no-ops.
  """
  @impl Cyfr.Execution
  defdelegate subscribe_events(execution_id, ctx),
    to: Opus.ExecutionEventBuffer,
    as: :subscribe

  @doc "Unsubscribe from an execution's event stream (same ctx as subscribe)."
  @impl Cyfr.Execution
  defdelegate unsubscribe_events(execution_id, ctx),
    to: Opus.ExecutionEventBuffer,
    as: :unsubscribe

  @doc "Buffered events after `last_sequence` for an execution of `athanor_id`, for replay on (re)connect."
  @impl Cyfr.Execution
  defdelegate events_since(execution_id, last_sequence, athanor_id),
    to: Opus.ExecutionEventBuffer,
    as: :since

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
  @impl Cyfr.Execution
  defdelegate list(ctx, opts \\ []), to: ExecutionRecord

  @doc """
  Get an execution record by ID.

  ## Examples

      ctx = Sanctum.TestContext.local()
      {:ok, record} = Opus.get(ctx, "exec_abc123")

  """
  @spec get(Context.t(), String.t()) :: {:ok, ExecutionRecord.t()} | {:error, term()}
  @impl Cyfr.Execution
  defdelegate get(ctx, execution_id), to: ExecutionRecord

  @doc """
  Cancel a running execution.

  Only running executions can be cancelled.

  ## Examples

      ctx = Sanctum.TestContext.local()
      {:ok, record} = Opus.cancel(ctx, "exec_abc123")

  """
  @spec cancel(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @impl Cyfr.Execution
  defdelegate cancel(ctx, execution_id), to: Opus.Executor

  @doc """
  Terminate a running execution because its consent changed underneath it.

  The delta revision applies to future roots; this one ends carrying
  `restart_required` so its surface can say "approved — re-run to
  continue" (§4.4).
  """
  @spec cancel_for_restart(Context.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  @impl Cyfr.Execution
  defdelegate cancel_for_restart(ctx, execution_id, payload), to: Opus.Executor

  @doc "Whether the engine can admit work: its semaphore is up."
  @impl Cyfr.Execution
  @spec ready?() :: boolean()
  def ready?, do: is_pid(Process.whereis(Opus.ExecutionSemaphore))
end
