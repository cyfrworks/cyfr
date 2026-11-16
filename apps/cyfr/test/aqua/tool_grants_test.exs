# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ToolGrantsTest do
  # Standing approvals as rows: declared policy composed with what a person
  # actually answered, and the rule that keeps an answer from reaching
  # further than the athanor it was given in.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.Loop.Binding
  alias Aqua.Loop.Binding.Call
  alias Aqua.Loop.Policy
  alias Aqua.ToolGrants

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

  describe "resolve/3" do
    test "an allow with no other bound is bounded by its sources: a declared 'ask' still asks" do
      declared = %{"component.pull" => "ask"}
      grants = [%{scope: "thread", effect: "allow", tool: "component", action: "pull"}]

      # Each call is decided as it is made (`Sanctum.ToolGrants.admits?/2`),
      # never by a plain `auto` for the whole turn.
      assert ToolGrants.resolve(declared, grants, {:ok, true}) == %{"component.pull" => "ask"}

      assert {:auto, {:bounded, [%{lifecycle_kind: nil, expires_at: nil, constraint: nil}]}} =
               ToolGrants.effective(declared, grants, {:ok, true})["component.pull"]

      named = [Map.put(hd(grants), :sources, [Prima.Source.outside("registry.example")])]

      assert {:auto, {:bounded, [%{sources: [%Prima.Source{name: "registry.example"}]}]}} =
               ToolGrants.effective(declared, named, {:ok, true})["component.pull"]
    end

    test "a deny beats a declared 'auto' and pins the pair as denied" do
      declared = %{"component.pull" => "auto", "files.read" => "auto"}
      grants = [%{scope: "thread", effect: "deny", tool: "component", action: "pull"}]

      # Kept as an exact "deny", not dropped: every policy reader falls back
      # to a `tool.*` glob only for an ABSENT key, so a dropped pair would
      # let a surviving glob answer for it. A present "deny" is uncallable
      # and not proposable, so a person who said "never" is not asked again.
      assert ToolGrants.resolve(declared, grants, {:ok, true}) ==
               %{"component.pull" => "deny", "files.read" => "auto"}
    end

    test "a deny wins over an allow for the same pair" do
      declared = %{}

      grants = [
        %{scope: "thread", effect: "allow", tool: "component", action: "pull"},
        %{scope: "thread", effect: "deny", tool: "component", action: "pull"}
      ]

      assert ToolGrants.resolve(declared, grants, {:ok, true}) == %{"component.pull" => "deny"}
    end

    test "a deny is not defeated, or inverted, by a glob" do
      # Standing denies must override both exact and globbed ask/auto policies.
      deny = [%{scope: "thread", effect: "deny", tool: "component", action: "pull"}]

      composed = ToolGrants.resolve(%{"component.*" => "ask"}, deny, {:ok, true})
      assert composed["component.pull"] == "deny"
      refute Map.has_key?(composed, "component.*")
      assert composed["component.search"] == "ask"

      inverted =
        ToolGrants.resolve(
          %{"component.pull" => "ask", "component.*" => "auto"},
          deny,
          {:ok, true}
        )

      assert inverted["component.pull"] == "deny"
      assert inverted["component.search"] == "auto"
    end

    test "a key for a tool nobody catalogues and the search gate pass through composition untouched" do
      composed =
        ToolGrants.resolve(%{"builder.*" => "auto", "native_search" => "auto"}, [], {:ok, true})

      assert composed == %{"builder.*" => "auto", "native_search" => "auto"}
    end

    test "the kind ceiling demotes an automatic destructive action, wherever it came from" do
      # A hand-edited file, or a row written before the rule: neither
      # reaches the guest as auto.
      assert ToolGrants.resolve(
               %{"files.delete" => "auto", "files.read" => "auto"},
               [],
               {:ok, true}
             ) ==
               %{"files.delete" => "ask", "files.read" => "auto"}

      assert ToolGrants.resolve(%{"http.*" => "auto"}, [], {:ok, true})["http.delete"] == "ask"
    end

    test "the ceiling demotes an automatic action declared to take no agent-wide standing allow, written or globbed" do
      # A pin, an endorsement and a scroll's writes are asked at every
      # call, and a kept note takes a standing allow for one thread only:
      # a file that says auto for one reaches the guest as ask.
      authored = %{
        "notes.pin" => "auto",
        "notes.keep" => "auto",
        "notes.endorse" => "auto",
        "aqua.skill_create" => "auto",
        "aqua.skill_update" => "auto",
        "notes.read" => "auto"
      }

      assert ToolGrants.resolve(authored, [], {:ok, true}) == %{
               "notes.pin" => "ask",
               "notes.keep" => "ask",
               "notes.endorse" => "ask",
               "aqua.skill_create" => "ask",
               "aqua.skill_update" => "ask",
               "notes.read" => "auto"
             }

      globbed = ToolGrants.resolve(%{"notes.*" => "auto"}, [], {:ok, true})
      assert globbed["notes.pin"] == "ask"
      assert globbed["notes.endorse"] == "ask"
      assert globbed["notes.keep"] == "ask"
      assert globbed["notes.read"] == "auto"

      for {tool, action, standing} <- [
            {"notes", "pin", false},
            {"aqua", "skill_create", false},
            {"notes", "keep", :thread}
          ] do
        assert {:ok, %{kind: :write, standing: ^standing}} =
                 Sanctum.Catalog.action_declaration("#{tool}.#{action}")

        refute Aqua.Kinds.auto_permitted?(tool, action)
      end

      assert Aqua.Kinds.auto_permitted?("notes", "read")
    end

    test "the ceiling admits an authored auto on a launch, and a stored allow never makes one run without its card" do
      # A launch is decided by its line: an authored auto reaches the guest
      # as auto, where the component's grant decides it. No answer a person
      # gives is ever kept for it.
      assert {:ok, %{kind: :execute, standing: nil, stored_answers: false}} =
               Sanctum.Catalog.action_declaration("execution.run")

      assert Aqua.Kinds.auto_permitted?("execution", "run")

      assert ToolGrants.resolve(%{"execution.run" => "auto"}, [], {:ok, true}) == %{
               "execution.run" => "auto"
             }

      # A stored allow for execution.run, which the store refuses, counts
      # for nothing however it was written: it leaves an authored auto as
      # it is, an authored ask asking, and no line no line.
      allow = %{
        scope: "agent",
        effect: "allow",
        agent_name: "aqua",
        tool: "execution",
        action: "run",
        sources: []
      }

      launch = %Call{
        kind: :launch,
        tool: "execution",
        action: "run",
        args: %{"reference" => "reagent:local.app:1.0.0", "input" => %{}},
        target: "reagent:local.app:1.0.0"
      }

      asks = ToolGrants.resolve(%{"execution.run" => "ask"}, [allow], {:ok, true})
      assert asks == %{"execution.run" => "ask"}
      assert Policy.decide(launch, asks, sources: []) == :ask
      refute Policy.auto?(launch, asks, sources: [])

      assert ToolGrants.resolve(%{"execution.run" => "auto"}, [allow], {:ok, true}) ==
               %{"execution.run" => "auto"}

      assert ToolGrants.resolve(%{}, [allow], {:ok, true}) == %{}
    end

    test "an HTTP post, put or patch the author made automatic asks; a GET stays automatic" do
      # Each call resolves through the binding the loop uses, and its decision
      # reads the key the binding names, from the ceiling's own effective map.
      args = %{"url" => "https://example.test/", "body" => "b"}

      authored = %{
        "http.get" => "auto",
        "http.post" => "auto",
        "http.put" => "auto",
        "http.patch" => "auto"
      }

      effective = ToolGrants.effective(authored, [], {:ok, true})
      guest = ToolGrants.to_guest(effective)

      for name <- ~w(http.post http.put http.patch) do
        assert {:ok, %Call{tool: tool, action: action} = call} = Binding.resolve(name, args)
        assert {:ask, :authored} = effective["#{tool}.#{action}"], "#{name} stayed automatic"
        assert Policy.decide(call, guest, []) == :ask
      end

      assert {:ok, %Call{} = get} = Binding.resolve("http.get", args)
      assert {:auto, :authored} = effective["http.get"]
      assert Policy.decide(get, guest, []) == :auto
    end

    test "allowed_keys/1 is grant-derived and a deny subtracts" do
      rows = [
        %{effect: "allow", scope: "thread", tool: "component", action: "pull"},
        %{effect: "deny", scope: "agent", tool: "component", action: "pull"},
        %{effect: "allow", scope: "thread", tool: "component", action: "list"}
      ]

      assert ToolGrants.allowed_keys(rows) == MapSet.new([{"component", "list", nil, nil}])
    end

    test "no grants leaves the declared policy exactly as written" do
      declared = %{"component.pull" => "ask", "files.read" => "auto"}
      assert ToolGrants.resolve(declared, [], {:ok, true}) == declared
    end
  end

  describe "the person's browser setting" do
    # The browser tool's actions, each following the person's setting, and
    # its three of the setting itself, which follow their policy lines.
    @family ~w(open read click type key page screenshot close)
    @authored %{
      "browser.open" => "ask",
      "browser.read" => "auto",
      "browser.click" => "ask",
      "browser.type" => "ask",
      "browser.key" => "ask",
      "browser.page" => "ask",
      "browser.screenshot" => "auto",
      "browser.close" => "ask",
      "browser.status" => "auto",
      "browser.turn_on" => "ask",
      "browser.turn_off" => "auto"
    }
    @setting_lines %{
      "browser.status" => "auto",
      "browser.turn_on" => "ask",
      "browser.turn_off" => "auto"
    }

    defp family(mode), do: Map.new(@family, &{"browser.#{&1}", mode})

    test "decides every action that follows it, on as auto and off as deny, whatever the author wrote; its own three keep their lines" do
      assert Enum.filter(
               Aqua.Kinds.actions_of("browser"),
               &Sanctum.Catalog.follows_setting?("browser", &1)
             )
             |> Enum.sort() == Enum.sort(@family)

      assert ToolGrants.resolve(@authored, [], {:ok, true}) ==
               Map.merge(family("auto"), @setting_lines)

      assert ToolGrants.resolve(@authored, [], {:ok, false}) ==
               Map.merge(family("deny"), @setting_lines)

      # A store that could not answer reads as off.
      assert ToolGrants.resolve(@authored, [], {:error, :unavailable}) ==
               ToolGrants.resolve(@authored, [], {:ok, false})

      # A glob names the family as its exact lines do; the setting's own
      # turn_on still asks, since it takes no standing answer, and the
      # person's watch keeps the line it was given, which no agent can use:
      # no turn's chain is offered it.
      assert ToolGrants.resolve(%{"browser.*" => "auto"}, [], {:ok, true}) ==
               family("auto")
               |> Map.merge(%{@setting_lines | "browser.turn_on" => "ask"})
               |> Map.put("browser.watch", "auto")

      assert ToolGrants.effective(%{"browser.open" => "ask"}, [], {:ok, false}) ==
               %{"browser.open" => {:deny, :setting}}
    end

    test "counts no standing answer for the family, and gives the browser to no agent whose author named it nowhere",
         %{ctx: ctx} do
      # A deny for one, and an allow for another written past the rule, as
      # a row stored before the rule would be.
      {:ok, _} = grant(ctx, %{tool: "browser", action: "click", effect: "deny"})

      {:ok, _} =
        Arca.ToolGrantStorage.put(%{
          athanor_id: ctx.athanor_id,
          scope: "thread",
          effect: "allow",
          thread_id: "thread_1",
          agent_name: "aqua",
          tool: "browser",
          action: "open",
          granted_by: ctx.user_id
        })

      rows = rows(ctx, "thread_1", ctx.athanor_id, "aqua")
      assert length(rows) == 2

      assert ToolGrants.resolve(@authored, rows, {:ok, true}) ==
               Map.merge(family("auto"), @setting_lines)

      assert ToolGrants.resolve(@authored, rows, {:ok, false}) ==
               Map.merge(family("deny"), @setting_lines)

      assert ToolGrants.resolve(%{"files.read" => "auto"}, rows, {:ok, true}) ==
               %{"files.read" => "auto"}
    end

    test "makes no other action automatic: an outward or destructive one the author made auto still asks" do
      tools =
        Sanctum.VirtualTools.tools() ++
          for tool_def <- Sanctum.Catalog.list_tools(),
              not String.contains?(tool_def["name"], ":"),
              do: tool_def["name"]

      outward =
        for tool <- Enum.uniq(tools),
            action <- Aqua.Kinds.actions_of(tool),
            Aqua.Kinds.kind_for(tool, action) in [:external, :destructive],
            not Sanctum.Catalog.follows_setting?(tool, action),
            do: "#{tool}.#{action}"

      assert "http.post" in outward and "files.delete" in outward
      authored = Map.new(outward, &{&1, "auto"})

      for setting <- [{:ok, true}, {:ok, false}] do
        policy = ToolGrants.resolve(authored, [], setting)
        assert Enum.reject(policy, fn {_key, mode} -> mode == "ask" end) == []
        assert map_size(policy) == length(outward)
      end
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
      effective = ToolGrants.effective(%{"files.write" => "ask"}, [bounded(%{})], {:ok, true})

      assert {:auto, {:bounded, [bounds]}} = effective["files.write"]
      assert %{scope: "thread", lifecycle_kind: "turn", lifecycle_id: "turn_1"} = bounds
      assert bounds.constraint == @notes

      assert ToolGrants.to_guest(effective) == %{"files.write" => "ask"}

      # One the author never listed joins the policy as a question, never
      # as an automatic pair.
      assert ToolGrants.resolve(%{}, [bounded(%{})], {:ok, true}) == %{"files.write" => "ask"}
    end

    test "never narrows an authored auto, and gives way to a deny; no allow becomes a plain auto" do
      assert ToolGrants.resolve(%{"files.write" => "auto"}, [bounded(%{})], {:ok, true}) ==
               %{"files.write" => "auto"}

      assert ToolGrants.resolve(
               %{},
               [
                 bounded(%{}),
                 bounded(%{
                   scope: "agent",
                   lifecycle_kind: nil,
                   lifecycle_id: nil,
                   constraint: nil
                 })
               ],
               {:ok, true}
             ) ==
               %{"files.write" => "ask"}

      assert ToolGrants.resolve(
               %{"files.write" => "auto"},
               [
                 bounded(%{}),
                 %{effect: "deny", scope: "agent", tool: "files", action: "write"}
               ],
               {:ok, true}
             ) == %{"files.write" => "deny"}
    end

    test "keeps every bounded allow for its pair" do
      effective =
        ToolGrants.effective(
          %{},
          [
            bounded(%{}),
            bounded(%{scope: "agent", lifecycle_kind: "execution", lifecycle_id: "exec_1"})
          ],
          {:ok, true}
        )

      assert {:auto, {:bounded, [_, _] = kept}} = effective["files.write"]
      assert Enum.map(kept, & &1.scope) |> Enum.sort() == ["agent", "thread"]
    end

    test "is listed among the thread's standing answers, so it can be withdrawn" do
      assert ToolGrants.allowed_keys([bounded(%{})]) == MapSet.new([{"files", "write", nil, nil}])

      assert ToolGrants.allowed_keys([
               bounded(%{}),
               %{effect: "allow", scope: "thread", tool: "component", action: "list"}
             ]) == MapSet.new([{"component", "list", nil, nil}, {"files", "write", nil, nil}])

      # Listed is not automatic: the guest still asks for it.
      assert ToolGrants.resolve(%{}, [bounded(%{})], {:ok, true}) == %{"files.write" => "ask"}

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
      assert ToolGrants.resolve(
               %{},
               [
                 bounded(%{tool: "notes", action: "keep"}),
                 bounded(%{
                   constraint: nil,
                   expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
                 })
               ],
               {:ok, true}
             ) == %{}
    end
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
               Sanctum.Catalog.action_declaration("notes.pin")

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

    test "a stored standing allow for an HTTP post stops counting at the read", %{ctx: ctx} do
      # A row a surface wrote without `put/2`, so the write's rule never saw it.
      # Read back, it stands for nothing: the pair is not listed, and the
      # author's `auto` falls to `ask` at the ceiling.
      stale = %{
        athanor_id: ctx.athanor_id,
        scope: "thread",
        effect: "allow",
        thread_id: "thread_1",
        agent_name: "aqua",
        tool: "http",
        action: "post",
        granted_by: ctx.user_id
      }

      assert {:ok, _} = Arca.ToolGrantStorage.put(stale)

      rows = rows(ctx, "thread_1", ctx.athanor_id, "aqua")
      assert [_] = rows
      assert ToolGrants.allowed_keys(rows) == MapSet.new()

      assert ToolGrants.resolve(%{"http.post" => "auto"}, rows, {:ok, true}) == %{
               "http.post" => "ask"
             }
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
      # is handed (`resolve/3`). A deny still counts.
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

      assert ToolGrants.resolve(
               %{"notes.pin" => "ask", "notes.forget" => "auto"},
               rows,
               {:ok, true}
             ) ==
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

      assert ToolGrants.resolve(%{"files.delete" => "auto"}, rows, {:ok, true})["files.delete"] ==
               "deny"
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

    # An execution the schedule started, as its root's admission records
    # it; none for nil.
    defp run!(ctx, schedule_id) do
      id = "exec_tgs_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Arca.Execution.admit(
          %{
            id: id,
            reference: "catalyst:local.test:1.0.0",
            user_id: ctx.user_id,
            athanor_id: ctx.athanor_id,
            component_type: "catalyst",
            origin: :schedule
          },
          grant: Arca.Test.Actor.grant(ctx.athanor_id),
          verify: &Arca.Test.Actor.admits/1
        )

      if schedule_id do
        {1, _} =
          Arca.Repo.update_all(from(e in Arca.Schemas.Execution, where: e.id == ^id),
            set: [schedule_id: schedule_id]
          )
      end

      id
    end

    defp write_call(execution_id),
      do: %{
        agent_name: "aqua",
        thread_id: "thread_1",
        tool: "files",
        action: "write",
        args: %{"path" => "data/notes/a.md", "content" => "x"},
        execution_id: execution_id,
        sources: []
      }

    defp listed(ctx),
      do: ctx |> rows("thread_1", ctx.athanor_id, "aqua") |> ToolGrants.allowed_keys()

    test "one for A, one for B and an ordinary one stand side by side, each covering its own runs; a second for A replaces A's alone, withdrawing B's leaves the others, and deleting A ends A's alone",
         %{ctx: ctx, a: a, b: b} do
      write = %{
        scope: "agent",
        effect: "allow",
        agent_name: "aqua",
        tool: "files",
        action: "write"
      }

      for_a = Map.merge(write, %{lifecycle_kind: "schedule", lifecycle_id: a.id})
      for_b = Map.merge(write, %{lifecycle_kind: "schedule", lifecycle_id: b.id})
      [run_a, run_b, plain] = [run!(ctx, a.id), run!(ctx, b.id), run!(ctx, nil)]

      covered = fn ->
        for run <- [run_a, run_b, plain], do: Sanctum.ToolGrants.admits?(ctx, write_call(run))
      end

      {:ok, _} = Sanctum.ToolGrants.put(ctx, for_a)
      assert covered.() == [true, false, false]

      {:ok, _} = Sanctum.ToolGrants.put(ctx, for_b)
      assert covered.() == [true, true, false]

      {:ok, _} = Sanctum.ToolGrants.put(ctx, write)
      assert covered.() == [true, true, true]

      assert listed(ctx) ==
               MapSet.new([
                 {"files", "write", nil, a.id},
                 {"files", "write", nil, b.id},
                 {"files", "write", nil, nil}
               ])

      assert ToolGrants.allowed_by_agent(ctx, "thread_1") ==
               {:ok,
                MapSet.new([
                  {"aqua", "files", "write", nil, %{id: a.id, name: a.name}},
                  {"aqua", "files", "write", nil, %{id: b.id, name: b.name}},
                  {"aqua", "files", "write", nil, nil}
                ])}

      notes = %{kind: "storage_path", patterns: ["data/notes/"]}
      {:ok, _} = Sanctum.ToolGrants.put(ctx, Map.put(for_a, :constraint, notes))

      assert ctx
             |> rows("thread_1", ctx.athanor_id, "aqua")
             |> Enum.map(&{&1.schedule_id, &1.constraint})
             |> Enum.sort() == Enum.sort([{a.id, notes}, {b.id, nil}, {"", nil}])

      key = Map.delete(write, :effect)
      assert :ok = ToolGrants.revoke(ctx, Map.put(key, :schedule_id, b.id))

      assert listed(ctx) ==
               MapSet.new([{"files", "write", nil, a.id}, {"files", "write", nil, nil}])

      {:ok, _} = Arca.CronSchedule.soft_delete(Sanctum.Context.actor(ctx), a.id)
      assert listed(ctx) == MapSet.new([{"files", "write", nil, nil}])

      assert :ok = ToolGrants.revoke(ctx, key)
      assert listed(ctx) == MapSet.new()
      assert covered.() == [false, false, false]
    end

    test "the browser setting decides the browser's actions over an answer for a schedule, and makes the schedule's other answers no more than they were",
         %{ctx: ctx, a: a} do
      for_a = %{
        scope: "agent",
        effect: "allow",
        agent_name: "aqua",
        lifecycle_kind: "schedule",
        lifecycle_id: a.id
      }

      {:ok, %{schedule_id: id}} =
        Sanctum.ToolGrants.put(ctx, Map.merge(for_a, %{tool: "browser", action: "read"}))

      assert id == a.id
      {:ok, _} = Sanctum.ToolGrants.put(ctx, Map.merge(for_a, %{tool: "files", action: "write"}))
      run_a = run!(ctx, a.id)
      rows = rows(ctx, "thread_1", ctx.athanor_id, "aqua")
      authored = %{"browser.read" => "ask", "browser.open" => "ask", "files.write" => "ask"}

      read = %Call{kind: :catalog, tool: "browser", action: "read", args: %{}}
      place = [ctx: ctx, agent: "aqua", thread_id: "thread_1", execution_id: run_a, sources: []]

      on = ToolGrants.resolve(authored, rows, {:ok, true})
      assert on == %{"browser.read" => "auto", "browser.open" => "auto", "files.write" => "ask"}
      assert Policy.decide(read, on, place) == :auto

      assert Policy.decide(
               %Call{
                 kind: :catalog,
                 tool: "files",
                 action: "write",
                 args: write_call(run_a).args
               },
               on,
               place
             ) == :auto

      # Off, the schedule's answer for the read covers nothing; its answer
      # for files.write still covers the schedule's own runs.
      off = ToolGrants.resolve(authored, rows, {:ok, false})
      assert off == %{"browser.read" => "deny", "browser.open" => "deny", "files.write" => "ask"}
      assert {:deny, _sentence} = Policy.decide(read, off, place)
      assert Sanctum.ToolGrants.admits?(ctx, write_call(run_a))
      refute Sanctum.ToolGrants.admits?(ctx, write_call(run!(ctx, nil)))
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

  describe "for_thread/3" do
    test "sees this thread's grants and the agent's, but not another thread's", %{ctx: ctx} do
      {:ok, _} = grant(ctx, %{thread_id: "thread_1", tool: "component", action: "pull"})
      {:ok, _} = grant(ctx, %{thread_id: "thread_2", tool: "component", action: "list"})
      {:ok, _} = grant(ctx, %{scope: "agent", tool: "record", action: "list"})

      keys =
        ctx
        |> rows("thread_1", ctx.athanor_id, "aqua")
        |> ToolGrants.allowed_keys()

      assert MapSet.equal?(
               keys,
               MapSet.new([{"component", "pull", nil, nil}, {"record", "list", nil, nil}])
             )
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
      assert listed == MapSet.new([{"files", "write", nil, nil}])

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
