# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.TrapTest do
  @moduledoc """
  A guest's trap is the run's error as a trap, in the engine's own words and
  nothing of the guest's input, and never as a component that exports the
  wrong interface; a guest that runs to completion is answered its output.
  The instance's server outlives a trap and serves the instance's next call.
  The guest is `test_wasm/hostile/trapper`, held to the digest its README
  records by `Locus.Runtime.StoreLimitsTest`.
  """

  use ExUnit.Case, async: true

  alias Locus.Runtime.Engine
  alias Locus.Runtime.Test.ScriptedHost

  @guest Path.expand("../../support/runtime/test_wasm/hostile/trapper.wasm", __DIR__)
  @probe Path.expand("../../support/runtime/test_wasm/hostile/vault_probe.wasm", __DIR__)
  @compute ["cyfr:reagent/compute@0.1.0", "compute"]
  @run ["cyfr:catalyst/run@0.1.0", "run"]

  # The library's exact words for the trap of `trapper`'s `unreachable`
  # (wasmex's native `component_execute_function`). The engine tells a
  # failure of the guest's call from any other refusal by them, so a
  # release that rewords them fails here first.
  @trap "Error during function excecution (wasm trap: wasm `unreachable` instruction executed): " <>
          "error while executing at wasm backtrace:\n" <>
          "    0:     0x98 - <unknown>!<wasm function 1>"

  # Its words for a call of `vault_probe` that failed as it ran without a
  # trap, whether its import raised or answered a result the interface
  # does not take: wasmtime's message is the guest's backtrace alone.
  @failed "Error during function excecution: error while executing at wasm backtrace:\n" <>
            "    0:    0x21c - wit-component:shim!indirect-cyfr:vault/read@0.1.0-get\n" <>
            "    1:     0xf1 - <unknown>!<wasm function 2>\n" <>
            "    2:    0x11c - <unknown>!<wasm function 3>"

  # Its words for a call of an instance a trap has left: the component
  # model enters no instance again once it trapped.
  @left "Error during function excecution (wasm trap: cannot enter component instance): " <>
          "wasm trap: cannot enter component instance"

  # What every run carries: an authority, its node's limits and its
  # attempt's host client.
  defp run_opts do
    [
      authority: Prima.Authority.zero(),
      limits: Prima.Authority.zero_limits(),
      host: ScriptedHost.attempt!(ScriptedHost.start!()).client
    ]
  end

  defp run(input), do: Engine.execute_component(File.read!(@guest), input, run_opts())

  test "a component that traps is reported as a trap, not as an interface failure" do
    # As the process a runner runs a component in does (`Locus.Runtime.Attempt`):
    # the instance's server is linked to it.
    Process.flag(:trap_exit, true)
    assert {:error, message} = run(%{"trap" => true})
    assert message == "Component call failed for #{inspect(@compute)}: #{@trap}"
    refute message =~ "Ensure the component exports"

    # The server outlived the trap and was stopped by the engine once the
    # run was over.
    assert_receive {:EXIT, _server, :normal}
  end

  test "an import that fails under the call is the call's failure, not an interface failure" do
    Process.flag(:trap_exit, true)

    # A value the interface's `string` cannot carry, handed back by the
    # vault's `get`: the import's result fails conversion under the call.
    assert {:error, message} =
             Engine.execute_component(
               File.read!(@probe),
               %{"operation" => "probe"},
               [component_type: :catalyst, preloaded_fields: %{"PROBE_KEY" => 7}] ++ run_opts()
             )

    assert message == "Component call failed for #{inspect(@run)}: #{@failed}"
    refute message =~ "Ensure the component exports"
    assert_receive {:EXIT, _server, :normal}
  end

  test "a component that runs to completion is answered its output" do
    assert run(%{"trap" => false}) == {:ok, %{"ran" => true}}
  end

  test "the instance's server survives a trap and answers the next call" do
    {:ok, store} =
      Wasmex.Components.Store.new(
        Engine.store_limits(64 * 1024 * 1024),
        Locus.Runtime.SharedEngine.get()
      )

    {:ok, component} = Wasmex.Components.Component.new(store, File.read!(@guest))

    # Unlinked, as nothing of this test is to end with the server.
    {:ok, pid} =
      GenServer.start(Wasmex.Components, %{store: store, component: component, imports: %{}})

    ref = Process.monitor(pid)

    assert {:error, @trap} =
             Wasmex.Components.call_function(pid, @compute, [~s({"trap":true})], :infinity)

    # The same server answers the next call, which the instance refuses:
    # the engine makes one call of an instance and stops it.
    assert {:error, @left} =
             Wasmex.Components.call_function(pid, @compute, [~s({"trap":false})], :infinity)

    refute_received {:DOWN, ^ref, :process, ^pid, _reason}
    GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "an import that raises fails the call it ran under, and the server serves on" do
    {:ok, store} =
      Wasmex.Components.Store.new_wasi(
        Locus.Runtime.ComponentType.wasi_options(:catalyst),
        Engine.store_limits(64 * 1024 * 1024),
        Locus.Runtime.SharedEngine.get()
      )

    {:ok, component} = Wasmex.Components.Component.new(store, File.read!(@probe))
    imports = %{"cyfr:vault/read@0.1.0" => %{"get" => {:fn, fn _name -> raise "a raise" end}}}

    {:ok, pid} =
      GenServer.start(Wasmex.Components, %{store: store, component: component, imports: imports})

    assert {:error, @failed} =
             Wasmex.Components.call_function(pid, @run, [~s({"operation":"probe"})], :infinity)

    assert Process.alive?(pid)
    assert {:error, @left} = Wasmex.Components.call_function(pid, @run, ["{}"], :infinity)
    GenServer.stop(pid, :normal)
  end
end
