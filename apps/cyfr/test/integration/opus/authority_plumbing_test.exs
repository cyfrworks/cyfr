# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.AuthorityPlumbingTest do
  # Verify the authority a run is dispatched with is the one its runner is
  # handed at its attach, read on the suite's wire, and that
  # authority_required fails closed at admission, with nothing attached.
  # The runtime's own re-check of authority_required is
  # `Opus.RuntimeTest`'s, in Opus's suite.
  use ExUnit.Case, async: false

  alias Cyfr.Test.TwoServices
  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../../support/test_wasm/math.wasm")
  @test_ref "reagent:local.authority-plumb:0.1.0"

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    TwoServices.watch!()

    test_path = Path.join(System.tmp_dir!(), "opus_auth_plumb_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    ctx = %Context{
      user_id: "auth_plumb_user_#{:rand.uniform(100_000)}",
      athanor_id: Sanctum.TestContext.athanor_id(),
      scope: :athanor,
      permissions: MapSet.new([:execute])
    }

    admin_ctx = Sanctum.TestContext.local()
    wasm_bytes = File.read!(@math_wasm_path)

    {:ok, _component} =
      Compendium.Registry.publish_bytes(admin_ctx, wasm_bytes, %{
        name: "authority-plumb",
        version: "0.1.0",
        type: "reagent",
        description: "Authority plumbing sentinel component"
      })

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    {:ok, ctx: ctx}
  end

  # Whether any run attached while the test watched the suite's wire.
  defp attached? do
    Enum.any?(TwoServices.calls(), &match?(%{callback: :attach}, &1))
  end

  # The authority as an assignment carries it to its runner: every member
  # but the budget's cap, which a decoded copy never charges.
  defp as_assigned(authority) do
    {:ok, decoded} = Cyfr.Authority.from_wire(Cyfr.Authority.to_wire(authority))
    decoded
  end

  # math.wasm is a core module, not a Component Model binary, so every run
  # here fails at component compile. That is irrelevant: its runner attaches,
  # and the required-check runs, before compilation is attempted.

  test "an :authority passed to a dispatched run reaches its runner as its assignment carries it",
       %{ctx: ctx} do
    authority = Cyfr.Authority.zero()
    execution_id = "exec_auth_plumb_#{System.unique_integer([:positive])}"

    _result =
      Cyfr.Execution.Dispatch.run(ctx, @test_ref, %{"a" => 1, "b" => 2},
        type: :reagent,
        execution_id: execution_id,
        authority: authority
      )

    assert TwoServices.entered(execution_id) == as_assigned(authority)
  end

  test "a run without an authority fails closed, executing nothing", %{ctx: ctx} do
    # Admission raises for a missing authority, and the raise closes the
    # run failed before it reaches the runtime.
    assert {:error, message} =
             Cyfr.Execution.Dispatch.run(ctx, @test_ref, %{"a" => 1, "b" => 2}, type: :reagent)

    assert message =~ "without an authority is not a thing"
    refute attached?()
  end

  test "authority_required without an authority fails closed, executing nothing", %{ctx: ctx} do
    assert {:error, message} =
             Cyfr.Execution.Dispatch.run(ctx, @test_ref, %{"a" => 1, "b" => 2},
               type: :reagent,
               authority_required: true
             )

    assert message =~ "without an authority"
    refute attached?()
  end

  test "authority_required with an authority proceeds to its runner", %{ctx: ctx} do
    authority = Cyfr.Authority.zero()
    execution_id = "exec_auth_plumb_#{System.unique_integer([:positive])}"

    _result =
      Cyfr.Execution.Dispatch.run(ctx, @test_ref, %{"a" => 1, "b" => 2},
        type: :reagent,
        execution_id: execution_id,
        authority: authority,
        authority_required: true
      )

    assert TwoServices.entered(execution_id) == as_assigned(authority)
  end
end
