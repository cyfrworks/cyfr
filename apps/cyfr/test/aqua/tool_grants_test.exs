# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ToolGrantsTest do
  # Standing approvals as rows: declared policy composed with what a person
  # actually answered, and the rule that keeps an answer from reaching
  # further than the estate it was given in.
  use ExUnit.Case, async: false

  alias Aqua.ToolGrants

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp grant(ctx, overrides) do
    attrs =
      Map.merge(
        %{
          scope: "conversation",
          effect: "allow",
          conversation_id: "conv_1",
          agent_name: "aqua",
          tool: "component",
          action: "pull"
        },
        overrides
      )

    ToolGrants.put(ctx, attrs)
  end

  describe "refusal_message/1" do
    test "every reason the union carries reads as a sentence, never as an atom" do
      reasons = [
        :destructive,
        :external,
        "destructive",
        "external",
        :never_standing,
        :conversation_only,
        :unknown_kind,
        :something_new
      ]

      for reason <- reasons do
        sentence = ToolGrants.refusal_message({:scope_not_permitted, reason})
        assert is_binary(sentence) and String.ends_with?(sentence, ".")
        refute sentence =~ ~r/never_standing|conversation_only|unknown_kind|foreign_agent/
      end

      # The runner spells the kind as the intent stores it (a string), the
      # write path as an atom; the person reads the same words.
      assert ToolGrants.refusal_message({:scope_not_permitted, :destructive}) ==
               ToolGrants.refusal_message({:scope_not_permitted, "destructive"})

      assert ToolGrants.refusal_message({:scope_not_permitted, :destructive}) =~
               "A destructive action always asks"

      assert ToolGrants.refusal_message({:scope_not_permitted, :never_standing}) =~
               "one click at a time"

      assert ToolGrants.refusal_message({:scope_not_permitted, :conversation_only}) =~
               "this conversation only"
    end
  end

  describe "resolve/2" do
    test "an allow makes a declared 'ask' automatic" do
      declared = %{"component.pull" => "ask"}
      grants = [%{effect: "allow", tool: "component", action: "pull"}]

      assert ToolGrants.resolve(declared, grants) == %{"component.pull" => "auto"}
    end

    test "a deny beats a declared 'auto' and pins the pair as denied" do
      declared = %{"component.pull" => "auto", "files.read" => "auto"}
      grants = [%{effect: "deny", tool: "component", action: "pull"}]

      # Kept as an exact "deny", not dropped: every policy reader falls back
      # to a `tool.*` glob only for an ABSENT key, so a dropped pair would
      # let a surviving glob answer for it. A present "deny" is uncallable
      # and not proposable, so a person who said "never" is not asked again.
      assert ToolGrants.resolve(declared, grants) ==
               %{"component.pull" => "deny", "files.read" => "auto"}
    end

    test "a deny wins over an allow for the same pair" do
      declared = %{}

      grants = [
        %{effect: "allow", tool: "component", action: "pull"},
        %{effect: "deny", tool: "component", action: "pull"}
      ]

      assert ToolGrants.resolve(declared, grants) == %{"component.pull" => "deny"}
    end

    test "a deny is not defeated, or inverted, by a glob" do
      # The two shapes that used to fail: a deny against a globbed `ask`
      # was re-offered every turn, and a deny against an exact `ask` under
      # a globbed `auto` made the pair directly callable.
      deny = [%{effect: "deny", tool: "component", action: "pull"}]

      composed = ToolGrants.resolve(%{"component.*" => "ask"}, deny)
      assert composed["component.pull"] == "deny"
      refute Map.has_key?(composed, "component.*")
      assert composed["component.search"] == "ask"

      inverted = ToolGrants.resolve(%{"component.pull" => "ask", "component.*" => "auto"}, deny)
      assert inverted["component.pull"] == "deny"
      assert inverted["component.search"] == "auto"
    end

    test "a role's delegation glob and the search gate pass through composition untouched" do
      composed = ToolGrants.resolve(%{"aqua_builder.*" => "auto", "native_search" => "auto"}, [])
      assert composed == %{"aqua_builder.*" => "auto", "native_search" => "auto"}
    end

    test "the kind ceiling demotes an automatic destructive action, wherever it came from" do
      # A hand-edited file, or a row written before the rule: neither
      # reaches the guest as auto.
      assert ToolGrants.resolve(%{"files.delete" => "auto", "files.read" => "auto"}, []) ==
               %{"files.delete" => "ask", "files.read" => "auto"}

      assert ToolGrants.resolve(%{"http.*" => "auto"}, [])["http.delete"] == "ask"
    end

    test "allowed_keys/1 is grant-derived and a deny subtracts" do
      rows = [
        %{effect: "allow", scope: "conversation", tool: "component", action: "pull"},
        %{effect: "deny", scope: "agent", tool: "component", action: "pull"},
        %{effect: "allow", scope: "conversation", tool: "component", action: "list"}
      ]

      assert ToolGrants.allowed_keys(rows) == MapSet.new([{"component", "list"}])
    end

    test "no grants leaves the declared policy exactly as written" do
      declared = %{"component.pull" => "ask", "files.read" => "auto"}
      assert ToolGrants.resolve(declared, []) == declared
    end
  end

  describe "scope" do
    test "an agent-scope row carries no conversation, and is keyed by the estate", %{ctx: ctx} do
      assert {:ok, row} = grant(ctx, %{scope: "agent"})
      assert is_nil(row.conversation_id)
      assert row.athanor_id == ctx.athanor_id
    end

    test "a standing allow for a destructive or external action is refused at the write", %{
      ctx: ctx
    } do
      # `notes.forget` is `kind: :destructive` in the live registry — the
      # same source the approval card derives its risk from.
      assert {:error, {:scope_not_permitted, :destructive}} =
               grant(ctx, %{tool: "notes", action: "forget"})

      # An external server's tool is external by its namespace.
      assert {:error, {:scope_not_permitted, :external}} =
               grant(ctx, %{tool: "srv:thing", action: "do"})

      # A standing DENY stands for both — "never do this" is exactly the
      # standing answer a destructive action should be able to take.
      assert {:ok, _} = grant(ctx, %{tool: "notes", action: "forget", effect: "deny"})
      assert {:ok, _} = grant(ctx, %{tool: "srv:thing", action: "do", effect: "deny"})
    end

    test "an action that never stands takes no standing allow at any scope, and a deny stands",
         %{ctx: ctx} do
      # `notes.pin` is `kind: :write` — the kind alone would admit it. Its
      # `standing: false` declaration is what refuses it here.
      assert {:error, {:scope_not_permitted, :never_standing}} =
               grant(ctx, %{tool: "notes", action: "pin"})

      assert {:error, {:scope_not_permitted, :never_standing}} =
               grant(ctx, %{scope: "agent", tool: "notes", action: "pin"})

      assert {:ok, _} = grant(ctx, %{tool: "notes", action: "pin", effect: "deny"})

      # A scroll is read into every turn's prompt index, so the two scroll
      # writes a chain may propose are `standing: false` the same way —
      # each one a click, at neither scope; a deny still stands.
      for action <- ~w(skill_create skill_update) do
        assert {:error, {:scope_not_permitted, :never_standing}} =
                 grant(ctx, %{tool: "aqua", action: action}),
               "aqua.#{action} took a conversation-scope standing allow"

        assert {:error, {:scope_not_permitted, :never_standing}} =
                 grant(ctx, %{scope: "agent", tool: "aqua", action: action}),
               "aqua.#{action} took an agent-scope standing allow"

        assert {:ok, _} = grant(ctx, %{tool: "aqua", action: action, effect: "deny"})
      end
    end

    test "an allow the action's current declaration would refuse stops counting at the read",
         %{ctx: ctx} do
      # A row written before `notes.pin` declared `standing: false` (or by
      # a surface that never went through `put/2`). It must not auto-run
      # anything — neither on the runner's fast path (`allowed_keys/1`)
      # nor by becoming `auto` in the policy the formula is handed
      # (`resolve/2`). A deny still counts.
      stale =
        %{
          athanor_id: ctx.athanor_id,
          scope: "conversation",
          effect: "allow",
          conversation_id: "conv_1",
          agent_name: "aqua",
          tool: "notes",
          action: "pin",
          granted_by: ctx.user_id
        }

      assert {:ok, _} = Arca.ToolGrantStorage.put(stale)
      assert {:ok, _} = Arca.ToolGrantStorage.put(%{stale | action: "forget", effect: "deny"})

      rows = rows(ctx, "conv_1", ctx.athanor_id, "aqua")
      assert length(rows) == 2

      assert ToolGrants.allowed_keys(rows) == MapSet.new()

      assert ToolGrants.resolve(%{"notes.pin" => "ask", "notes.forget" => "auto"}, rows) ==
               %{"notes.pin" => "ask", "notes.forget" => "deny"}
    end

    test "a conversation-only action takes a conversation allow and refuses the agent scope",
         %{ctx: ctx} do
      # `notes.keep` declares `standing: :conversation`: a filed note
      # follows the thread it was kept from, never the agent — so an
      # agent-scope allow is refused outright rather than narrowed.
      assert {:ok, _} = grant(ctx, %{tool: "notes", action: "keep"})

      assert {:error, {:scope_not_permitted, :conversation_only}} =
               grant(ctx, %{scope: "agent", tool: "notes", action: "keep"})
    end

    test "an allow whose kind nothing can answer is refused; a deny stands", %{
      ctx: ctx
    } do
      # "Not known" and "not up yet" read the same at this seam — and only
      # the second could otherwise write a standing allow for something
      # destructive.
      assert {:error, {:scope_not_permitted, :unknown_kind}} =
               grant(ctx, %{tool: "no_such_tool", action: "go"})

      assert {:ok, _} = grant(ctx, %{tool: "no_such_tool", action: "go", effect: "deny"})
    end

    test "virtual tools are classified by the catalog, not the registry", %{ctx: ctx} do
      # `files` lives in the formula, not `Emissary.MCP.ToolRegistry` — a
      # standing allow for its write verb must not read as unknown, and
      # its destructive verb is refused like any other.
      assert {:ok, _} = grant(ctx, %{tool: "files", action: "write"})

      assert {:error, {:scope_not_permitted, :destructive}} =
               grant(ctx, %{tool: "files", action: "delete"})
    end
  end

  describe "put/2 replaces rather than accumulates" do
    test "flipping allow to deny leaves one row, not a contradictory pair", %{ctx: ctx} do
      {:ok, _} = grant(ctx, %{scope: "agent", effect: "allow"})
      {:ok, _} = grant(ctx, %{scope: "agent", effect: "deny"})

      rows = rows(ctx, "conv_1", ctx.athanor_id, "aqua")
      assert [%{effect: "deny"}] = rows
    end

    test "the same pair in two conversations is two rows", %{ctx: ctx} do
      {:ok, _} = grant(ctx, %{conversation_id: "conv_1"})
      {:ok, _} = grant(ctx, %{conversation_id: "conv_2"})

      assert [_] = rows(ctx, "conv_1", ctx.athanor_id, "aqua")
      assert [_] = rows(ctx, "conv_2", ctx.athanor_id, "aqua")
    end
  end

  describe "for_conversation/3" do
    test "sees this thread's grants and the agent's, but not another thread's", %{ctx: ctx} do
      {:ok, _} = grant(ctx, %{conversation_id: "conv_1", tool: "component", action: "pull"})
      {:ok, _} = grant(ctx, %{conversation_id: "conv_2", tool: "component", action: "list"})
      {:ok, _} = grant(ctx, %{scope: "agent", tool: "record", action: "list"})

      keys =
        ctx
        |> rows("conv_1", ctx.athanor_id, "aqua")
        |> ToolGrants.allowed_keys()

      assert MapSet.equal?(keys, MapSet.new([{"component", "pull"}, {"record", "list"}]))
    end

    test "another agent's grants are not this agent's", %{ctx: ctx} do
      {:ok, _} = grant(ctx, %{agent_name: "aqua_planner"})

      assert [] = rows(ctx, "conv_1", ctx.athanor_id, "aqua")
    end
  end

  describe "revoke/2" do
    test "withdraws a row and is idempotent", %{ctx: ctx} do
      {:ok, _} = grant(ctx, %{})

      key = %{
        scope: "conversation",
        conversation_id: "conv_1",
        agent_name: "aqua",
        tool: "component",
        action: "pull"
      }

      assert :ok = ToolGrants.revoke(ctx, key)
      assert [] = rows(ctx, "conv_1", ctx.athanor_id, "aqua")
      assert :ok = ToolGrants.revoke(ctx, key)
    end
  end

  # The rows a read answers — `{:ok, rows}`, since a store that cannot be
  # read is an error the caller refuses on, never an empty list.
  defp rows(ctx, conversation_id, _owner, name) do
    {:ok, rows} = ToolGrants.for_conversation(ctx, conversation_id, name)
    rows
  end
end
