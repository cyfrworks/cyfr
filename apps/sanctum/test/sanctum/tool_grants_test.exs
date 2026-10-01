# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.ToolGrantsTest do
  # Standing tool grants are consent state: the tenant and the deciding
  # person come from the context, an outage is never "no grants", and a
  # row built for another transaction is the same row a write stores.
  # Which answers may stand, and whether a bounded allow covers one call,
  # are decided here from the action's declaration and the rows as they
  # stand.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Sanctum.ToolGrants

  # The operation catalog as the standing rule reads it. This suite runs
  # without the host, so it installs its own port for the length of each
  # test and puts back whatever was installed before.
  defmodule StubGrimoire do
    @moduledoc false
    @behaviour Sanctum.Grimoire

    @declarations %{
      "component.pull" => %{kind: :read, standing: nil, resource: nil},
      "component.list" => %{kind: :read, standing: nil, resource: nil},
      "notes.forget" => %{kind: :destructive, standing: nil, resource: nil},
      "notes.pin" => %{kind: :write, standing: false, resource: nil},
      "notes.keep" => %{kind: :write, standing: :thread, resource: nil},
      "files.write" => %{kind: :write, standing: nil, resource: {"path", :storage_path}},
      "web.fetch" => %{kind: :read, standing: nil, resource: {"domain", :egress_domain}},
      "srv:thing.do" => %{kind: :external, standing: nil, resource: nil}
    }

    @impl true
    def action_declaration(name) do
      case Map.fetch(@declarations, name) do
        {:ok, declaration} -> {:ok, declaration}
        :error -> {:error, :not_found}
      end
    end

    @impl true
    def tool_actions, do: Map.keys(@declarations)

    @impl true
    def providers_loaded, do: :ok

    @impl true
    def tool_server_candidates(_ctx), do: []

    @impl true
    def tool_server_candidate(_ctx, _name), do: {:error, :not_found}
  end

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    installed =
      try do
        Sanctum.Grimoire.impl!()
      rescue
        Sanctum.Grimoire.NotInstalledError -> nil
      end

    Sanctum.Grimoire.install!(StubGrimoire)

    on_exit(fn ->
      if installed,
        do: Sanctum.Grimoire.install!(installed),
        else: Sanctum.Grimoire.reset()
    end)

    {ctx, other} = Sanctum.TestContext.two_contexts()
    {:ok, ctx: ctx, other: other}
  end

  defp decision(overrides \\ %{}) do
    Map.merge(
      %{
        scope: "thread",
        effect: "allow",
        thread_id: "thread_1",
        agent_name: "aqua",
        tool: "component",
        action: "pull"
      },
      overrides
    )
  end

  defp no_tenant(ctx), do: %{ctx | athanor_id: nil}

  defp soon, do: DateTime.add(DateTime.utc_now(), 3600, :second)
  defp notes, do: %{kind: "storage_path", patterns: ["data/notes/"]}

  test "the vocabulary is the stored one" do
    assert ToolGrants.scopes() == ["thread", "agent"]
    assert ToolGrants.effects() == ["allow", "deny"]
  end

  describe "put/2 and for_thread/2" do
    test "a decision lands in the caller's tenant, by the caller", %{ctx: ctx} do
      assert {:ok, grant} = ToolGrants.put(ctx, decision())
      assert grant.athanor_id == ctx.athanor_id
      assert grant.granted_by == ctx.user_id

      assert {:ok, [%{tool: "component", action: "pull", effect: "allow"}]} =
               ToolGrants.for_thread(ctx, "thread_1")
    end

    test "a caller cannot name the tenant, the person or the row", %{ctx: ctx, other: other} do
      smuggled =
        decision(%{athanor_id: other.athanor_id, granted_by: "someone-else", id: "grant_forged"})

      assert {:ok, grant} = ToolGrants.put(ctx, smuggled)
      assert grant.athanor_id == ctx.athanor_id
      assert grant.granted_by == ctx.user_id
      refute grant.id == "grant_forged"

      assert {:ok, []} = ToolGrants.for_thread(other, "thread_1")
    end

    test "an agent-scope decision names no thread and reaches every thread", %{ctx: ctx} do
      assert {:ok, grant} = ToolGrants.put(ctx, decision(%{scope: "agent"}))
      assert is_nil(grant.thread_id)

      assert {:ok, [%{scope: "agent"}]} = ToolGrants.for_thread(ctx, "thread_2")
    end

    test "attributes that do not make a grant are refused with their fields", %{ctx: ctx} do
      assert {:error, {:invalid, errors}} =
               ToolGrants.put(ctx, decision(%{scope: "forever", effect: "maybe", tool: ""}))

      assert Map.keys(errors) |> Enum.sort() == [:effect, :scope, :tool]

      assert {:error, {:invalid, %{thread_id: _}}} =
               ToolGrants.put(ctx, Map.delete(decision(), :thread_id))
    end

    test "an answer that may not stand is refused with its reason and writes nothing",
         %{ctx: ctx} do
      assert {:error, {:scope_not_permitted, :destructive}} =
               ToolGrants.put(ctx, decision(%{tool: "notes", action: "forget"}))

      assert {:error, {:scope_not_permitted, :bounded_deny}} =
               ToolGrants.put(ctx, decision(%{effect: "deny", expires_at: soon()}))

      assert {:ok, []} = ToolGrants.for_thread(ctx, "thread_1")
    end

    test "a bounded allow is stored with its bounds", %{ctx: ctx} do
      until = soon()

      assert {:ok, _} =
               ToolGrants.put(
                 ctx,
                 decision(%{
                   tool: "files",
                   action: "write",
                   expires_at: until,
                   constraint: notes()
                 })
               )

      assert {:ok, [grant]} = ToolGrants.for_thread(ctx, "thread_1")
      assert grant.constraint == notes()
      assert DateTime.compare(grant.expires_at, until) == :eq
      assert is_nil(grant.lifecycle_kind)
    end

    @tag :capture_log
    test "a store that cannot answer is unavailable, never an empty list", %{ctx: ctx} do
      {:ok, _} = ToolGrants.put(ctx, decision())
      Arca.Repo.query!("ALTER TABLE tool_grants RENAME TO tool_grants_unavailable")

      assert {:error, :unavailable} = ToolGrants.for_thread(ctx, "thread_1")
      assert {:error, :unavailable} = ToolGrants.put(ctx, decision(%{action: "list"}))
      assert {:error, :unavailable} = ToolGrants.revoke(ctx, decision())

      refute ToolGrants.admits?(ctx, %{
               agent_name: "aqua",
               thread_id: "thread_1",
               tool: "component",
               action: "pull",
               args: %{}
             })
    end

    test "a context with no tenant is refused before any read or write", %{ctx: ctx} do
      assert {:error, :no_athanor} = ToolGrants.for_thread(no_tenant(ctx), "thread_1")
      assert {:error, :no_athanor} = ToolGrants.put(no_tenant(ctx), decision())
      assert {:error, :no_athanor} = ToolGrants.revoke(no_tenant(ctx), decision())
    end
  end

  describe "revoke/2" do
    test "withdraws by key, in the caller's tenant only, idempotently",
         %{ctx: ctx, other: other} do
      # A thread id is global, so the same agent-scope key is what two
      # tenants can both hold.
      agent_key = decision(%{scope: "agent"})
      {:ok, _} = ToolGrants.put(ctx, agent_key)
      {:ok, _} = ToolGrants.put(other, agent_key)

      assert :ok = ToolGrants.revoke(ctx, Map.delete(agent_key, :effect))
      assert {:ok, []} = ToolGrants.for_thread(ctx, "thread_1")
      assert {:ok, [_theirs]} = ToolGrants.for_thread(other, "thread_1")

      assert :ok = ToolGrants.revoke(ctx, agent_key)
    end
  end

  describe "grant_row/2" do
    test "builds the row a write would store, without storing it", %{ctx: ctx} do
      assert {:ok, row} = ToolGrants.grant_row(ctx, decision(%{athanor_id: "ath_forged"}))

      assert row == %{
               athanor_id: ctx.athanor_id,
               granted_by: ctx.user_id,
               scope: "thread",
               effect: "allow",
               thread_id: "thread_1",
               agent_name: "aqua",
               tool: "component",
               action: "pull"
             }

      assert {:ok, []} = ToolGrants.for_thread(ctx, "thread_1")

      # The turn store writes exactly this row inside its own transaction.
      assert {:ok, _} = Arca.ToolGrantStorage.put(row)
      assert {:ok, [_stored]} = ToolGrants.for_thread(ctx, "thread_1")
    end

    test "carries the bounds the person chose, and nothing it did not", %{ctx: ctx} do
      until = soon()

      assert {:ok, row} =
               ToolGrants.grant_row(
                 ctx,
                 decision(%{
                   tool: "files",
                   action: "write",
                   lifecycle_kind: "turn",
                   lifecycle_id: "turn_1",
                   expires_at: until,
                   constraint: nil
                 })
               )

      assert %{lifecycle_kind: "turn", lifecycle_id: "turn_1", expires_at: ^until} = row
      refute Map.has_key?(row, :constraint)
    end

    test "refuses a context with no tenant, attributes that make no grant, and an answer that may not stand",
         %{ctx: ctx} do
      assert {:error, :forbidden} = ToolGrants.grant_row(no_tenant(ctx), decision())
      assert {:error, :invalid_argument} = ToolGrants.grant_row(ctx, decision(%{effect: nil}))
      assert {:error, :invalid_argument} = ToolGrants.grant_row(ctx, decision(%{scope: "all"}))

      assert {:error, {:scope_not_permitted, :no_resource}} =
               ToolGrants.grant_row(ctx, decision(%{constraint: notes()}))
    end
  end

  describe "check_standing/2" do
    setup do
      {:ok, now: DateTime.utc_now()}
    end

    test "a deny stands, and one carrying any bound is refused, so a deny never lapses",
         %{now: now} do
      deny = decision(%{effect: "deny", tool: "notes", action: "forget"})
      assert :ok = ToolGrants.check_standing(deny, now)

      for bound <- [
            %{lifecycle_kind: "execution", lifecycle_id: "exec_1"},
            %{lifecycle_kind: "turn"},
            %{expires_at: soon()},
            %{constraint: notes()}
          ] do
        assert {:error, {:scope_not_permitted, :bounded_deny}} =
                 ToolGrants.check_standing(Map.merge(deny, bound), now),
               "a deny took #{inspect(bound)}"
      end
    end

    test "the action's kind and standing declaration decide which allows may stand",
         %{now: now} do
      assert :ok = ToolGrants.check_standing(decision(), now)

      assert {:error, {:scope_not_permitted, :destructive}} =
               ToolGrants.check_standing(decision(%{tool: "notes", action: "forget"}), now)

      assert {:error, {:scope_not_permitted, :external}} =
               ToolGrants.check_standing(decision(%{tool: "srv:thing", action: "do"}), now)

      assert {:error, {:scope_not_permitted, :unknown_kind}} =
               ToolGrants.check_standing(decision(%{tool: "nothing", action: "here"}), now)

      assert {:error, {:scope_not_permitted, :never_standing}} =
               ToolGrants.check_standing(decision(%{tool: "notes", action: "pin"}), now)

      assert :ok = ToolGrants.check_standing(decision(%{tool: "notes", action: "keep"}), now)

      assert {:error, {:scope_not_permitted, :thread_only}} =
               ToolGrants.check_standing(
                 decision(%{scope: "agent", tool: "notes", action: "keep"}),
                 now
               )

      assert {:error, {:scope_not_permitted, :unknown_kind}} =
               ToolGrants.check_standing(decision(%{scope: "forever"}), now)
    end

    test "a lifecycle names its kind and its row together", %{now: now} do
      for kind <- ["execution", "turn", "schedule"] do
        assert :ok =
                 ToolGrants.check_standing(
                   decision(%{lifecycle_kind: kind, lifecycle_id: "row_1"}),
                   now
                 )
      end

      for bad <- [
            %{lifecycle_kind: "turn"},
            %{lifecycle_id: "row_1"},
            %{lifecycle_kind: "forever", lifecycle_id: "row_1"},
            %{lifecycle_kind: "turn", lifecycle_id: ""}
          ] do
        assert {:error, {:scope_not_permitted, :invalid_lifecycle}} =
                 ToolGrants.check_standing(decision(bad), now),
               "#{inspect(bad)} stood"
      end
    end

    test "a deadline is a time still to come", %{now: now} do
      assert :ok = ToolGrants.check_standing(decision(%{expires_at: soon()}), now)

      assert {:error, {:scope_not_permitted, :deadline_passed}} =
               ToolGrants.check_standing(decision(%{expires_at: now}), now)

      assert {:error, {:scope_not_permitted, :invalid_deadline}} =
               ToolGrants.check_standing(decision(%{expires_at: "tomorrow"}), now)
    end

    test "a constraint only for an action that declares its resource, of that kind and grammar",
         %{now: now} do
      write = decision(%{tool: "files", action: "write"})

      assert :ok = ToolGrants.check_standing(Map.put(write, :constraint, notes()), now)

      assert :ok =
               ToolGrants.check_standing(
                 Map.put(write, :constraint, %{
                   "kind" => "storage_path",
                   "patterns" => ["data/a.md"]
                 }),
                 now
               )

      assert {:error, {:scope_not_permitted, :no_resource}} =
               ToolGrants.check_standing(decision(%{constraint: notes()}), now)

      assert {:error, {:scope_not_permitted, :resource_kind}} =
               ToolGrants.check_standing(
                 Map.put(write, :constraint, %{kind: "egress_domain", patterns: ["example.com"]}),
                 now
               )

      for bad <- [
            %{kind: "storage_path", patterns: []},
            %{kind: "storage_path", patterns: ["../escape"]},
            %{kind: "storage_path", patterns: ["/data/"]},
            %{kind: "storage_path", patterns: [""]},
            %{kind: "storage_path", patterns: "data/"},
            # The store's own grammar: no pattern twice, at most 64, and
            # no wildcard — a pattern names one path or one folder.
            %{kind: "storage_path", patterns: ["data/a/", "data/a/"]},
            %{kind: "storage_path", patterns: Enum.map(1..65, &"data/#{&1}.md")},
            %{kind: "storage_path", patterns: ["*"]},
            %{kind: "storage_path", patterns: ["data/*"]},
            %{kind: "storage_path", patterns: ["data/notes/", "data/*.md"]},
            %{patterns: ["data/"]},
            :corrupt
          ] do
        assert {:error, {:scope_not_permitted, :invalid_constraint}} =
                 ToolGrants.check_standing(Map.put(write, :constraint, bad), now),
               "#{inspect(bad)} stood"
      end

      assert :ok =
               ToolGrants.check_standing(
                 Map.put(write, :constraint, %{
                   kind: "storage_path",
                   patterns: Enum.map(1..64, &"data/#{&1}.md")
                 }),
                 now
               )

      fetch = decision(%{tool: "web", action: "fetch"})

      assert :ok =
               ToolGrants.check_standing(
                 Map.put(fetch, :constraint, %{kind: :egress_domain, patterns: ["*.example.com"]}),
                 now
               )

      assert {:error, {:scope_not_permitted, :invalid_constraint}} =
               ToolGrants.check_standing(
                 Map.put(fetch, :constraint, %{kind: "egress_domain", patterns: ["*"]}),
                 now
               )
    end

    test "the rule's grammar is the store's: what one refuses the other refuses", %{
      ctx: ctx,
      now: now
    } do
      write = decision(%{tool: "files", action: "write"})

      for patterns <- [
            ["data/a/", "data/a/"],
            Enum.map(1..65, &"data/#{&1}.md"),
            ["*"],
            ["data/notes/*"]
          ] do
        assert [_ | _] = Arca.ToolGrantStorage.constraint_errors("storage_path", patterns)

        assert {:error, {:scope_not_permitted, :invalid_constraint}} =
                 ToolGrants.check_standing(
                   Map.put(write, :constraint, %{kind: "storage_path", patterns: patterns}),
                   now
                 )

        # Written past the rule, the store refuses the same constraint.
        {:ok, row} = ToolGrants.grant_row(ctx, write)

        assert {:error, {:invalid, %{constraint: _}}} =
                 Arca.ToolGrantStorage.put(
                   Map.put(row, :constraint, %{kind: "storage_path", patterns: patterns})
                 )
      end

      assert [] = Arca.ToolGrantStorage.constraint_errors("storage_path", ["data/notes/"])
      assert {:ok, []} = ToolGrants.for_thread(ctx, "thread_1")
    end
  end

  describe "admits?/2" do
    setup %{ctx: ctx} do
      actor = Sanctum.Context.actor(ctx) |> Map.put(:user_id, ctx.user_id)
      {:ok, thread} = Arca.ThreadStorage.create(actor)

      {:ok, %{turn: turn}} =
        Arca.TurnStorage.accept_message(actor, thread.id, %{
          message: %{author: ctx.user_id, content: "go"},
          turn: %{agent: "aqua", requested_by: ctx.user_id, origin: :interactive}
        })

      {:ok, thread: thread.id, turn: turn.id, a: running!(ctx), b: running!(ctx)}
    end

    defp running!(ctx) do
      id = "exec_tga_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Arca.Execution.admit(
          %{
            id: id,
            reference: "catalyst:local.test:1.0.0",
            user_id: ctx.user_id,
            athanor_id: ctx.athanor_id,
            component_type: "catalyst",
            origin: :interactive
          },
          grant: Arca.Test.Actor.grant(ctx.athanor_id),
          verify: &Arca.Test.Actor.admits/1
        )

      id
    end

    defp allow!(ctx, thread, bounds, pair \\ %{tool: "files", action: "write"}) do
      {:ok, _} =
        ToolGrants.put(ctx, Map.merge(decision(%{thread_id: thread}), Map.merge(pair, bounds)))
    end

    defp call(thread, overrides) do
      Map.merge(
        %{
          agent_name: "aqua",
          thread_id: thread,
          tool: "files",
          action: "write",
          args: %{"path" => "data/notes/a.md", "content" => "x"}
        },
        overrides
      )
    end

    test "a call inside the constraint is covered; another path, an unsafe one or none asks",
         %{ctx: ctx, thread: thread, a: a} do
      allow!(ctx, thread, %{
        lifecycle_kind: "execution",
        lifecycle_id: a,
        constraint: notes()
      })

      assert ToolGrants.admits?(ctx, call(thread, %{execution_id: a}))

      for path <- ["data/notes/deep/b.md", "data/notes"] do
        assert ToolGrants.admits?(ctx, call(thread, %{execution_id: a, args: %{"path" => path}})),
               "#{path} was not covered"
      end

      # Read as the storage door reads a path: an absolute one is refused,
      # and a spelling the door would not match under the pattern asks.
      for path <- [
            "/data/notes/c.md",
            "/data//notes/c.md",
            "data//notes/c.md",
            "data/other/b.md",
            "data/notesx/b.md",
            "data/notes/../secrets.md",
            "data/notes/%2e%2e/secrets.md",
            "data",
            ".",
            ""
          ] do
        refute ToolGrants.admits?(ctx, call(thread, %{execution_id: a, args: %{"path" => path}})),
               "#{path} was covered"
      end

      refute ToolGrants.admits?(ctx, call(thread, %{execution_id: a, args: %{}}))
    end

    test "an allow for execution A covers A's calls and not B's while A runs, and nothing once A ends",
         %{ctx: ctx, thread: thread, a: a, b: b} do
      allow!(ctx, thread, %{lifecycle_kind: "execution", lifecycle_id: a})

      assert ToolGrants.admits?(ctx, call(thread, %{execution_id: a}))
      refute ToolGrants.admits?(ctx, call(thread, %{execution_id: b}))
      refute ToolGrants.admits?(ctx, call(thread, %{}))

      {1, _} =
        Arca.Repo.update_all(
          from(e in Arca.Schemas.Execution, where: e.id == ^a),
          set: [status: "completed", completed_at: DateTime.utc_now(), duration_ms: 1]
        )

      refute ToolGrants.admits?(ctx, call(thread, %{execution_id: a}))
    end

    test "an allow for a turn covers that turn's calls alone", %{
      ctx: ctx,
      thread: thread,
      turn: turn
    } do
      allow!(ctx, thread, %{lifecycle_kind: "turn", lifecycle_id: turn})

      assert ToolGrants.admits?(ctx, call(thread, %{turn_id: turn}))
      refute ToolGrants.admits?(ctx, call(thread, %{turn_id: "turn_other"}))
    end

    test "an allow for a schedule covers only a call whose execution that schedule started",
         %{ctx: ctx, thread: thread, a: a} do
      allow!(ctx, thread, %{lifecycle_kind: "schedule", lifecycle_id: "sched_1"})

      refute ToolGrants.admits?(ctx, call(thread, %{execution_id: a}))
    end

    test "a call after the deadline asks", %{ctx: ctx, thread: thread, a: a} do
      allow!(ctx, thread, %{
        lifecycle_kind: "execution",
        lifecycle_id: a,
        expires_at: soon()
      })

      assert ToolGrants.admits?(ctx, call(thread, %{execution_id: a}))

      {1, _} =
        Arca.Repo.update_all(
          from(g in Arca.Schemas.ToolGrant, where: g.thread_id == ^thread),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      refute ToolGrants.admits?(ctx, call(thread, %{execution_id: a}))
    end

    test "a deny for the pair covers every call, and an unbounded allow is not this answer's",
         %{ctx: ctx, thread: thread, a: a} do
      allow!(ctx, thread, %{lifecycle_kind: "execution", lifecycle_id: a})

      {:ok, _} =
        ToolGrants.put(
          ctx,
          decision(%{scope: "agent", effect: "deny", tool: "files", action: "write"})
        )

      refute ToolGrants.admits?(ctx, call(thread, %{execution_id: a}))

      allow!(ctx, thread, %{}, %{tool: "component", action: "list"})

      refute ToolGrants.admits?(
               ctx,
               call(thread, %{tool: "component", action: "list", execution_id: a})
             )
    end

    test "another agent's, another thread's and another athanor's allows cover nothing",
         %{ctx: ctx, other: other, thread: thread, a: a} do
      allow!(ctx, thread, %{lifecycle_kind: "execution", lifecycle_id: a})

      refute ToolGrants.admits?(ctx, call(thread, %{agent_name: "planner", execution_id: a}))
      refute ToolGrants.admits?(ctx, call("thread_other", %{execution_id: a}))
      refute ToolGrants.admits?(other, call(thread, %{execution_id: a}))
    end

    test "an allow the action's current declaration refuses covers nothing",
         %{ctx: ctx, thread: thread, a: a} do
      # Written past the rule, as a row from before a declaration changed.
      {:ok, _} =
        Arca.ToolGrantStorage.put(%{
          athanor_id: ctx.athanor_id,
          scope: "thread",
          effect: "allow",
          thread_id: thread,
          agent_name: "aqua",
          tool: "notes",
          action: "pin",
          granted_by: ctx.user_id,
          lifecycle_kind: "execution",
          lifecycle_id: a
        })

      refute ToolGrants.admits?(
               ctx,
               call(thread, %{tool: "notes", action: "pin", execution_id: a})
             )
    end

    test "a domain constraint matches the call's host as egress does", %{
      ctx: ctx,
      thread: thread,
      a: a
    } do
      allow!(
        ctx,
        thread,
        %{
          lifecycle_kind: "execution",
          lifecycle_id: a,
          constraint: %{kind: "egress_domain", patterns: ["*.example.com"]}
        },
        %{tool: "web", action: "fetch"}
      )

      fetch = fn domain ->
        call(thread, %{
          tool: "web",
          action: "fetch",
          execution_id: a,
          args: %{"domain" => domain}
        })
      end

      assert ToolGrants.admits?(ctx, fetch.("api.example.com"))
      refute ToolGrants.admits?(ctx, fetch.("example.com"))
      refute ToolGrants.admits?(ctx, fetch.("api.example.org"))
      refute ToolGrants.admits?(ctx, fetch.("*.example.com"))
    end
  end
end
