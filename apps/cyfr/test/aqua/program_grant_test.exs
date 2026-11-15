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
      {:ok, [grant]} = Aqua.Standing.rows(ctx, turn, start(row.id), :always, %{until: until})
      {:ok, _} = Sanctum.ToolGrants.put(ctx, grant)
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

      # The chat lists each by its program's name, its row behind it.
      assert {:ok, listed} = Aqua.ToolGrants.allowed_by_agent(ctx, turn.thread_id)

      assert listed ==
               MapSet.new([
                 {"aqua", "program", "start", %{id: gh.id, name: "gh"}},
                 {"aqua", "program", "start", %{id: jq.id, name: "jq"}}
               ])

      # A renamed row's answer reads as the program it covers.
      import Ecto.Query

      {1, _} =
        Arca.Repo.update_all(from(s in Arca.Schemas.McpServer, where: s.id == ^gh.id),
          set: [name: "github"]
        )

      assert {:ok, renamed} = Aqua.ToolGrants.allowed_by_agent(ctx, turn.thread_id)
      assert {"aqua", "program", "start", %{id: gh.id, name: "github"}} in renamed
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

    test "the thread's revoke names the program, and refuses one that names none",
         %{ctx: ctx, turn: turn, gh: gh, jq: jq} do
      allow!(ctx, turn, gh, :thread)
      allow!(ctx, turn, jq, :thread)

      assert {:error, _named_none} =
               Aqua.Runner.revoke_grant(ctx, turn.thread_id, "aqua", "program", "start")

      assert Map.keys(stored(ctx)) == Enum.sort([gh.id, jq.id])

      assert :ok =
               Aqua.Runner.revoke_grant(ctx, turn.thread_id, "aqua", "program", "start", jq.id)

      assert Map.keys(stored(ctx)) == [gh.id]
    end

    test "a never stays the one answer for every start, and beats each program's allow",
         %{ctx: ctx, turn: turn, gh: gh} do
      allow!(ctx, turn, gh)
      {:ok, [deny]} = Aqua.Standing.rows(ctx, turn, start(gh.id), :never)
      {:ok, _} = Sanctum.ToolGrants.put(ctx, deny)

      assert Map.keys(stored(ctx)) == ["", gh.id]
      refute Sanctum.ToolGrants.admits?(ctx, start_call(turn, gh))
      assert {:ok, listed} = Aqua.ToolGrants.allowed_by_agent(ctx, turn.thread_id)
      assert listed == MapSet.new()
    end
  end

  describe "an answer is written only for a program that stands as it was shown" do
    defp start_at(row, epoch),
      do: %{
        "tool" => "program",
        "action" => "start",
        "args" => %{"program" => row.id, "epoch" => epoch}
      }

    test "a program that does not exist, or is another athanor's, takes no answer",
         %{ctx: ctx, turn: turn} do
      missing = %{
        "tool" => "program",
        "action" => "start",
        "args" => %{"program" => "no_such_program"}
      }

      assert {:error, {:scope_not_permitted, :no_program}} =
               Aqua.Standing.rows(ctx, turn, missing, :always)

      {:ok, other} =
        Sanctum.Test.People.linked(%{id: "grant-other", provider: "local", verified: true})

      other_athanor = Sanctum.Test.People.athanor!(other)
      theirs_ctx = %{ctx | user_id: other.id, athanor_id: other_athanor.id}
      theirs = row!(theirs_ctx, "theirs")

      assert {:error, {:scope_not_permitted, :no_program}} =
               Aqua.Standing.rows(ctx, turn, start(theirs.id), :always)

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
      {:ok, [grant]} = Aqua.Standing.rows(ctx, turn, start_at(gh, gh.epoch), :always)
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
      {:ok, [first]} = Aqua.Standing.rows(ctx, turn, start_at(jq, jq.epoch), :always)
      {:ok, _} = Sanctum.ToolGrants.put(ctx, first)
      {:ok, _} = Arca.McpServerStorage.update(actor, "jq", %{config_json: changed.("jq")})
      assert {:ok, []} = Arca.ToolGrantStorage.on_program_row(actor, jq.id)

      # Decided on the card's epoch, written after the change: refused.
      {:ok, [grant]} = Aqua.Standing.rows(ctx, turn, start_at(gh, gh.epoch), :always)
      {:ok, moved} = Arca.McpServerStorage.update(actor, "gh", %{config_json: changed.("gh")})
      assert {:error, :program_changed} = Arca.ToolGrantStorage.put(grant)

      assert {:error, {:scope_not_permitted, :program_changed}} =
               Sanctum.ToolGrants.put(ctx, grant)

      # Decided on the old epoch after the change: refused before anything.
      assert {:error, {:scope_not_permitted, :program_changed}} =
               Aqua.Standing.rows(ctx, turn, start_at(gh, gh.epoch), :always)

      # On the epoch it holds now, it stands.
      assert {:ok, [now]} = Aqua.Standing.rows(ctx, turn, start_at(gh, moved.epoch), :always)
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

  test "the soul's policy asks for a start and a send, and never makes a start automatic" do
    refute Aqua.Kinds.auto_permitted?("program", "start")
    assert Aqua.Kinds.auto_permitted?("program", "list")
    assert Aqua.Kinds.standing_for("program", "send") == :thread
  end
end
