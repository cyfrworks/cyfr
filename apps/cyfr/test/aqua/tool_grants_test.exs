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
          agent_athanor_id: ctx.athanor_id,
          agent_name: "aqua",
          tool: "component",
          action: "pull"
        },
        overrides
      )

    ToolGrants.put(ctx, attrs)
  end

  describe "resolve/2" do
    test "an allow makes a declared 'ask' automatic" do
      declared = %{"component.pull" => "ask"}
      grants = [%{effect: "allow", tool: "component", action: "pull"}]

      assert ToolGrants.resolve(declared, grants) == %{"component.pull" => "auto"}
    end

    test "a deny beats a declared 'auto' and leaves the surface entirely" do
      declared = %{"component.pull" => "auto", "files.read" => "auto"}
      grants = [%{effect: "deny", tool: "component", action: "pull"}]

      # Removed, not demoted to "ask": absence from the allowlist is what
      # makes an action uncallable, so a person who said "never" is not
      # asked again either.
      assert ToolGrants.resolve(declared, grants) == %{"files.read" => "auto"}
    end

    test "a deny wins over an allow for the same pair" do
      declared = %{}

      grants = [
        %{effect: "allow", tool: "component", action: "pull"},
        %{effect: "deny", tool: "component", action: "pull"}
      ]

      assert ToolGrants.resolve(declared, grants) == %{}
    end

    test "no grants leaves the declared policy exactly as written" do
      declared = %{"component.pull" => "ask", "files.read" => "auto"}
      assert ToolGrants.resolve(declared, []) == declared
    end
  end

  describe "scope" do
    test "agent scope for a borrowed agent narrows to this conversation, loudly", %{ctx: ctx} do
      # Not refused-and-dropped: the person answered, and the answer is
      # recorded where it CAN reach — this thread — with `narrowed?: true`
      # as the caller's cue to say so.
      assert {:ok, %{row: row, narrowed?: true}} =
               grant(ctx, %{scope: "agent", agent_athanor_id: "ath_someone_else"})

      assert row.scope == "conversation"
      assert row.conversation_id == "conv_1"
      assert row.athanor_id == ctx.athanor_id

      # …and the same narrowing for a deny: "never" on a borrowed agent IS
      # a conversation-scope deny. An agent-scope "never" following the
      # agent home would be the allow leak with the sign reversed.
      assert {:ok, %{row: deny, narrowed?: true}} =
               grant(ctx, %{
                 scope: "agent",
                 effect: "deny",
                 agent_athanor_id: "ath_someone_else"
               })

      assert deny.scope == "conversation"
    end

    test "agent scope with nothing to narrow into keeps the refusal", %{ctx: ctx} do
      assert {:error, {:scope_not_permitted, :foreign_agent}} =
               grant(ctx, %{
                 scope: "agent",
                 agent_athanor_id: "ath_someone_else",
                 conversation_id: nil
               })
    end

    test "conversation scope stays available for a borrowed agent", %{ctx: ctx} do
      assert {:ok, %{row: row, narrowed?: false}} =
               grant(ctx, %{scope: "conversation", agent_athanor_id: "ath_someone_else"})

      assert row.scope == "conversation"
      assert row.athanor_id == ctx.athanor_id
      assert row.agent_athanor_id == "ath_someone_else"
    end

    test "an agent-scope row carries no conversation", %{ctx: ctx} do
      assert {:ok, %{row: row}} = grant(ctx, %{scope: "agent"})
      assert is_nil(row.conversation_id)
    end

    test "an agent-scope answer follows the agent into another estate", %{ctx: ctx} do
      # Written at home (owner == focus)…
      {:ok, _} = grant(ctx, %{scope: "agent", tool: "component", action: "pull"})
      {:ok, _} = grant(ctx, %{scope: "agent", effect: "deny", tool: "files", action: "write"})

      # …and read wherever the agent works: another estate's conversation
      # unions the OWNER's agent-scope rows in.
      elsewhere = %{ctx | athanor_id: "ath_elsewhere"}
      rows = ToolGrants.for_conversation(elsewhere, "conv_far", ctx.athanor_id, "aqua")

      assert {"component", "pull"} in ToolGrants.allowed_keys(rows)

      # The deny rides along too — a "never" answered at home is not
      # re-offered abroad (and the followed allow composes in as auto).
      assert ToolGrants.resolve(%{"files.write" => "auto"}, rows) ==
               %{"component.pull" => "auto"}
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
    end

    test "a conversation-only action takes a conversation allow and refuses the agent scope",
         %{ctx: ctx} do
      # `notes.keep` declares `standing: :conversation`: a filed note
      # follows the thread it was kept from, never the agent — so an
      # agent-scope allow is refused outright rather than narrowed.
      assert {:ok, %{narrowed?: false}} = grant(ctx, %{tool: "notes", action: "keep"})

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

      rows = ToolGrants.for_conversation(ctx, "conv_1", ctx.athanor_id, "aqua")
      assert [%{effect: "deny"}] = rows
    end

    test "two agent-scope rows for the same pair collide despite the null conversation", %{
      ctx: ctx
    } do
      # The regression the two partial indexes exist for: a single unique
      # index over a nullable `conversation_id` constrains nothing, because
      # NULL never equals NULL.
      {:ok, _} = grant(ctx, %{scope: "agent", effect: "allow"})
      {:ok, _} = grant(ctx, %{scope: "agent", effect: "allow"})

      assert [_one] = ToolGrants.for_conversation(ctx, "conv_1", ctx.athanor_id, "aqua")
    end

    test "the same pair in two conversations is two rows", %{ctx: ctx} do
      {:ok, _} = grant(ctx, %{conversation_id: "conv_1"})
      {:ok, _} = grant(ctx, %{conversation_id: "conv_2"})

      assert [_] = ToolGrants.for_conversation(ctx, "conv_1", ctx.athanor_id, "aqua")
      assert [_] = ToolGrants.for_conversation(ctx, "conv_2", ctx.athanor_id, "aqua")
    end
  end

  describe "for_conversation/4" do
    test "sees this thread's grants and the agent's, but not another thread's", %{ctx: ctx} do
      {:ok, _} = grant(ctx, %{conversation_id: "conv_1", tool: "component", action: "pull"})
      {:ok, _} = grant(ctx, %{conversation_id: "conv_2", tool: "component", action: "list"})
      {:ok, _} = grant(ctx, %{scope: "agent", tool: "record", action: "list"})

      keys =
        ctx
        |> ToolGrants.for_conversation("conv_1", ctx.athanor_id, "aqua")
        |> ToolGrants.allowed_keys()

      assert MapSet.equal?(keys, MapSet.new([{"component", "pull"}, {"record", "list"}]))
    end

    test "another agent's grants are not this agent's", %{ctx: ctx} do
      {:ok, _} = grant(ctx, %{agent_name: "aqua_planner"})

      assert [] = ToolGrants.for_conversation(ctx, "conv_1", ctx.athanor_id, "aqua")
    end
  end

  describe "revoke/2" do
    test "withdraws a row and is idempotent", %{ctx: ctx} do
      {:ok, _} = grant(ctx, %{})

      key = %{
        scope: "conversation",
        conversation_id: "conv_1",
        agent_athanor_id: ctx.athanor_id,
        agent_name: "aqua",
        tool: "component",
        action: "pull"
      }

      assert :ok = ToolGrants.revoke(ctx, key)
      assert [] = ToolGrants.for_conversation(ctx, "conv_1", ctx.athanor_id, "aqua")
      assert :ok = ToolGrants.revoke(ctx, key)
    end
  end
end
