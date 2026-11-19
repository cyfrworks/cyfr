# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ToolGrantsTest do
  # Standing answers as rows, written through `Sanctum.ToolGrants` against
  # the live catalog: the rule that decides which answers may stand, and
  # keeps an answer from reaching further than the athanor it was given in.
  use ExUnit.Case, async: false

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
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

    Sanctum.ToolGrants.put(ctx, attrs)
  end

  describe "the action's declaration from the operation table" do
    test "a virtual hand, a catalogued action and an upstream tool, with the resource each names" do
      assert {:ok, %{kind: :write, standing: nil, resource: {"path", :storage_path}}} =
               Sanctum.Catalog.action_declaration("files.write")

      assert {:ok, %{kind: :read, resource: {"base_path", :storage_path}}} =
               Sanctum.Catalog.action_declaration("files.search")

      assert {:ok, %{kind: :destructive, resource: {"path", :storage_path}}} =
               Sanctum.Catalog.action_declaration("files.delete")

      # The files page's own tool and a component's source name their path
      # the same way.
      for name <-
            ~w(file.list file.read file.write file.delete) ++
              ~w(source.tree source.read source.grep source.write source.edit source.delete) do
        assert {:ok, %{resource: {"path", :storage_path}}} =
                 Sanctum.Catalog.action_declaration(name),
               "#{name} names no path"
      end

      assert {:ok, %{kind: :write, standing: nil, resource: {"path", :storage_path}}} =
               Sanctum.Catalog.action_declaration("source.write")

      assert {:ok, %{kind: :write, standing: :thread, resource: nil}} =
               Sanctum.Catalog.action_declaration("notes.keep")

      assert {:ok, %{kind: :write, standing: false, resource: nil}} =
               Sanctum.Catalog.action_declaration("notes.endorse")

      assert {:ok, %{kind: :external, standing: nil, resource: nil}} =
               Sanctum.Catalog.action_declaration("srv:repos.list.do")

      for name <- ["no_such_tool.go", "files.nothing", "files", "", ".write", "files."] do
        assert {:error, :not_found} = Sanctum.Catalog.action_declaration(name),
               "#{inspect(name)} was answered"
      end
    end

    test "storage and http name no resource, so they take no constraint" do
      for name <- ~w(storage.write storage.read http.get http.post) do
        assert {:ok, %{resource: nil}} = Sanctum.Catalog.action_declaration(name)
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
      # `notes.forget` is `kind: :destructive` in the live registry.
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

    test "an HTTP post, put or patch takes no standing allow at the write, at either scope", %{
      ctx: ctx
    } do
      # Their kind is external: a destination outside the home is never a
      # standing answer. A deny stands, and a GET (a read) is granted.
      for action <- ~w(post put patch) do
        assert {:error, {:scope_not_permitted, :external}} =
                 grant(ctx, %{tool: "http", action: action}),
               "http.#{action} took a thread-scope standing allow"

        assert {:error, {:scope_not_permitted, :external}} =
                 grant(ctx, %{scope: "agent", tool: "http", action: action}),
               "http.#{action} took an agent-scope standing allow"

        assert {:ok, _} = grant(ctx, %{tool: "http", action: action, effect: "deny"})
      end

      assert {:error, {:scope_not_permitted, :destructive}} =
               grant(ctx, %{tool: "http", action: "delete"})

      assert {:ok, _} = grant(ctx, %{tool: "http", action: "get"})
    end

    test "an action that never stands takes no standing allow at any scope, and a deny stands",
         %{ctx: ctx} do
      # `notes.endorse` is `kind: :write` — the kind alone would admit it.
      # Its `standing: false` declaration is what refuses it here.
      assert {:error, {:scope_not_permitted, :never_standing}} =
               grant(ctx, %{tool: "notes", action: "endorse"})

      assert {:error, {:scope_not_permitted, :never_standing}} =
               grant(ctx, %{scope: "agent", tool: "notes", action: "endorse"})

      assert {:ok, _} = grant(ctx, %{tool: "notes", action: "endorse", effect: "deny"})

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

      # The plain deny stands: nothing a deny carries can lapse.
      assert {:ok, deny} = grant(ctx, %{tool: "files", action: "delete", effect: "deny"})
      assert is_nil(deny.expires_at) and is_nil(deny.lifecycle_kind)
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

  describe "answers for a schedule" do
    setup %{ctx: ctx} do
      Arca.Test.Actor.ensure_athanor_row(ctx.athanor_id)
      {:ok, a: schedule!(ctx, "Morning"), b: schedule!(ctx, "Evening")}
    end

    defp schedule!(ctx, name) do
      {:ok, row} =
        Arca.CronSchedule.create(Sanctum.Context.actor(ctx), %{
          user_id: ctx.user_id,
          name: "#{name}-#{System.unique_integer([:positive])}",
          cron_expression: "*/5 * * * *",
          reference: "reagent:local.test:1.0.0",
          resolved_reference: "reagent:local.test:1.0.0",
          profile_id: "prof_test",
          cap: 0
        })

      row
    end

    test "a thread-only action takes an agent-wide allow only when it ends with a schedule; a launch, a destructive and an external action take none",
         %{ctx: ctx, a: a} do
      schedule = %{scope: "agent", lifecycle_kind: "schedule", lifecycle_id: a.id}

      assert {:ok, %{scope: "agent", schedule_id: id}} =
               grant(ctx, Map.merge(schedule, %{tool: "notes", action: "keep"}))

      assert id == a.id

      assert {:error, {:scope_not_permitted, :thread_only}} =
               grant(ctx, %{scope: "agent", tool: "notes", action: "keep"})

      for {pair, reason} <- [
            {%{tool: "execution", action: "run"}, :never_standing},
            {%{tool: "files", action: "delete"}, :destructive},
            {%{tool: "http", action: "post"}, :external}
          ] do
        assert {:error, {:scope_not_permitted, ^reason}} = grant(ctx, Map.merge(schedule, pair)),
               "#{pair.tool}.#{pair.action} stood for a schedule"
      end
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

  # The rows a read answers for one agent: the thread's own and the
  # athanor's agent-scope ones (`Sanctum.ToolGrants.for_thread/2`).
  defp rows(ctx, thread_id, _owner, name) do
    {:ok, rows} = Sanctum.ToolGrants.for_thread(ctx, thread_id)
    Enum.filter(rows, &(&1.agent_name == name))
  end
end
