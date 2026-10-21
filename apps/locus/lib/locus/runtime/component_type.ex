# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.ComponentType do
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
    consent edges its authority carries. Sub-invocations are admitted, run and closed like any
    execution (edge check, rate limit, credentials, WASM, masking, record write, telemetry). Each
    gets its own `exec_<uuid7>` ID and stores `parent_execution_id` for lineage tracking.

  ## Secrets Access

  Only Catalysts can read secrets via the `cyfr:vault/read` WASI import. The
  value comes from a Vault entry that a consent edge binds to the running node —
  the operator maps the catalyst's named need to one of their vault entries at
  consent time; there is no per-secret grant API and no athanor-wide secret
  namespace.

      # Catalysts call cyfr:vault/read.get("url") to read a projected field of
      # the bound Vault entry. A node with no bound entry gets "access-denied".
      # Reagents and Formulas never receive the secrets import.

  ## OAuth Token Access

  Only Catalysts can request OAuth tokens, and only when the running node's
  consent edge binds an OAuth Vault entry (a manifest declares the need via
  needs/caps; `oauth`/`setup`/`wasi` manifest blocks are refused at
  registration). CYFR manages the full lifecycle — client credentials,
  refresh tokens, and token exchange are never exposed to WASM: a guest
  asks its attempt for a token (`Locus.Runtime.OAuthHandler`) and CYFR dispenses
  one from the consented vault edge.

      # Catalysts call cyfr:oauth/token.get-access-token("google") at runtime.
      # Host refreshes automatically. Access tokens are masked in output.

  ## Wasmex Behavior

  `WasiP2Options` (even with `allow_http: false`) has Wasmtime enable clocks,
  random, and the other base WASI interfaces.

  ## Security Model

  The default is `:reagent` (no network access) - callers must explicitly
  request elevated capabilities by specifying `:catalyst`.

  Uses WASI Preview 2 via `Wasmex.Components` for all component execution.

  ## Wasmex Limitations

  Not configurable in the Wasmex version this tree pins (see apps/locus/mix.exs):
  - `wasi:sockets` - Not exposed in WasiP2Options
  - `wasi:filesystem/types` - Not individually configurable

  ## Usage

      # Get WASI options for a component type
      wasi_opts = Locus.Runtime.ComponentType.wasi_options(:catalyst)

      # Validate a type string
      {:ok, :reagent} = Locus.Runtime.ComponentType.parse("reagent")

  """

  alias Wasmex.Wasi.WasiP2Options

  # Hand-written because a typespec cannot derive from a runtime list; a
  # test pins the canonical type list to it, so a new executable type fails
  # loudly there instead of leaving the spec silently stale.
  @type t :: :catalyst | :reagent | :formula

  # Parsing derives from the canonical type list, so a new executable type
  # added there is accepted here without a second edit.
  @valid_type_strings Prima.ComponentRef.executable_types()
  @valid_types Enum.map(@valid_type_strings, &String.to_atom/1)

  @doc """
  Parse a string type into an atom.

  Returns `{:ok, atom}` or `{:error, reason}`.
  """
  # A missing type is an error, not a reagent: the one caller parses the
  # type its assignment carries, and there is no default to invent here.
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
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
  - `:formula` - Same as Reagent (composition at the runtime level)

  No type gets the host's stdio. Catalyst HTTP goes through `cyfr:http/fetch`
  host function (not `wasi:http/outgoing-handler`) for full policy enforcement.

  ## Examples

      iex> opts = Locus.Runtime.ComponentType.wasi_options(:catalyst)
      iex> opts.allow_http
      false

      iex> opts = Locus.Runtime.ComponentType.wasi_options(:reagent)
      iex> opts.inherit_stdout
      false

  """
  # Every executable type gets the same sandbox: `allow_http: false`, because
  # egress goes through the host function where the edge is enforced, never
  # through `wasi:http`. The types do not differ here.
  #
  # The guest gets no host environment: nothing puts host environment
  # variables inside the sandbox.
  #
  # Nor does it get the host's stdout/stderr. Inheriting them would hand
  # every guest — reagents included, whose whole definition is compute with
  # no I/O — an unbounded write straight into the operator's console and log
  # aggregation: no `Prima.SecretMasker`, no emit rate limit, no emit size
  # cap, and a trivial way to fill a disk. `wasmex`'s WASI options are
  # inherit-or-nothing (there is no capture pipe to point somewhere safe),
  # so this is `false`. A component that wants to say something says it
  # through `emit`, which is bounded, masked, sequenced and attributable.
  @spec wasi_options(t()) :: WasiP2Options.t()
  def wasi_options(type) when type in @valid_types do
    %WasiP2Options{
      allow_http: false,
      inherit_stdin: false,
      inherit_stdout: false,
      inherit_stderr: false,
      args: [],
      env: %{}
    }
  end
end
