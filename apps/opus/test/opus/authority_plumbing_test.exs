# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.AuthorityPlumbingTest do
  # The executor filters runtime opts through a Keyword.take allowlist before
  # they cross the spawn boundary into Opus.Runtime. If :authority were dropped
  # from that list, a chain's granted capabilities would be silently stripped
  # and the guest would run on ambient permissions — failing open with no
  # compile error. These tests are the tripwire: the sentinel must arrive
  # inside the runtime, and :authority_required must fail closed at both the
  # executor and the runtime layer.
  use ExUnit.Case, async: false

  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")
  @test_ref "reagent:local.authority-plumb:0.1.0"
  @telemetry_event [:opus, :runtime, :authority_entered]

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

  # math.wasm is a core module, not a Component Model binary, so every run
  # here fails at component compile. That is irrelevant: the witness fires
  # and the required-check runs before compilation is attempted.

  test "an :authority passed to Executor.run reaches the runtime intact", %{ctx: ctx} do
    attach_witness()
    authority = Sanctum.Authority.zero()
    execution_id = "exec_auth_plumb_#{System.unique_integer([:positive])}"

    _result =
      Opus.Executor.run(ctx, @test_ref, %{"a" => 1, "b" => 2},
        type: :reagent,
        execution_id: execution_id,
        authority: authority
      )

    assert_receive {:authority_entered, metadata}, 30_000
    assert metadata.authority == authority
    assert metadata.execution_id == execution_id
  end

  test "a run without an authority fails closed, executing nothing", %{ctx: ctx} do
    attach_witness()

    # The enforcement stage raises for a missing authority; the pipeline
    # rescue converts that into a failed execution that never reached the
    # runtime.
    assert {:error, message} =
             Opus.Executor.run(ctx, @test_ref, %{"a" => 1, "b" => 2}, type: :reagent)

    assert message =~ "without an authority is not a thing"
    refute_receive {:authority_entered, _}, 500
  end

  test "authority_required without an authority fails closed, executing nothing", %{ctx: ctx} do
    attach_witness()

    assert {:error, message} =
             Opus.Executor.run(ctx, @test_ref, %{"a" => 1, "b" => 2},
               type: :reagent,
               authority_required: true
             )

    assert message =~ "without an authority"
    refute_receive {:authority_entered, _}, 100
  end

  test "authority_required with an authority proceeds to the runtime", %{ctx: ctx} do
    attach_witness()
    authority = Sanctum.Authority.zero()

    _result =
      Opus.Executor.run(ctx, @test_ref, %{"a" => 1, "b" => 2},
        type: :reagent,
        authority: authority,
        authority_required: true
      )

    assert_receive {:authority_entered, metadata}, 30_000
    assert metadata.authority == authority
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
        authority: Sanctum.Authority.zero(),
        authority_required: true
      )

    assert {:error, _} = result
  end
end
