# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.SharedEngine do
  @moduledoc """
  Holds a single shared `%Wasmex.Engine{}` for all WASM component executions.

  Sharing one engine enables compile-once/instantiate-many: a compiled
  `Wasmex.Components.Component` works with any Store created from the same
  engine, so `Locus.Runtime.ComponentCache` can skip JIT recompilation on repeat
  executions of the same component.

  The engine is created once at startup; if creation fails, the application
  crashes (no silent fallback).

  ## Fuel Enforcement

  Fuel-based CPU limits require `consume_fuel: true` on the engine and
  `set_fuel/2` on each store. Wasmex exposes no `set_fuel` for Component
  Model stores (`Wasmex.Components.Store`), so the engine runs with
  `consume_fuel: false` and enforces no fuel.

  ## CPU-Time Limitation

  Wasmex runs each store's calls as tasks on its own pool of native
  threads, and its engine turns on epoch interruption only so that a call
  yields its thread every tick: it interrupts a core module's call at the
  call's timeout and never a component's, whose call outlives its caller
  and finishes in the background. So the wall-clock timeout kill in
  `Locus.Runtime.Runner` cannot preempt a component that never returns
  (e.g. a tight compute loop). Killing the waiting BEAM process frees the
  execution slot, but the call keeps one CPU core busy until the runner's
  VM ends: a killed call leaves its runner unclean, and its service ends
  it. Mitigations: CYFR's per-tenant execution slots bound how many such
  loops one tenant can start, and the container CPU quota (docker-compose
  `cpus:`) bounds aggregate damage.
  """

  use Agent

  def start_link(_opts) do
    Agent.start_link(
      fn ->
        case Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: false}) do
          {:ok, engine} ->
            # A fresh generation per engine: compiled components are NIF
            # resources belonging to ONE engine, so a cache entry minted
            # under a previous engine must never be handed to stores built
            # from this one (Locus.Runtime.ComponentCache keys on this value).
            %{engine: engine, generation: :erlang.unique_integer([:positive, :monotonic])}

          {:error, reason} ->
            raise "Locus.Runtime.SharedEngine: failed to create Wasmex engine: #{Prima.LoggerContext.shape(reason)}"
        end
      end,
      name: __MODULE__
    )
  end

  @doc "Returns the shared engine."
  @spec get() :: Wasmex.Engine.t()
  def get, do: Agent.get(__MODULE__, & &1.engine)

  @doc "Opaque identity of the CURRENT engine instance (changes on restart)."
  @spec generation() :: pos_integer()
  def generation, do: Agent.get(__MODULE__, & &1.generation)
end
