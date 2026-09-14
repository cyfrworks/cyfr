# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutorRegistrationTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")
  @test_ref "reagent:local.reg-math:0.1.0"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "opus_reg_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    ctx = %Context{
      user_id: "reg_test_user_#{:rand.uniform(100_000)}",
      athanor_id: Sanctum.TestContext.athanor_id(),
      scope: :athanor,
      permissions: MapSet.new([:execute])
    }

    admin_ctx = Sanctum.TestContext.local()
    wasm_bytes = File.read!(@math_wasm_path)

    {:ok, _component} =
      Compendium.Registry.publish_bytes(admin_ctx, wasm_bytes, %{
        name: "reg-math",
        version: "0.1.0",
        type: "reagent",
        description: "Registration test math component"
      })

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx}
  end

  # Every execution process must register for cancellation, including synchronous runs and children.

  test "a synchronous run leaves no registry entry behind", %{ctx: ctx} do
    execution_id = "exec_reg_sync_#{System.unique_integer([:positive])}"

    # math.wasm is a core module, not a Component Model binary, so the run
    # fails at compile — irrelevant here: registration wraps the execution
    # window either way, and the entry must be gone afterwards.
    _result =
      Opus.Executor.run(ctx, @test_ref, %{"a" => 1, "b" => 2},
        type: :reagent,
        execution_id: execution_id
      )

    assert Registry.lookup(Cyfr.Execution.Registry, execution_id) == []
  end

  test "a pre-registered owner (the run_stream shape) keeps its entry", %{ctx: ctx} do
    execution_id = "exec_reg_owned_#{System.unique_integer([:positive])}"
    parent = self()

    owner =
      spawn_link(fn ->
        # Mirrors Cyfr.Execution.MCP run_stream / cron: the task registers itself,
        # then drives the executor in the same process.
        {:ok, _} = Registry.register(Cyfr.Execution.Registry, execution_id, :running)
        send(parent, :registered)

        result =
          Opus.Executor.run(ctx, @test_ref, %{"a" => 2, "b" => 3},
            type: :reagent,
            execution_id: execution_id
          )

        send(parent, {:done, result})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :registered, 5_000
    assert_receive {:done, _result}, 30_000

    # The executor's own register/unregister must not steal or clear the
    # streaming task's entry — it stays until the owner process exits.
    assert [{^owner, _}] = Registry.lookup(Cyfr.Execution.Registry, execution_id)

    send(owner, :stop)
  end

  describe "cancelling reaches the process running the component" do
    test "a linked child that traps exits survives its parent's kill" do
      # The shape the executor uses: the runner is spawn_link'd from the
      # process that registers, and it sets trap_exit so a Wasmex crash
      # becomes a message instead of killing it. A link-propagated exit is
      # trappable whatever its reason — :killed included — so killing the
      # registered process does NOT stop the runner. Only a direct
      # `Process.exit(runner, :kill)` is untrappable. This is why cancel has
      # to name the runner rather than its parent.
      parent_of_all = self()

      registered =
        spawn(fn ->
          runner =
            spawn_link(fn ->
              Process.flag(:trap_exit, true)
              send(parent_of_all, {:runner, self()})
              # Keep working, exactly as a component call would.
              Process.sleep(:infinity)
            end)

          send(parent_of_all, {:registered, self(), runner})
          Process.sleep(:infinity)
        end)

      assert_receive {:registered, ^registered, runner}, 5_000
      assert_receive {:runner, ^runner}, 5_000

      ref = Process.monitor(runner)
      Process.exit(registered, :kill)

      refute_receive {:DOWN, ^ref, :process, ^runner, _}, 300
      assert Process.alive?(runner), "the trapping runner outlived the kill of its parent"

      # ...and the direct kill the fix uses does stop it.
      Process.exit(runner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^runner, _}, 5_000
    end

    test "cancel kills the runner the entry names, not only its parent" do
      # Staged rather than driven through a real component: the repo ships no
      # Component Model fixture (math.wasm is a core module and fails at
      # compile), so this builds the exact registry shape `execute_with_timeout`
      # publishes and asserts what `cancel/3` does with it.
      admin = Sanctum.TestContext.local()

      record =
        Cyfr.Execution.Record.new(admin, "reagent:local.cancel-me:0.1.0", %{},
          component_type: :reagent
        )

      :ok = Cyfr.Execution.Record.write_started(record)

      parent = self()

      runner =
        spawn(fn ->
          Process.flag(:trap_exit, true)
          send(parent, {:runner_up, self()})
          Process.sleep(:infinity)
        end)

      assert_receive {:runner_up, ^runner}, 5_000
      ref = Process.monitor(runner)

      owner =
        spawn(fn ->
          {:ok, _} =
            Registry.register(Cyfr.Execution.Registry, record.id, %{
              status: :running,
              runner_pid: runner
            })

          send(parent, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered, 5_000

      assert {:ok, %{cancelled: true}} = Opus.Executor.cancel(admin, record.id)

      # The runner traps exits, so the link from its parent could never stop
      # it — cancel has to name it.
      assert_receive {:DOWN, ^ref, :process, ^runner, :killed}, 5_000
      refute Process.alive?(owner)
    end
  end
end
