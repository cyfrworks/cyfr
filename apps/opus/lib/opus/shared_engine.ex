defmodule Opus.SharedEngine do
  @moduledoc """
  Holds a single shared `%Wasmex.Engine{}` for all WASM component executions.

  Sharing one engine enables compile-once/instantiate-many: a compiled
  `Wasmex.Components.Component` works with any Store created from the same
  engine, so `Opus.ComponentCache` can skip JIT recompilation on repeat
  executions of the same component.

  The engine is created once at startup; if creation fails, the application
  crashes (no silent fallback).

  Must be started before `Opus.ExecutionSemaphore` in the supervisor tree.

  ## Fuel Enforcement

  Fuel-based CPU limits require `consume_fuel: true` on the engine AND
  calling `set_fuel/2` on each store. Wasmex does not currently expose
  `set_fuel` for Component Model stores (`Wasmex.Components.Store`),
  so fuel enforcement is not yet possible for components. The engine
  uses `consume_fuel: false` until Wasmex adds this capability.
  """

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn ->
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: false})
      engine
    end, name: __MODULE__)
  end

  @doc "Returns the shared engine."
  @spec get() :: Wasmex.Engine.t()
  def get, do: Agent.get(__MODULE__, & &1)
end
