# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ProgramGrantTest do
  @moduledoc """
  A standing answer to start a program: it covers the row the call names
  and no other, whatever the card sent (`Aqua.Standing`), and it stands
  on that row as the row's other grants do: the row's confirmation names
  it (`Sanctum.Mount.granted_to/2`) and the row's removal ends it.
  """
  use ExUnit.Case, async: false

  alias Arca.ThreadStorage, as: Threads

  setup do
    Cyfr.Test.Sandbox.setup!()

    {:ok, user} =
      Sanctum.Test.People.linked(%{id: "grant-person", provider: "local", verified: true})

    athanor = Sanctum.Test.People.athanor!(user)

    ctx = %{
      Sanctum.TestContext.local()
      | user_id: user.id,
        athanor_id: athanor.id,
        permissions: MapSet.new([:*])
    }

    {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))
    turn = %{id: "turn_1", thread_id: thread.id, agent: "aqua", root_execution_id: nil}
    {:ok, ctx: ctx, turn: turn, gh: row!(ctx, "gh"), jq: row!(ctx, "jq")}
  end

  defp row!(ctx, name) do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: name,
        transport: "program",
        mark: "driven",
        url: nil,
        home: "kept",
        config_json: Jason.encode!(%{"command" => name, "env" => %{}})
      })

    row
  end

  defp start(row_id),
    do: %{"tool" => "program", "action" => "start", "args" => %{"program" => row_id}}

  defp allow!(ctx, turn, row, scope \\ :always) do
    {:ok, [grant]} = Aqua.Standing.rows(ctx, turn, start(row.id), scope)
    {:ok, _} = Sanctum.ToolGrants.put(ctx, grant)
    grant
  end

  test "an answer for every start covers the call's own row, whatever the card sent",
       %{ctx: ctx, turn: turn, gh: gh, jq: jq} do
    for scope <- [:always, :thread] do
      assert {:ok, [%{constraint: %{kind: "program_row", patterns: [id]}}]} =
               Aqua.Standing.rows(ctx, turn, start(gh.id), scope)

      assert id == gh.id

      wider = %{constraint: %{kind: "program_row", patterns: [gh.id, jq.id]}}

      assert {:ok, [%{constraint: %{patterns: [^id]}}]} =
               Aqua.Standing.rows(ctx, turn, start(gh.id), scope, wider)
    end

    assert {:error, {:scope_not_permitted, :unconstrained_program}} =
             Aqua.Standing.rows(ctx, turn, %{start(gh.id) | "args" => %{}}, :always)

    # A never is a deny for every start, as any deny is.
    assert {:ok, [%{effect: "deny"} = deny]} = Aqua.Standing.rows(ctx, turn, start(gh.id), :never)
    refute Map.get(deny, :constraint)
  end

  test "the row's grants name the answer, and its removal ends it and leaves another row's",
       %{ctx: ctx, turn: turn, gh: gh, jq: jq} do
    # One standing answer per agent, tool and action at a scope: these two
    # stand side by side because one is the agent's and one the thread's.
    allow!(ctx, turn, gh)
    allow!(ctx, turn, jq, :thread)

    assert {:ok, ["aqua: every start of gh"]} = Sanctum.Mount.granted_to(ctx.athanor_id, gh)

    assert {:ok, _deleted} = Arca.McpServerStorage.delete(Sanctum.Context.actor(ctx), "gh")

    assert {:ok, []} = Arca.ToolGrantStorage.on_program_row(Sanctum.Context.actor(ctx), gh.id)

    assert {:ok, [%{constraint: %{patterns: [jq_id]}}]} =
             Arca.ToolGrantStorage.on_program_row(Sanctum.Context.actor(ctx), jq.id)

    assert jq_id == jq.id
    assert {:ok, ["aqua: every start of jq"]} = Sanctum.Mount.granted_to(ctx.athanor_id, jq)
  end

  test "a change of the row's definition ends its every-start answer; enabling and disabling keep it",
       %{ctx: ctx, turn: turn, gh: gh} do
    actor = Sanctum.Context.actor(ctx)
    allow!(ctx, turn, gh)

    start = %{
      agent_name: "aqua",
      thread_id: turn.thread_id,
      tool: "program",
      action: "start",
      args: %{"program" => gh.id, "epoch" => gh.epoch},
      sources: []
    }

    assert Sanctum.ToolGrants.admits?(ctx, start)

    # The change's confirmation names it among the grants that end.
    assert {:ok, ["aqua: every start of gh"]} = Sanctum.Mount.granted_to(ctx.athanor_id, gh)

    {:ok, off} = Arca.McpServerStorage.update(actor, "gh", %{enabled: false})
    {:ok, on} = Arca.McpServerStorage.update(actor, "gh", %{enabled: true})
    assert on.epoch == off.epoch + 1
    assert Sanctum.ToolGrants.admits?(ctx, start)

    # The same definition written again moves nothing.
    {:ok, same} = Arca.McpServerStorage.update(actor, "gh", %{config_json: gh.config_json})
    assert Sanctum.ToolGrants.admits?(ctx, start)

    changed = Jason.encode!(%{"command" => "gh --hostname evil.example", "env" => %{}})

    assert {:ok, _moved} =
             Arca.McpServerStorage.update(actor, "gh", %{config_json: changed}, %{
               id: gh.id,
               epoch: same.epoch
             })

    refute Sanctum.ToolGrants.admits?(ctx, start)
    assert {:ok, []} = Arca.ToolGrantStorage.on_program_row(actor, gh.id)
    assert {:ok, []} = Sanctum.Mount.granted_to(ctx.athanor_id, gh)
  end

  test "an update that finds its row moved writes nothing and ends nothing",
       %{ctx: ctx, turn: turn, gh: gh} do
    actor = Sanctum.Context.actor(ctx)
    allow!(ctx, turn, gh)
    changed = Jason.encode!(%{"command" => "gh2", "env" => %{}})

    assert {:error, :stale_epoch} =
             Arca.McpServerStorage.update(actor, "gh", %{config_json: changed}, %{
               id: gh.id,
               epoch: gh.epoch + 1
             })

    assert {:ok, [_still]} = Arca.ToolGrantStorage.on_program_row(actor, gh.id)

    assert {:error, :not_found} =
             Arca.McpServerStorage.update(actor, "nobody", %{config_json: changed})
  end

  test "the soul's policy asks for a start and a send, and never makes a start automatic" do
    refute Aqua.Kinds.auto_permitted?("program", "start")
    assert Aqua.Kinds.auto_permitted?("program", "list")
    assert Aqua.Kinds.standing_for("program", "send") == :thread
  end
end
