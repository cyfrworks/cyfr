# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/opus_service_helper.exs", __DIR__)

defmodule Opus.AuthorityPlumbingTest do
  # Verify the authority a run's assignment carries survives the
  # runtime-option allowlist, and that authority_required fails closed in
  # both admission and runtime.
  use ExUnit.Case, async: false

  @moduletag :requires_opus

  setup_all do
    Cyfr.Test.Integration.Opus.ensure_started!()
    :ok
  end

  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../../support/test_wasm/math.wasm")
  @test_ref "reagent:local.authority-plumb:0.1.0"
  @telemetry_event [:cyfr, :opus, :runtime, :authority_entered]

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

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

    {:ok, ctx: ctx}
  end

  defp attach_witness do
    handler_id = "authority-witness-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @telemetry_event,
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:authority_entered, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # The authority as an assignment carries it to its runner: every member
  # but the budget's cap, which a decoded copy never charges.
  defp as_assigned(authority) do
    {:ok, decoded} = Cyfr.Authority.from_wire(Cyfr.Authority.to_wire(authority))
    decoded
  end

  # math.wasm is a core module, not a Component Model binary, so every run
  # here fails at component compile. That is irrelevant: the witness fires
  # and the required-check runs before compilation is attempted.

  test "an :authority passed to a dispatched run reaches the runtime as its assignment carries it",
       %{ctx: ctx} do
    attach_witness()
    authority = Cyfr.Authority.zero()
    execution_id = "exec_auth_plumb_#{System.unique_integer([:positive])}"

    _result =
      Cyfr.Execution.Dispatch.run(ctx, @test_ref, %{"a" => 1, "b" => 2},
        type: :reagent,
        execution_id: execution_id,
        authority: authority
      )

    assert_receive {:authority_entered, metadata}, 30_000
    assert metadata.authority == as_assigned(authority)
    assert metadata.execution_id == execution_id
  end

  test "a run without an authority fails closed, executing nothing", %{ctx: ctx} do
    attach_witness()

    # Admission raises for a missing authority, and the raise closes the
    # run failed before it reaches the runtime.
    assert {:error, message} =
             Cyfr.Execution.Dispatch.run(ctx, @test_ref, %{"a" => 1, "b" => 2}, type: :reagent)

    assert message =~ "without an authority is not a thing"
    refute_receive {:authority_entered, _}, 500
  end

  test "authority_required without an authority fails closed, executing nothing", %{ctx: ctx} do
    attach_witness()

    assert {:error, message} =
             Cyfr.Execution.Dispatch.run(ctx, @test_ref, %{"a" => 1, "b" => 2},
               type: :reagent,
               authority_required: true
             )

    assert message =~ "without an authority"
    refute_receive {:authority_entered, _}, 100
  end

  test "authority_required with an authority proceeds to the runtime", %{ctx: ctx} do
    attach_witness()
    authority = Cyfr.Authority.zero()

    _result =
      Cyfr.Execution.Dispatch.run(ctx, @test_ref, %{"a" => 1, "b" => 2},
        type: :reagent,
        authority: authority,
        authority_required: true
      )

    assert_receive {:authority_entered, metadata}, 30_000
    assert metadata.authority == as_assigned(authority)
  end

  test "the runtime itself re-checks authority_required" do
    assert_raise ArgumentError, ~r/an opts filter dropped it/, fn ->
      Opus.Runtime.execute_component(<<0, 1, 2, 3>>, %{}, authority_required: true)
    end
  end

  test "the runtime accepts authority_required when the authority is present" do
    # Garbage bytes fail at compile, not at the authority check — proving the
    # check passed and execution was attempted.
    result =
      Opus.Runtime.execute_component(<<0, 1, 2, 3>>, %{},
        authority: Cyfr.Authority.zero(),
        authority_required: true
      )

    assert {:error, _} = result
  end
end
