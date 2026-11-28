# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.ExecutorRegistrationTest do
  use ExUnit.Case, async: false

  @node "reagent:local.reg-math"
  @test_ref "#{@node}:0.1.0"

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "runtime_reg_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    # A person on the console, in their own athanor, running a component
    # they published and consented as a person consents one: each run is
    # rooted under that consent's authority (`Opus.run_root/5`).
    {ctx, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
    ctx = %{ctx | origin: :interactive, athanor_id: Sanctum.Test.People.athanor!(user).id}
    Sanctum.TestContext.ready!(ctx.athanor_id)

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
        name: "reg-math",
        version: "0.1.0",
        type: "reagent",
        description: "Registration test math component"
      })

    decisions = %{ref: @node}
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: @node})
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    {:ok, ctx: ctx}
  end

  # Every run's waiter registers for cancellation, including synchronous
  # runs and children; each run here completes with the guest's answer, so
  # the registry is read after a run that happened.

  test "a synchronous run leaves no registry entry behind", %{ctx: ctx} do
    execution_id = "exec_reg_sync_#{System.unique_integer([:positive])}"

    # Registration wraps the execution window, and the entry must be gone
    # afterwards.
    assert {:ok, %{status: :completed, output: %{"ran" => true}}} =
             run(ctx, %{"a" => 1, "b" => 2}, execution_id)

    assert Registry.lookup(Opus.Registry, execution_id) == []
  end

  test "a pre-registered owner (a turn root's shape) keeps its entry", %{ctx: ctx} do
    execution_id = "exec_reg_owned_#{System.unique_integer([:positive])}"
    parent = self()

    owner =
      spawn_link(fn ->
        # Mirrors a turn's root (Opus.TurnRoot): the task registers itself,
        # then dispatches the run from the same process.
        {:ok, _} = Registry.register(Opus.Registry, execution_id, :running)
        send(parent, :registered)
        send(parent, {:done, run(ctx, %{"a" => 2, "b" => 3}, execution_id)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :registered, 5_000
    assert_receive {:done, {:ok, %{status: :completed, output: %{"ran" => true}}}}, 30_000

    # The dispatch's own register/unregister must not steal or clear the
    # streaming task's entry — it stays until the owner process exits.
    assert [{^owner, _}] = Registry.lookup(Opus.Registry, execution_id)

    send(owner, :stop)
  end

  defp run(ctx, input, execution_id),
    do:
      Opus.run_root(ctx, :default, @test_ref, input, execution_id: execution_id, type: "reagent")
end
