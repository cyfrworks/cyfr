# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ComponentType do
  @moduledoc """
  Component type definitions and WASI capability mappings.

  Component types determine WASI interface grants:

  | Interface                     | Catalyst | Reagent | Formula |
  |-------------------------------|----------|---------|---------|
  | `cyfr:http/fetch`              | ✅        | ❌       | ❌       |
  | `cyfr:http/streaming`          | ✅        | ❌       | ❌       |
  | `cyfr:oauth/token`            | ✅†       | ❌       | ❌       |
  | `cyfr:formula/invoke`          | ❌        | ❌       | ✅       |
  | `wasi:logging/logging`        | ✅        | ✅       | ✅       |
  | `wasi:clocks/wall-clock`      | ✅        | ✅       | ✅       |
  | `wasi:random/random`          | ✅        | ✅       | ✅       |
  | `cyfr:vault/read`           | ✅*       | ❌       | ❌       |

  *`cyfr:vault/read` resolves fields from the Vault entry a consent edge binds
  †`cyfr:oauth/token` resolves a token from the Vault OAuth entry a consent edge binds

  - **Catalyst**: WASI with HTTP via `cyfr:http/fetch` host function (policy-enforced)
  - **Reagent**: Pure compute — no HTTP, no secrets, no side effects
  - **Formula**: Orchestration — dispatches MCP tool calls via `cyfr:formula/invoke@0.1.0` host function.
    All capabilities (component execution, registry search, build, guides) are governed by the
    consent edges its authority carries. Sub-invocations run through the full Executor pipeline
    (edge check, rate limit, credentials, WASM, masking, record write, telemetry). Each gets its
    own `exec_<uuid7>` ID and stores
    `parent_execution_id` for lineage tracking.

  ## Secrets Access

  Only Catalysts can read secrets via the `cyfr:vault/read` WASI import. The
  value comes from a Vault entry that a consent edge binds to the running node —
  the operator maps the catalyst's named need to one of their Connections at
  consent time; there is no per-secret grant API and no athanor-wide secret
  namespace.

      # Catalysts call cyfr:vault/read.get("url") to read a projected field of
      # the bound Vault entry. A node with no bound entry gets "access-denied".
      # Reagents and Formulas never receive the secrets import.

  ## OAuth Token Access

  Only Catalysts can request OAuth tokens, and only when the running node's
  consent edge binds an OAuth Vault entry (a manifest declares the need via
  needs/caps; `oauth`/`setup`/`wasi` manifest blocks are refused at
  registration). The host manages the full lifecycle — client credentials,
  refresh tokens, and token exchange are never exposed to WASM
  (`Sanctum.Vault.OAuthGrant` mints the authorize URL and the callback seals
  the tokens).

      # Catalysts call cyfr:oauth/token.get-access-token("google") at runtime.
      # Host refreshes automatically. Access tokens are masked in output.

  ## Wasmex Behavior

  When `WasiP2Options` is provided (even with `allow_http: false`), Wasmtime
  internally enables clocks, random, and other base WASI interfaces. When `nil`
  is passed, NO WASI is available at all.

  ## Security Model

  The default is `:reagent` (no network access) - callers must explicitly
  request elevated capabilities by specifying `:catalyst`.

  Uses WASI Preview 2 via `Wasmex.Components` for all component execution.

  ## Wasmex Limitations

  Not configurable in the Wasmex version this tree pins (see opus/mix.exs):
  - `wasi:sockets` - Not exposed in WasiP2Options
  - `wasi:filesystem/types` - Not individually configurable

  ## Usage

      # Get WASI options for a component type
      wasi_opts = Opus.ComponentType.wasi_options(:catalyst)

      # Validate a type string
      {:ok, :reagent} = Opus.ComponentType.parse("reagent")

  """

  alias Wasmex.Wasi.WasiP2Options

  # Hand-written because a typespec cannot derive from a runtime list; a
  # test pins it to @valid_types so a new executable type fails loudly here
  # instead of leaving the spec silently stale.
  @type t :: :catalyst | :reagent | :formula

  # Both the string and atom parse paths derive from the canonical type
  # list, so a new executable type added there is accepted here without a
  # second edit.
  @valid_type_strings Sanctum.ComponentRef.executable_types()
  @valid_types Enum.map(@valid_type_strings, &String.to_atom/1)

  @doc """
  Parse a string type into an atom.

  Returns `{:ok, atom}` or `{:error, reason}`.
  """
  # No nil clause: a missing type is not a reagent. Every caller either
  # guards on `is_binary/1` or decides its own default, so inventing one
  # here only hid the question.
  @spec parse(String.t() | atom()) :: {:ok, t()} | {:error, String.t()}
  def parse(type) when type in @valid_types, do: {:ok, type}

  def parse(type) when type in @valid_type_strings,
    do: {:ok, String.to_existing_atom(type)}

  def parse(invalid) do
    {:error,
     "Invalid component type: #{inspect(invalid)}. " <>
       "Must be one of: #{Enum.join(@valid_type_strings, ", ")}"}
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

  # Every executable type gets the same sandbox: `allow_http: false`, because
  # egress goes through the host function where the edge is enforced, never
  # through `wasi:http`. Three identical clauses invited the reading that the
  # types differ here. They do not.
  def wasi_options(type, env) when type in @valid_types do
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
