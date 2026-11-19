# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ProgramGrantTest do
  @moduledoc """
  A standing answer to start a program covers the one row its constraint
  names (`Sanctum.ToolGrants`), and it stands on that row as the row's
  other grants do: the row's confirmation names it
  (`Sanctum.Mount.granted_to/2`) and the row's removal ends it.
  """
  use ExUnit.Case, async: false

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

    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
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

  # A standing allow to start `row`, at agent scope for `:always` and at
  # thread scope for `:thread`, constrained to that row, with `bounds`.
  defp start_grant(turn, row, scope, bounds \\ %{}) do
    Map.merge(
      %{
        scope: if(scope == :thread, do: "thread", else: "agent"),
        effect: "allow",
        thread_id: turn.thread_id,
        agent_name: turn.agent,
        tool: "program",
        action: "start",
        constraint: %{kind: "program_row", patterns: [row.id]}
      },
      bounds
    )
  end

  defp allow!(ctx, turn, row, scope \\ :always) do
    {:ok, grant} = Sanctum.ToolGrants.put(ctx, start_grant(turn, row, scope))
    grant
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

  describe "one answer per program" do
    defp start_call(turn, row),
      do: %{
        agent_name: "aqua",
        thread_id: turn.thread_id,
        tool: "program",
        action: "start",
        args: %{"program" => row.id, "epoch" => row.epoch},
        sources: []
      }

    defp allow_until!(ctx, turn, row, until) do
      {:ok, _} =
        Sanctum.ToolGrants.put(ctx, start_grant(turn, row, :always, %{expires_at: until}))
    end

    defp stored(ctx) do
      import Ecto.Query

      Arca.Repo.all(
        from(g in Arca.Schemas.ToolGrant,
          where: g.athanor_id == ^ctx.athanor_id and g.tool == "program",
          order_by: g.program_row
        )
      )
      |> Map.new(&{&1.program_row, &1.expires_at})
    end

    test "gh's answer and jq's stand side by side, each with its own bounds",
         %{ctx: ctx, turn: turn, gh: gh, jq: jq} do
      soon = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:microsecond)
      allow_until!(ctx, turn, gh, soon)
      allow!(ctx, turn, jq)

      assert stored(ctx) == %{gh.id => soon, jq.id => nil}
      assert Sanctum.ToolGrants.admits?(ctx, start_call(turn, gh))
      assert Sanctum.ToolGrants.admits?(ctx, start_call(turn, jq))
    end

    test "a second answer for gh replaces gh's alone", %{ctx: ctx, turn: turn, gh: gh, jq: jq} do
      soon = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:microsecond)
      allow!(ctx, turn, gh)
      allow_until!(ctx, turn, jq, soon)
      allow_until!(ctx, turn, gh, soon)

      assert stored(ctx) == %{gh.id => soon, jq.id => soon}
    end

    test "revoking one program's answer leaves the other's; a revoke that names no program is refused",
         %{ctx: ctx, turn: turn, gh: gh, jq: jq} do
      allow!(ctx, turn, gh)
      allow!(ctx, turn, jq)
      key = %{scope: "agent", agent_name: "aqua", tool: "program", action: "start"}

      assert {:error, {:invalid, %{program_row: ["names the program whose answer is withdrawn"]}}} =
               Sanctum.ToolGrants.revoke(ctx, key)

      assert Map.keys(stored(ctx)) == Enum.sort([gh.id, jq.id])

      assert :ok = Sanctum.ToolGrants.revoke(ctx, Map.put(key, :program_row, gh.id))
      assert Map.keys(stored(ctx)) == [jq.id]
      refute Sanctum.ToolGrants.admits?(ctx, start_call(turn, gh))
      assert Sanctum.ToolGrants.admits?(ctx, start_call(turn, jq))
    end

    test "a never stays the one answer for every start, and beats each program's allow",
         %{ctx: ctx, turn: turn, gh: gh} do
      allow!(ctx, turn, gh)

      {:ok, _} =
        Sanctum.ToolGrants.put(ctx, %{
          scope: "agent",
          effect: "deny",
          agent_name: turn.agent,
          tool: "program",
          action: "start"
        })

      assert Map.keys(stored(ctx)) == ["", gh.id]
      refute Sanctum.ToolGrants.admits?(ctx, start_call(turn, gh))
    end
  end

  describe "an answer is written only for a program that stands as it was shown" do
    # The allow a decision on the card's `epoch` of `row` builds.
    defp start_at(turn, row, epoch),
      do: start_grant(turn, row, :always, %{program_epoch: epoch})

    test "a program that does not exist, or is another athanor's, takes no answer",
         %{ctx: ctx, turn: turn} do
      assert {:error, {:scope_not_permitted, :no_program}} =
               Sanctum.ToolGrants.grant_row(
                 ctx,
                 start_grant(turn, %{id: "no_such_program"}, :always)
               )

      {:ok, other} =
        Sanctum.Test.People.linked(%{id: "grant-other", provider: "local", verified: true})

      other_athanor = Sanctum.Test.People.athanor!(other)
      theirs_ctx = %{ctx | user_id: other.id, athanor_id: other_athanor.id}
      theirs = row!(theirs_ctx, "theirs")

      assert {:error, {:scope_not_permitted, :no_program}} =
               Sanctum.ToolGrants.grant_row(ctx, start_grant(turn, theirs, :always))

      # The store refuses it too, whoever built the row.
      row = %{
        id: "grant_forged",
        athanor_id: ctx.athanor_id,
        scope: "agent",
        effect: "allow",
        agent_name: "aqua",
        tool: "program",
        action: "start",
        granted_at: DateTime.utc_now(),
        constraint: %{kind: "program_row", patterns: [theirs.id]}
      }

      assert {:error, :no_program} = Arca.ToolGrantStorage.put(row)

      assert {:ok, []} =
               Arca.ToolGrantStorage.on_program_row(Sanctum.Context.actor(ctx), theirs.id)
    end

    test "a decision racing the row's removal lands before it and goes with it, or is refused",
         %{ctx: ctx, turn: turn, gh: gh, jq: jq} do
      actor = Sanctum.Context.actor(ctx)

      # Written first: the removal ends it.
      allow!(ctx, turn, jq)
      {:ok, _} = Arca.McpServerStorage.delete(actor, "jq")
      assert {:ok, []} = Arca.ToolGrantStorage.on_program_row(actor, jq.id)

      # Decided before the removal, written after it: refused, nothing kept.
      {:ok, grant} = Sanctum.ToolGrants.grant_row(ctx, start_at(turn, gh, gh.epoch))
      {:ok, _} = Arca.McpServerStorage.delete(actor, "gh")
      assert {:error, :no_program} = Arca.ToolGrantStorage.put(grant)

      assert {:error, {:scope_not_permitted, :no_program}} =
               Sanctum.ToolGrants.put(ctx, grant)

      assert {:ok, []} = Arca.ToolGrantStorage.on_program_row(actor, gh.id)
    end

    test "a decision racing the row's change lands before it and goes with it, or is refused",
         %{ctx: ctx, turn: turn, gh: gh, jq: jq} do
      actor = Sanctum.Context.actor(ctx)
      changed = fn name -> Jason.encode!(%{"command" => "#{name} --other", "env" => %{}}) end

      # Written first: the change ends it.
      {:ok, first} = Sanctum.ToolGrants.grant_row(ctx, start_at(turn, jq, jq.epoch))
      {:ok, _} = Sanctum.ToolGrants.put(ctx, first)
      {:ok, _} = Arca.McpServerStorage.update(actor, "jq", %{config_json: changed.("jq")})
      assert {:ok, []} = Arca.ToolGrantStorage.on_program_row(actor, jq.id)

      # Decided on the card's epoch, written after the change: refused.
      {:ok, grant} = Sanctum.ToolGrants.grant_row(ctx, start_at(turn, gh, gh.epoch))
      {:ok, moved} = Arca.McpServerStorage.update(actor, "gh", %{config_json: changed.("gh")})
      assert {:error, :program_changed} = Arca.ToolGrantStorage.put(grant)

      assert {:error, {:scope_not_permitted, :program_changed}} =
               Sanctum.ToolGrants.put(ctx, grant)

      # Decided on the old epoch after the change: refused before anything.
      assert {:error, {:scope_not_permitted, :program_changed}} =
               Sanctum.ToolGrants.grant_row(ctx, start_at(turn, gh, gh.epoch))

      # On the epoch it holds now, it stands.
      assert {:ok, now} = Sanctum.ToolGrants.grant_row(ctx, start_at(turn, gh, moved.epoch))
      assert {:ok, _} = Sanctum.ToolGrants.put(ctx, now)
    end
  end

  describe "the store reads a constraint one way, whatever its keys" do
    defp stored_row(ctx, constraint) do
      %{
        id: "grant_#{System.unique_integer([:positive])}",
        athanor_id: ctx.athanor_id,
        scope: "agent",
        effect: "allow",
        agent_name: "aqua",
        tool: "program",
        action: "start",
        granted_at: DateTime.utc_now(),
        constraint: constraint
      }
    end

    test "a program row that does not stand is refused, keyed by atoms or by strings",
         %{ctx: ctx} do
      for constraint <- [
            %{kind: "program_row", patterns: ["missing_program"]},
            %{kind: :program_row, patterns: ["missing_program"]},
            %{"kind" => "program_row", "patterns" => ["missing_program"]}
          ] do
        assert {:error, :no_program} =
                 Arca.ToolGrantStorage.put(stored_row(ctx, constraint)),
               inspect(constraint)
      end
    end

    test "a program row that stands is the answer's, keyed by atoms or by strings",
         %{ctx: ctx, gh: gh} do
      for constraint <- [
            %{"kind" => "program_row", "patterns" => [gh.id]},
            %{kind: "program_row", patterns: [gh.id]}
          ] do
        assert {:ok, %{program_row: row}} =
                 Arca.ToolGrantStorage.put(stored_row(ctx, constraint))

        assert row == gh.id
      end
    end

    test "a program row constraint names exactly one row, or the write is refused",
         %{ctx: ctx, gh: gh, jq: jq} do
      for constraint <- [
            %{"kind" => "program_row", "patterns" => [gh.id, jq.id]},
            %{kind: "program_row", patterns: [gh.id, jq.id]}
          ] do
        assert {:error, {:invalid, %{constraint: ["names exactly one program row"]}}} =
                 Arca.ToolGrantStorage.put(stored_row(ctx, constraint))
      end

      assert {:ok, []} = Arca.ToolGrantStorage.on_program_row(Sanctum.Context.actor(ctx), gh.id)
    end
  end

  test "a program the store cannot read just now takes no standing answer, and nothing is written",
       %{ctx: ctx, turn: turn, gh: gh} do
    {:ok, built} = Sanctum.ToolGrants.grant_row(ctx, start_grant(turn, gh, :always))
    Arca.Repo.query!("ALTER TABLE mcp_servers RENAME TO unread_mcp_servers")

    try do
      assert {:error, {:scope_not_permitted, :program_unavailable}} =
               Sanctum.ToolGrants.grant_row(ctx, start_grant(turn, gh, :always))

      assert {:error, {:scope_not_permitted, :program_unavailable}} =
               Sanctum.ToolGrants.put(ctx, built)
    after
      Arca.Repo.query!("ALTER TABLE unread_mcp_servers RENAME TO mcp_servers")
    end

    assert {:ok, []} = Arca.ToolGrantStorage.on_program_row(Sanctum.Context.actor(ctx), gh.id)
  end

  test "a start is never auto-permitted, a list is, and a send stands for one thread only" do
    refute Sanctum.Catalog.auto_permitted?("program", "start")
    assert Sanctum.Catalog.auto_permitted?("program", "list")
    assert {:ok, %{standing: :thread}} = Sanctum.Catalog.action_declaration("program.send")
  end
end
