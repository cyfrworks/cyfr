defmodule Opus.ComponentType do
  @moduledoc """
  Component type definitions and WASI capability mappings.

  Per PRD §5.1, component types determine WASI interface grants:

  | Interface                     | Catalyst | Reagent | Formula |
  |-------------------------------|----------|---------|---------|
  | `cyfr:http/fetch`              | ✅        | ❌       | ❌       |
  | `cyfr:http/streaming`          | ✅        | ❌       | ❌       |
  | `cyfr:formula/invoke`          | ❌        | ❌       | ✅       |
  | `cyfr:mcp/tools`               | ❌        | ❌       | ✅**     |
  | `wasi:logging/logging`        | ✅        | ✅       | ✅       |
  | `wasi:clocks/wall-clock`      | ✅        | ✅       | ✅       |
  | `wasi:random/random`          | ✅        | ✅       | ✅       |
  | `cyfr:secrets/read`           | ✅*       | ❌       | ❌       |

  *`cyfr:secrets/read` requires explicit grants via `Sanctum.Secrets.grant/3`
  **`cyfr:mcp/tools` requires explicit `allowed_tools` in policy (deny-by-default)

  - **Catalyst**: WASI with HTTP via `cyfr:http/fetch` host function (policy-enforced)
  - **Reagent**: Pure compute — no HTTP, no secrets, no side effects
  - **Formula**: Orchestration — invokes sub-components via `cyfr:formula/invoke@0.1.0` host function.
    Sub-invocations run through the full Executor pipeline (policy, rate limit, secrets, WASM, masking,
    record write, telemetry). Each gets its own `exec_<uuid7>` ID and stores `parent_execution_id`
    for lineage tracking.

  ## Secrets Access

  Only Catalysts can read secrets via the `cyfr:secrets/read` WASI import.
  Access requires an explicit grant:

      # Grant a catalyst access to a secret
      Sanctum.Secrets.grant(ctx, "API_KEY", "local.my-catalyst:1.0.0")

      # Catalysts call cyfr:secrets/read.get("API_KEY") to retrieve the value
      # Access without a grant returns "access-denied" error
      # Reagents and Formulas never receive secrets imports

  ## Wasmex 0.14.0 Behavior

  When `WasiP2Options` is provided (even with `allow_http: false`), Wasmtime
  internally enables clocks, random, and other base WASI interfaces. When `nil`
  is passed, NO WASI is available at all.

  ## Security Model

  The default is `:reagent` (no network access) - callers must explicitly
  request elevated capabilities by specifying `:catalyst`.

  Uses WASI Preview 2 via `Wasmex.Components` for all component execution.

  ## Wasmex Limitations

  The following PRD capabilities are not configurable in Wasmex 0.14.0:
  - `wasi:sockets` - Not exposed in WasiP2Options
  - `wasi:filesystem/types` - Not individually configurable

  ## Usage

      # Get WASI options for a component type
      wasi_opts = Opus.ComponentType.wasi_options(:catalyst)

      # Validate a type string
      {:ok, :reagent} = Opus.ComponentType.parse("reagent")

  """

  alias Wasmex.Wasi.WasiP2Options

  @type t :: :catalyst | :reagent | :formula

  @valid_types [:catalyst, :reagent, :formula]

  @doc """
  Parse a string type into an atom.

  Returns `{:ok, atom}` or `{:error, reason}`.
  """
  @spec parse(String.t() | atom() | nil) :: {:ok, t()} | {:error, String.t()}
  def parse(nil), do: {:ok, :reagent}
  def parse(type) when type in @valid_types, do: {:ok, type}
  def parse("catalyst"), do: {:ok, :catalyst}
  def parse("reagent"), do: {:ok, :reagent}
  def parse("formula"), do: {:ok, :formula}

  def parse(invalid) do
    {:error, "Invalid component type: #{inspect(invalid)}. Must be one of: catalyst, reagent, formula"}
  end

  @doc """
  Returns WASI P2 options for the given component type.

  - `:catalyst` - WASI with logging, clocks, random; HTTP via `cyfr:http/fetch` host function
  - `:reagent` - WASI with logging, clocks, random; NO HTTP
  - `:formula` - Same as Reagent (composition at Opus level)

  All types get stdout/stderr for logging. Catalyst HTTP goes through `cyfr:http/fetch`
  host function (not `wasi:http/outgoing-handler`) for full policy enforcement.

  ## Examples

      iex> opts = Opus.ComponentType.wasi_options(:catalyst)
      iex> opts.allow_http
      false

      iex> opts = Opus.ComponentType.wasi_options(:reagent)
      iex> opts.allow_http
      false

  """
  @spec wasi_options(t(), map()) :: WasiP2Options.t() | nil
  def wasi_options(type, env \\ %{})

  def wasi_options(:catalyst, env) do
    %WasiP2Options{
      allow_http: false,
      inherit_stdin: false,
      inherit_stdout: true,
      inherit_stderr: true,
      args: [],
      env: env
    }
  end

  def wasi_options(:reagent, env) do
    %WasiP2Options{
      allow_http: false,
      inherit_stdin: false,
      inherit_stdout: true,
      inherit_stderr: true,
      args: [],
      env: env
    }
  end

  def wasi_options(:formula, env) do
    %WasiP2Options{
      allow_http: false,
      inherit_stdin: false,
      inherit_stdout: true,
      inherit_stderr: true,
      args: [],
      env: env
    }
  end

  def wasi_options(_, _env), do: nil

  @doc """
  Returns the list of valid component types.
  """
  @spec valid_types() :: [t()]
  def valid_types, do: @valid_types

  @doc """
  Check if a type is valid.
  """
  @spec valid?(atom()) :: boolean()
  def valid?(type), do: type in @valid_types
end


