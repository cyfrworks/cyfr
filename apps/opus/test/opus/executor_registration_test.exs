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
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    ctx = %Context{
      user_id: "reg_test_user_#{:rand.uniform(100_000)}",
      org_id: "local",
      project_id: "default",
      scope: :project,
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

  # Every execution now registers its driving process in ExecutionRegistry so
  # cancel/2 can kill it — previously only run_stream and cron registered,
  # leaving synchronous runs and all formula children uncancellable.

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

    assert Registry.lookup(Opus.ExecutionRegistry, execution_id) == []
  end

  test "a pre-registered owner (the run_stream shape) keeps its entry", %{ctx: ctx} do
    execution_id = "exec_reg_owned_#{System.unique_integer([:positive])}"
    parent = self()

    owner =
      spawn_link(fn ->
        # Mirrors Opus.MCP run_stream / cron: the task registers itself,
        # then drives the executor in the same process.
        {:ok, _} = Registry.register(Opus.ExecutionRegistry, execution_id, :running)
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
    assert [{^owner, _}] = Registry.lookup(Opus.ExecutionRegistry, execution_id)

    send(owner, :stop)
  end
end
