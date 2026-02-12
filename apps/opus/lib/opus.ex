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

      ctx = Sanctum.Context.local()
      reference = %{"local" => "components/catalysts/local/my-tool/0.1.0/catalyst.wasm"}
      input = %{"a" => 5, "b" => 10}

      {:ok, result} = Opus.run(ctx, reference, input)

  ## Component Types

  - `:reagent` - Pure sandboxed compute, no I/O (default)
  - `:catalyst` - WASI enabled with HTTP/filesystem access
  - `:formula` - Composition of other components

  ## Reference Types

  - `%{"local" => path}` - Local filesystem path
  - `%{"registry" => "name:version"}` - Local registry reference (via Compendium)
  - `%{"arca" => path}` - User's Arca storage
  - `%{"oci" => ref}` - OCI registry reference
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

      ctx = Sanctum.Context.local()
      {:ok, result} = Opus.run(ctx, %{"local" => "path/to/component.wasm"}, %{"a" => 1})
      result.status  # => :completed

  """
  @spec run(Context.t(), map(), map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  defdelegate run(ctx, reference, input, opts \\ []), to: Opus.Executor

  @doc """
  List execution records for the current user.

  ## Options

  - `:limit` - Maximum records to return (default: 20)
  - `:status` - Filter by status (:running, :completed, :failed, :all)

  ## Examples

      ctx = Sanctum.Context.local()
      {:ok, records} = Opus.list(ctx, limit: 10)

  """
  @spec list(Context.t(), keyword()) :: {:ok, [ExecutionRecord.t()]} | {:error, term()}
  defdelegate list(ctx, opts \\ []), to: ExecutionRecord

  @doc """
  Get an execution record by ID.

  ## Examples

      ctx = Sanctum.Context.local()
      {:ok, record} = Opus.get(ctx, "exec_abc123")

  """
  @spec get(Context.t(), String.t()) :: {:ok, ExecutionRecord.t()} | {:error, term()}
  defdelegate get(ctx, execution_id), to: ExecutionRecord

  @doc """
  Cancel a running execution.

  Only running executions can be cancelled.

  ## Examples

      ctx = Sanctum.Context.local()
      {:ok, record} = Opus.cancel(ctx, "exec_abc123")

  """
  @spec cancel(Context.t(), String.t()) :: {:ok, ExecutionRecord.t()} | {:error, term()}
  defdelegate cancel(ctx, execution_id), to: ExecutionRecord
end

