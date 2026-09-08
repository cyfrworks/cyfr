# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TurnStorageTest do
  use ExUnit.Case, async: false

  alias Arca.TurnStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Sanctum.TestContext.athanor!()
    ctx = Sanctum.TestContext.local()
    {:ok, conv} = Arca.ConversationStorage.create(ctx)
    {:ok, ctx: ctx, conv: conv}
  end

  test "a turn is accepted for its execution and closed the way it ended", %{
    ctx: ctx,
    conv: conv
  } do
    exec = "exec_turn_#{System.unique_integer([:positive])}"

    assert {:ok, turn} =
             TurnStorage.accept(ctx, %{
               conversation_id: conv.id,
               execution_id: exec,
               orchestrator: "aqua",
               requested_by: ctx.user_id
             })

    assert String.starts_with?(turn.id, "trn_")
    assert turn.athanor_id == ctx.athanor_id
    assert turn.status == "accepted"
    assert %DateTime{} = turn.accepted_at
    assert is_nil(turn.ended_at)

    assert {:ok, 1} = TurnStorage.close(ctx, exec, "failed", "boom")

    assert {:ok, [%{status: "failed", error: "boom", ended_at: %DateTime{}}]} =
             TurnStorage.list(ctx, conv.id)

    # Closed once: a second closing changes nothing.
    assert {:ok, 0} = TurnStorage.close(ctx, exec, "completed")
    assert {:ok, [%{status: "failed"}]} = TurnStorage.list(ctx, conv.id)
  end

  test "a turn belongs to its athanor: another estate closes nothing and lists nothing", %{
    ctx: ctx,
    conv: conv
  } do
    exec = "exec_turn_#{System.unique_integer([:positive])}"
    {:ok, _} = TurnStorage.accept(ctx, %{conversation_id: conv.id, execution_id: exec})

    other = %{ctx | athanor_id: "ath_elsewhere"}
    assert {:ok, 0} = TurnStorage.close(other, exec, "cancelled")
    assert {:ok, []} = TurnStorage.list(other, conv.id)
    assert {:ok, [%{status: "accepted"}]} = TurnStorage.list(ctx, conv.id)
  end

  test "a turn names a conversation of its own athanor, never another's", %{ctx: ctx} do
    assert {:error, :conversation_not_found} =
             TurnStorage.accept(%{ctx | athanor_id: "ath_elsewhere"}, %{
               conversation_id: "conv_nowhere",
               execution_id: "exec_x"
             })
  end
end
