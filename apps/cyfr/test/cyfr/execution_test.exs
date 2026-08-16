# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ExecutionTest do
  @moduledoc """
  The execution port: cyfr reaches the engine through `Cyfr.Execution`, the
  engine registers itself, and a build without one answers unavailable.
  """
  use ExUnit.Case, async: false

  defmodule FakeEngine do
    @behaviour Cyfr.Execution
    def run_root(_ctx, sel, ref, input, opts),
      do: {:ok, %{sel: sel, ref: ref, input: input, opts: opts}}

    def run_root_edge(_ctx, src, ref, _input, _opts), do: {:ok, %{src: src, ref: ref}}
    def authority_for(_ctx, _sel, _ref, _opts), do: {:ok, :authority}
    def subscribe_events(_id, _ctx), do: :ok
    def unsubscribe_events(_id, _ctx), do: :ok
    def events_since(_id, _seq, _athanor), do: [%{seq: 1}]
    def cancel(_ctx, id), do: {:ok, id}
    def cancel_for_restart(_ctx, _id, _payload), do: :ok
    def get(_ctx, id), do: {:ok, %{id: id}}
    def list(_ctx, _opts), do: {:ok, []}
    def ready?, do: true
  end

  setup do
    original = Application.get_env(:cyfr, :execution_impl)

    on_exit(fn ->
      if original,
        do: Application.put_env(:cyfr, :execution_impl, original),
        else: Application.delete_env(:cyfr, :execution_impl)
    end)

    :ok
  end

  test "without an engine every call answers unavailable" do
    Application.delete_env(:cyfr, :execution_impl)
    refute Cyfr.Execution.available?()
    ctx = Sanctum.TestContext.local()
    assert {:error, :execution_unavailable} = Cyfr.Execution.run_root(ctx, nil, "f:local.x", %{})
    assert {:error, :execution_unavailable} = Cyfr.Execution.cancel(ctx, "exec_1")
    assert Cyfr.Execution.events_since("exec_1", 0, ctx.athanor_id) == []
  end

  test "a registered engine answers through the port" do
    Application.put_env(:cyfr, :execution_impl, FakeEngine)
    assert Cyfr.Execution.available?()
    ctx = Sanctum.TestContext.local()

    assert {:ok, %{ref: "f:local.x", opts: [route: :protected]}} =
             Cyfr.Execution.run_root(ctx, "prof", "f:local.x", %{}, route: :protected)

    assert {:ok, "exec_1"} = Cyfr.Execution.cancel(ctx, "exec_1")
    assert [%{seq: 1}] = Cyfr.Execution.events_since("exec_1", 0, ctx.athanor_id)
  end

  @tag :requires_opus
  test "the engine registers itself when it starts" do
    assert Cyfr.Execution.impl() == Opus
    assert Cyfr.Execution.available?()
  end
end
