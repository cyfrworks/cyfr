# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ToolGrantsTest do
  # Standing approvals as rows: declared policy composed with what a person
  # actually answered, and the rule that keeps an answer from reaching
  # further than the athanor it was given in.
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
          scope: "thread",
          effect: "allow",
          thread_id: "thread_1",
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
        :thread_only,
        :unknown_kind,
        :bounded_deny,
        :bounds_without_standing,
        :invalid_lifecycle,
        :no_schedule,
        :invalid_deadline,
        :deadline_passed,
        :no_resource,
        :resource_kind,
        :invalid_constraint,
        :something_new
      ]

      for reason <- reasons do
        sentence = ToolGrants.refusal_message({:scope_not_permitted, reason})
        assert String.ends_with?(sentence, ".")

        refute sentence =~
                 ~r/never_standing|thread_only|unknown_kind|foreign_agent|bounded_deny|bounds_without|invalid_|no_schedule|deadline_passed|no_resource|resource_kind/
      end

      # Every reason the rule and the decision name has its own sentence.
      generic = ToolGrants.refusal_message({:scope_not_permitted, :something_new})

      for reason <- reasons -- [:something_new] do
        refute ToolGrants.refusal_message({:scope_not_permitted, reason}) == generic,
               "#{inspect(reason)} reads as the generic refusal"
      end

      # The runner spells the kind as the intent stores it (a string), the
      # write path as an atom; the person reads the same words.
      assert ToolGrants.refusal_message({:scope_not_permitted, :destructive}) ==
               ToolGrants.refusal_message({:scope_not_permitted, "destructive"})

      assert ToolGrants.refusal_message({:scope_not_permitted, :destructive}) =~
               "A destructive action always asks"

      assert ToolGrants.refusal_message({:scope_not_permitted, :never_standing}) =~
               "one click at a time"

      assert ToolGrants.refusal_message({:scope_not_permitted, :thread_only}) =~
               "this thread only"
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
      # Standing denies must override both exact and globbed ask/auto policies.
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
      composed = ToolGrants.resolve(%{"builder.*" => "auto", "native_search" => "auto"}, [])
      assert composed == %{"builder.*" => "auto", "native_search" => "auto"}
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
        %{effect: "allow", scope: "thread", tool: "component", action: "pull"},
        %{effect: "deny", scope: "agent", tool: "component", action: "pull"},
        %{effect: "allow", scope: "thread", tool: "component", action: "list"}
      ]

      assert ToolGrants.allowed_keys(rows) == MapSet.new([{"component", "list"}])
    end

    test "no grants leaves the declared policy exactly as written" do
      declared = %{"component.pull" => "ask", "files.read" => "auto"}
      assert ToolGrants.resolve(declared, []) == declared
    end
  end

  describe "a bounded allow" do
    @notes %{kind: "storage_path", patterns: ["data/notes/"]}

    defp bounded(overrides) do
      Map.merge(
        %{
          effect: "allow",
          scope: "thread",
          tool: "files",
          action: "write",
          lifecycle_kind: "turn",
          lifecycle_id: "turn_1",
          expires_at: nil,
          constraint: @notes
        },
        overrides
      )
    end

    test "keeps its bounds on its pair, and the guest reads it as ask" do
      effective = ToolGrants.effective(%{"files.write" => "ask"}, [bounded(%{})])

      assert {:auto, {:bounded, [bounds]}} = effective["files.write"]
      assert %{scope: "thread", lifecycle_kind: "turn", lifecycle_id: "turn_1"} = bounds
      assert bounds.constraint == @notes

      assert ToolGrants.to_guest(effective) == %{"files.write" => "ask"}

      # One the author never listed joins the policy as a question, never
      # as an automatic pair.
      assert ToolGrants.resolve(%{}, [bounded(%{})]) == %{"files.write" => "ask"}
    end

    test "never narrows an authored auto, and gives way to an unbounded allow and to a deny" do
      assert ToolGrants.resolve(%{"files.write" => "auto"}, [bounded(%{})]) ==
               %{"files.write" => "auto"}

      assert ToolGrants.resolve(%{}, [
               bounded(%{}),
               bounded(%{scope: "agent", lifecycle_kind: nil, lifecycle_id: nil, constraint: nil})
             ]) ==
               %{"files.write" => "auto"}

      assert ToolGrants.resolve(%{"files.write" => "auto"}, [
               bounded(%{}),
               %{effect: "deny", scope: "agent", tool: "files", action: "write"}
             ]) == %{"files.write" => "deny"}
    end

    test "keeps every bounded allow for its pair" do
      effective =
        ToolGrants.effective(%{}, [
          bounded(%{}),
          bounded(%{scope: "agent", lifecycle_kind: "execution", lifecycle_id: "exec_1"})
        ])

      assert {:auto, {:bounded, [_, _] = kept}} = effective["files.write"]
      assert Enum.map(kept, & &1.scope) |> Enum.sort() == ["agent", "thread"]
    end

    test "is listed among the thread's standing answers, so it can be withdrawn" do
      assert ToolGrants.allowed_keys([bounded(%{})]) == MapSet.new([{"files", "write"}])

      assert ToolGrants.allowed_keys([
               bounded(%{}),
               %{effect: "allow", scope: "thread", tool: "component", action: "list"}
             ]) == MapSet.new([{"component", "list"}, {"files", "write"}])

      # Listed is not automatic: the guest still asks for it.
      assert ToolGrants.resolve(%{}, [bounded(%{})]) == %{"files.write" => "ask"}

      # A deny for the pair subtracts, and an allow the action's current
      # declaration refuses (a deadline gone) no longer stands.
      assert ToolGrants.allowed_keys([
               bounded(%{}),
               %{effect: "deny", scope: "agent", tool: "files", action: "write"}
             ]) == MapSet.new()

      assert ToolGrants.allowed_keys([
               bounded(%{expires_at: DateTime.add(DateTime.utc_now(), -1, :second)})
             ]) == MapSet.new()
    end

    test "that the action's current declaration refuses counts for nothing" do
      # A constraint on an action that names no resource, and a deadline
      # already gone: neither reaches the policy as a question.
      assert ToolGrants.resolve(%{}, [
               bounded(%{tool: "notes", action: "keep"}),
               bounded(%{
                 constraint: nil,
                 expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
               })
             ]) == %{}
    end
  end

  describe "the action's declaration through the port" do
    test "a virtual hand, a catalogued action and an upstream tool, with the resource each names" do
      assert {:ok, %{kind: :write, standing: nil, resource: {"path", :storage_path}}} =
               Sanctum.Grimoire.action_declaration("files.write")

      assert {:ok, %{kind: :read, resource: {"base_path", :storage_path}}} =
               Sanctum.Grimoire.action_declaration("files.search")

      assert {:ok, %{kind: :destructive, resource: {"path", :storage_path}}} =
               Sanctum.Grimoire.action_declaration("files.delete")

      # The files page's own tool and a component's source name their path
      # the same way.
      for name <-
            ~w(file.list file.read file.write file.delete) ++
              ~w(source.tree source.read source.grep source.write source.edit source.delete) do
        assert {:ok, %{resource: {"path", :storage_path}}} =
                 Sanctum.Grimoire.action_declaration(name),
               "#{name} names no path"
      end

      assert {:ok, %{kind: :write, standing: nil, resource: {"path", :storage_path}}} =
               Sanctum.Grimoire.action_declaration("source.write")

      assert {:ok, %{kind: :write, standing: :thread, resource: nil}} =
               Sanctum.Grimoire.action_declaration("notes.keep")

      assert {:ok, %{kind: :write, standing: false, resource: nil}} =
               Sanctum.Grimoire.action_declaration("notes.pin")

      assert {:ok, %{kind: :external, standing: nil, resource: nil}} =
               Sanctum.Grimoire.action_declaration("srv:repos.list.do")

      for name <- ["no_such_tool.go", "files.nothing", "files", "", ".write", "files."] do
        assert {:error, :not_found} = Sanctum.Grimoire.action_declaration(name),
               "#{inspect(name)} was answered"
      end
    end

    test "storage and http name no resource, so they take no constraint" do
      for name <- ~w(storage.write storage.read http.get http.post) do
        assert {:ok, %{resource: nil}} = Sanctum.Grimoire.action_declaration(name)
      end
    end
  end

  describe "scope" do
    test "an agent-scope row carries no thread, and is keyed by the athanor", %{ctx: ctx} do
      assert {:ok, row} = grant(ctx, %{scope: "agent"})
      assert is_nil(row.thread_id)
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
               "aqua.#{action} took a thread-scope standing allow"

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
      # anything — neither by being listed as a standing answer
      # (`allowed_keys/1`) nor by becoming `auto` in the policy the formula
      # is handed (`resolve/2`). A deny still counts.
      stale =
        %{
          athanor_id: ctx.athanor_id,
          scope: "thread",
          effect: "allow",
          thread_id: "thread_1",
          agent_name: "aqua",
          tool: "notes",
          action: "pin",
          granted_by: ctx.user_id
        }

      assert {:ok, _} = Arca.ToolGrantStorage.put(stale)
      assert {:ok, _} = Arca.ToolGrantStorage.put(%{stale | action: "forget", effect: "deny"})

      rows = rows(ctx, "thread_1", ctx.athanor_id, "aqua")
      assert length(rows) == 2

      assert ToolGrants.allowed_keys(rows) == MapSet.new()

      assert ToolGrants.resolve(%{"notes.pin" => "ask", "notes.forget" => "auto"}, rows) ==
               %{"notes.pin" => "ask", "notes.forget" => "deny"}
    end

    test "a thread-only action takes a thread allow and refuses the agent scope",
         %{ctx: ctx} do
      # `notes.keep` declares `standing: :thread`: a filed note
      # follows the thread it was kept from, never the agent — so an
      # agent-scope allow is refused outright rather than narrowed.
      assert {:ok, _} = grant(ctx, %{tool: "notes", action: "keep"})

      assert {:error, {:scope_not_permitted, :thread_only}} =
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

    test "a constraint binds only an action that names its resource, and a deny takes no bound",
         %{ctx: ctx} do
      notes = %{kind: "storage_path", patterns: ["data/notes/"]}

      assert {:error, {:scope_not_permitted, :no_resource}} =
               grant(ctx, %{tool: "notes", action: "keep", constraint: notes})

      assert {:error, {:scope_not_permitted, :resource_kind}} =
               grant(ctx, %{
                 tool: "files",
                 action: "write",
                 constraint: %{kind: "egress_domain", patterns: ["example.com"]}
               })

      assert {:ok, %{constraint: ^notes}} =
               grant(ctx, %{tool: "files", action: "write", constraint: notes})

      for bound <- [
            %{expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)},
            %{constraint: notes},
            %{lifecycle_kind: "turn", lifecycle_id: "turn_1"}
          ] do
        assert {:error, {:scope_not_permitted, :bounded_deny}} =
                 grant(ctx, Map.merge(%{tool: "files", action: "delete", effect: "deny"}, bound))
      end

      # The plain deny stands, and outranks an authored auto whatever the
      # clock says: nothing a deny carries can lapse.
      assert {:ok, deny} = grant(ctx, %{tool: "files", action: "delete", effect: "deny"})
      assert is_nil(deny.expires_at) and is_nil(deny.lifecycle_kind)

      rows = rows(ctx, "thread_1", ctx.athanor_id, "aqua")
      assert ToolGrants.resolve(%{"files.delete" => "auto"}, rows)["files.delete"] == "deny"
    end

    test "virtual tools are classified by the catalog, not the registry", %{ctx: ctx} do
      # `files` lives in the formula, not the operation table — a
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

      rows = rows(ctx, "thread_1", ctx.athanor_id, "aqua")
      assert [%{effect: "deny"}] = rows
    end

    test "the same pair in two threads is two rows", %{ctx: ctx} do
      {:ok, _} = grant(ctx, %{thread_id: "thread_1"})
      {:ok, _} = grant(ctx, %{thread_id: "thread_2"})

      assert [_] = rows(ctx, "thread_1", ctx.athanor_id, "aqua")
      assert [_] = rows(ctx, "thread_2", ctx.athanor_id, "aqua")
    end
  end

  describe "for_thread/3" do
    test "sees this thread's grants and the agent's, but not another thread's", %{ctx: ctx} do
      {:ok, _} = grant(ctx, %{thread_id: "thread_1", tool: "component", action: "pull"})
      {:ok, _} = grant(ctx, %{thread_id: "thread_2", tool: "component", action: "list"})
      {:ok, _} = grant(ctx, %{scope: "agent", tool: "record", action: "list"})

      keys =
        ctx
        |> rows("thread_1", ctx.athanor_id, "aqua")
        |> ToolGrants.allowed_keys()

      assert MapSet.equal?(keys, MapSet.new([{"component", "pull"}, {"record", "list"}]))
    end

    test "another agent's grants are not this agent's", %{ctx: ctx} do
      {:ok, _} = grant(ctx, %{agent_name: "planner"})

      assert [] = rows(ctx, "thread_1", ctx.athanor_id, "aqua")
    end
  end

  describe "revoke/2" do
    test "withdraws a row and is idempotent", %{ctx: ctx} do
      {:ok, _} = grant(ctx, %{})

      key = %{
        scope: "thread",
        thread_id: "thread_1",
        agent_name: "aqua",
        tool: "component",
        action: "pull"
      }

      assert :ok = ToolGrants.revoke(ctx, key)
      assert [] = rows(ctx, "thread_1", ctx.athanor_id, "aqua")
      assert :ok = ToolGrants.revoke(ctx, key)
    end

    test "a bounded allow the thread lists is withdrawn by its pair", %{ctx: ctx} do
      until = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, _} =
        grant(ctx, %{
          tool: "files",
          action: "write",
          expires_at: until,
          constraint: %{kind: "storage_path", patterns: ["data/notes/"]}
        })

      listed = ctx |> rows("thread_1", ctx.athanor_id, "aqua") |> ToolGrants.allowed_keys()
      assert listed == MapSet.new([{"files", "write"}])

      assert :ok =
               ToolGrants.revoke(ctx, %{
                 scope: "thread",
                 thread_id: "thread_1",
                 agent_name: "aqua",
                 tool: "files",
                 action: "write"
               })

      assert [] = rows(ctx, "thread_1", ctx.athanor_id, "aqua")
    end
  end

  # The rows a read answers — `{:ok, rows}`, since a store that cannot be
  # read is an error the caller refuses on, never an empty list.
  defp rows(ctx, thread_id, _owner, name) do
    {:ok, rows} = ToolGrants.for_thread(ctx, thread_id, name)
    rows
  end
end
