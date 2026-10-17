# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.PolicyTest do
  @moduledoc """
  A call runs, asks or is refused by the agent's effective policy; a
  launch always asks, whatever the policy says, since only an approved
  card launches; reads overlap and nothing else does; a card carries the
  canonical proposal and the catalog's kind and standing.
  """

  use ExUnit.Case, async: true

  alias Aqua.Loop.{Binding, Policy}

  defp resolve!(name, args, opts \\ []) do
    {:ok, call} = Binding.resolve(name, args, opts)
    call
  end

  @policy %{
    "files.read" => "auto",
    "files.write" => "ask",
    "notes.read" => "auto",
    "builder.*" => "auto",
    "execution.run" => "auto"
  }

  test "the decision matrix" do
    assert :auto =
             Policy.decide(resolve!("files", %{"action" => "read", "path" => "a"}), @policy, [])

    assert :ask =
             Policy.decide(resolve!("files", %{"action" => "write", "path" => "a"}), @policy, [])

    assert {:deny, text} =
             Policy.decide(resolve!("files", %{"action" => "delete", "path" => "a"}), @policy, [])

    assert text =~ "files.delete"
    assert :auto = Policy.decide(resolve!("ui", %{"kind" => "ui.navigate"}), @policy, [])

    assert :auto =
             Policy.decide(resolve!("builder", %{"task" => "x"}, roles: ["builder"]), @policy, [])

    assert {:deny, _} =
             Policy.decide(resolve!("web", %{"task" => "x"}, roles: ["web"]), @policy, [])

    assert :ask = Policy.decide(resolve!("github__search", %{}), @policy, [])
  end

  test "a launch always asks, consented or not, touched or not, unless it is denied or no component" do
    launch =
      resolve!("execution", %{"action" => "run", "reference" => "formula:local.demo:1.0.0"})

    consented = fn ref -> String.starts_with?(ref, "formula:local.demo") end

    # Every launch asks, whatever the policy says: only an approved card
    # launches.
    assert :ask = Policy.decide(launch, @policy, consented?: consented)
    assert :ask = Policy.decide(launch, @policy, consented?: fn _ -> false end)

    assert :ask =
             Policy.decide(launch, @policy,
               consented?: consented,
               touched: MapSet.new(["formula:local.demo"])
             )

    assert {:deny, _} =
             Policy.decide(launch, Map.put(@policy, "execution.run", "deny"),
               consented?: consented
             )

    # A policy that names no `execution.run` denies the launch: an agent
    # launches only what its own policy grants.
    for policy <- [%{}, Map.delete(@policy, "execution.run")] do
      assert {:deny, "execution.run is not in the agent's policy"} =
               Policy.decide(launch, policy, consented?: consented)
    end

    bad = resolve!("execution", %{"action" => "run", "reference" => "not a ref"})
    assert {:refuse, _} = Policy.decide(bad, @policy, [])
  end

  test "what the turn wrote to is read from the closed calls' rows" do
    calls = [
      %{
        "tool" => "files",
        "action" => "read",
        "arguments" => %{"path" => "components/formulas/local/demo/1.0.0/x"}
      },
      %{
        "tool" => "files",
        "action" => "write",
        "arguments" => %{"path" => "components/formulas/local/demo/1.0.0/src/lib.rs"}
      },
      %{
        "tool" => "component",
        "action" => "register",
        "arguments" => %{"reference" => "reagent:local.tool:2.0.0"}
      },
      %{
        "tool" => "build",
        "action" => "compile",
        "arguments" => %{"ref" => "catalyst:local.thing:0.1.0"}
      }
    ]

    touched = Policy.touched_refs(calls)
    assert MapSet.member?(touched, "formula:local.demo")
    assert MapSet.member?(touched, "catalyst:local.thing")
    refute MapSet.member?(touched, "formula:local.other")
  end

  test "a run after a source write and a compile of the same component still needs a card" do
    launch =
      resolve!("execution", %{"action" => "run", "reference" => "catalyst:local.widget:0.1.0"})

    consented = fn ref -> String.starts_with?(ref, "catalyst:local.widget") end

    closed =
      for {action, extra} <- [
            {"write", %{"content" => "fn main() {}"}},
            {"edit", %{"edits" => []}},
            {"delete", %{}}
          ] do
        [
          %{
            "tool" => "source",
            "action" => action,
            "arguments" =>
              Map.put(extra, "path", "components/catalysts/local/widget/0.1.0/src/lib.rs")
          },
          %{
            "tool" => "build",
            "action" => "compile",
            "arguments" => %{"reference" => "catalyst:local.widget:0.1.0"}
          }
        ]
      end

    for calls <- closed do
      touched = Policy.touched_refs(calls)
      assert MapSet.member?(touched, "catalyst:local.widget")
      assert :ask = Policy.decide(launch, @policy, consented?: consented, touched: touched)
    end
  end

  test "a launch of what the same batch writes to needs a card, whatever has closed" do
    launch =
      resolve!("execution", %{"action" => "run", "reference" => "formula:local.demo:1.0.0"})

    consented = fn ref -> String.starts_with?(ref, "formula:local.demo") end

    # Nothing has closed yet, which is the state every call in one model
    # response is decided in. Every launch asks, whatever the policy says.
    assert :ask = Policy.decide(launch, @policy, consented?: consented, touched: MapSet.new())

    # The same response also proposes writing to it.
    writes =
      Policy.touched_refs([
        %{
          "tool" => "files",
          "action" => "write",
          "arguments" => %{"path" => "components/formulas/local/demo/1.0.0/src/lib.rs"}
        }
      ])

    assert :ask = Policy.decide(launch, @policy, consented?: consented, touched: writes)
  end

  test "reads overlap; everything else runs alone" do
    assert :concurrent = Policy.overlap(resolve!("files", %{"action" => "read"}))
    assert :concurrent = Policy.overlap(resolve!("notes", %{"action" => "read"}))
    assert :exclusive = Policy.overlap(resolve!("files", %{"action" => "write"}))
    assert :exclusive = Policy.overlap(resolve!("builder", %{}, roles: ["builder"]))
    assert :exclusive = Policy.overlap(resolve!("github__search", %{}))
  end

  test "a card carries the canonical proposal, the kind and the standing, and a stable digest" do
    call =
      resolve!("files", %{"action" => "write", "path" => "data/storage/k.json", "content" => "{}"})

    card = Policy.card(call, id: "apr_1")

    assert card["proposal"] == %{
             "tool" => "storage",
             "action" => "write",
             "args" => %{"key" => "k", "value" => "{}"}
           } or
             card["proposal"]["tool"] == "storage"

    assert card["action_kind"] == "write"
    assert card["id"] == "apr_1"
    assert Policy.proposal_digest(card) == Policy.proposal_digest(card["proposal"])
    assert Policy.proposal_digest(card) =~ ~r/^sha256:[0-9a-f]{64}$/
  end

  test "a restricted turn runs replay-safe reads and nothing else, whatever the policy says" do
    read = resolve!("files", %{"action" => "read", "path" => "a"})
    write = resolve!("files", %{"action" => "write", "path" => "a", "content" => "b"})
    ui = resolve!("ui", %{"kind" => "ui.navigate"})

    assert Policy.replay_safe?(read)
    refute Policy.replay_safe?(write)
    refute Policy.replay_safe?(ui)

    assert :auto = Policy.decide(read, @policy, restricted?: true)
    assert {:deny, why} = Policy.decide(write, @policy, restricted?: true)
    assert why =~ "outcome is unknown"
    assert {:deny, _} = Policy.decide(ui, @policy, restricted?: true)
    assert :auto = Policy.decide(ui, @policy, restricted?: false)
  end

  # ---------------------------------------------------------------------------
  # What a launch's card binds
  # ---------------------------------------------------------------------------

  defp launch!(args \\ %{}) do
    resolve!(
      "execution",
      Map.merge(
        %{"action" => "run", "reference" => "reagent:local.app:1.0.0", "input" => %{}},
        args
      )
    )
  end

  defp digest(call, opts), do: call |> Policy.card(opts) |> Policy.proposal_digest()

  test "a launch's card binds the turn's sources, the grant's consent revision and the classes it lets flow" do
    call = launch!()
    pinned = Prima.Source.new(:pinned)
    host = Prima.Source.outside("news.example")

    shown = [
      sources: [pinned, host],
      launch: %{consent_id: "con_shown", classes: [:pinned, :outside]}
    ]

    card = Policy.card(call, shown)

    assert card["proposal"] == %{
             "tool" => "execution",
             "action" => "run",
             "args" => call.args,
             "sources" => [
               %{"class" => "pinned"},
               %{"class" => "outside", "name" => "news.example"}
             ],
             "consent_id" => "con_shown",
             "lets_flow" => ["pinned", "outside"]
           }

    # The binding reads back as what was bound.
    assert Aqua.Launch.bound(card["proposal"]) == %{
             sources: [pinned, host],
             consent_id: "con_shown",
             classes: [:pinned, :outside]
           }

    # Each of the three moves the digest: a card approved over one is not
    # the card of another.
    approved = digest(call, shown)
    assert digest(call, Keyword.put(shown, :sources, [pinned])) != approved

    assert digest(
             call,
             Keyword.put(shown, :launch, %{consent_id: "con_other", classes: [:pinned, :outside]})
           ) !=
             approved

    assert digest(
             call,
             Keyword.put(shown, :launch, %{consent_id: "con_shown", classes: [:pinned]})
           ) !=
             approved

    # A launch whose grant could not be loaded binds none, and still binds
    # the sources; any other call's card binds nothing of a launch.
    unloaded = Policy.card(call, sources: [pinned, host])["proposal"]
    assert %{"lets_flow" => [], "sources" => [_, _]} = unloaded
    refute Map.has_key?(unloaded, "consent_id")
    assert Aqua.Launch.bound(unloaded).consent_id == nil

    read = resolve!("files", %{"action" => "read", "path" => "a"})
    refute Map.has_key?(Policy.card(read, sources: [pinned])["proposal"], "sources")
  end

  # A blob of one node whose edges are `edges` (`{key, edge}`).
  defp blob(edges) do
    %Prima.Authority.Blob{
      nodes: %{
        "reagent:local.app" => %Prima.Authority.Blob.Node{limits: nil, edges: Map.new(edges)}
      }
    }
  end

  defp egress(domains, flows),
    do: %Prima.Authority.Blob.Edge{
      egress: %{domains: domains, methods: [], schemes: [], private_ips: []},
      flows: flows
    }

  defp server(name, flows),
    do: %Prima.Authority.Blob.Edge{
      tool_servers: [
        %{
          server_digest: "sha256:x",
          server_name: name,
          tool_patterns: ["*"],
          descriptions_digest: nil
        }
      ],
      flows: flows
    }

  test "a launch lets flow the classes some exit of the grant's tree declares no flow of" do
    pinned = Prima.Source.new(:pinned)
    filed = Prima.Source.new(:filed)
    api = Prima.Source.outside("api.example.com")

    covered = egress(["api.example.com"], [%{from: :pinned, to: "api.example.com"}])

    # A class the edge's own flow covers at its one exit needs nothing.
    assert Policy.lets_flow(blob([{"@ingress", covered}]), [pinned]) == []
    assert Policy.lets_flow(blob([{"@ingress", covered}]), [pinned, filed]) == [:filed]

    # Every exit of the tree counts: a tool server with no pinned flow lets
    # pinned flow, whatever the domain's flow covers.
    tree = blob([{"@ingress", covered}, {"catalyst:local.tool", server("github", [])}])
    assert Policy.lets_flow(tree, [pinned]) == [:pinned]

    github = server("github", [%{from: :pinned, to: "server:github"}])
    assert Policy.lets_flow(blob([{"@ingress", covered}, {"tool", github}]), [pinned]) == []

    # Material from a host may go back to it by name; a pattern never
    # covers by name.
    assert Policy.lets_flow(blob([{"@ingress", egress(["api.example.com"], [])}]), [api]) == []

    assert Policy.lets_flow(blob([{"@ingress", egress(["*.example.com"], [])}]), [api]) == [
             :outside
           ]

    # A domain narrowed under a flow's pattern keeps the pattern's flow.
    narrowed = egress(["api.example.com"], [%{from: :filed, to: "*.example.com"}])
    assert Policy.lets_flow(blob([{"@ingress", narrowed}]), [filed]) == []

    # No exit, no flow to let; and a grant with no blob lets nothing.
    assert Policy.lets_flow(blob([{"@ingress", %Prima.Authority.Blob.Edge{}}]), [pinned]) == []
    assert Policy.lets_flow(:none, [pinned, filed]) == []
  end

  test "a child's answer carries its ledger, says nothing ran, or leaves it to the row" do
    vault = Prima.Source.new(:vault_disclosed)

    assert Policy.child_ledger({:ok, %{status: :completed, output: %{}, sources: [vault]}}) ==
             {:carried, [vault]}

    admission = %Prima.Refusal{
      class: :forbidden,
      reason: :denied,
      message: "no",
      stage: :admission
    }

    assert Policy.child_ledger({:error, admission}) == :nothing_ran

    # A refusal of the execution, a failure's text, an answer with no
    # ledger or one that does not read, and a death leave it to the row.
    assert Policy.child_ledger({:error, %{admission | stage: :execution}}) == :unknown
    assert Policy.child_ledger({:error, "the run failed"}) == :unknown
    assert Policy.child_ledger({:ok, %{output: %{}}}) == :unknown

    assert Policy.child_ledger({:ok, %{output: %{}, sources: [%{"class" => "filed"}]}}) ==
             :unknown

    assert Policy.child_ledger({:error, {:invoke_denied, :edge_missing}}) == :unknown

    # A hand's result carries its child's ledger beside what the hand names.
    get = resolve!("http", %{"action" => "get", "url" => "https://news.example/today"})

    assert Policy.sources_of(get, {:ok, %{output: %{}, sources: [vault]}}, ctx()) ==
             [Prima.Source.outside("news.example"), vault]

    assert Policy.sources_of(get, {:error, "the run failed"}, ctx()) ==
             [Prima.Source.outside("news.example")]
  end

  describe "a catalog call's sources are its operation's" do
    # Sol's assessment probe (Sol-2): a registry read declares no sources,
    # so its answer is outside, as the operation's own reading says.
    for action <- ["get_namespace", "legal_page"] do
      test "catalog retains canonical sources: #{action}" do
        action = unquote(action)
        ctx = %{ctx() | athanor_id: "ath_probe", user_id: "usr_probe"}
        operation = registry_operation(action)
        call = %Binding.Call{kind: :catalog, tool: "registry", action: action, args: %{}}
        answer = %{content: "outside registry content"}
        expected = Prima.Operation.answer_sources(operation, Sanctum.Context.actor(ctx), answer)

        assert Policy.sources_of(call, {:ok, answer}, ctx) == expected
        assert expected == [Prima.Source.outside(nil)]
      end
    end

    # Opus's assessment probe (Sol-2): the same reads, resolved as the
    # model names them, carry an outside source into the turn.
    test "a registry read carries an outside source into the turn" do
      ctx = %{ctx() | athanor_id: "ath_probe"}

      results =
        for action <- ["get_namespace", "legal_page"] do
          operation = registry_operation(action)
          assert %Prima.Operation{kind: :read, sources: [:outside]} = operation
          call = resolve!("registry", %{"action" => action, "slug" => "acme", "name" => "terms"})
          answer = %{content: "outside registry content"}
          expected = Prima.Operation.answer_sources(operation, Sanctum.Context.actor(ctx), answer)
          {action, expected, Policy.sources_of(call, {:ok, answer}, ctx)}
        end

      for {action, expected, actual} <- results do
        assert {action, actual} == {action, expected}
        assert expected == [Prima.Source.outside(nil)]
      end
    end

    test "every catalogued action's success is what its declaration reads from the answer" do
      ctx = ctx()
      actor = Sanctum.Context.actor(ctx)
      answer = %{content: "an answer"}

      for {tool, {_module, %{operations: operations}}} <- Sanctum.Catalog.operations(),
          %Prima.Operation{action: action} = operation <- operations do
        call = %Binding.Call{kind: :catalog, tool: tool, action: action, args: %{}}

        assert Policy.sources_of(call, {:ok, answer}, ctx) ==
                 Prima.Operation.answer_sources(operation, actor, answer),
               "#{tool}.#{action}"
      end
    end

    test "an explicit empty declaration carries nothing; an omitted one, and an action nothing declares, is outside" do
      ctx = ctx()
      list = %Binding.Call{kind: :catalog, tool: "feed", action: "list", args: %{}}
      # An action served only outside a chain need not declare; one that
      # does not is outside.
      push = %Binding.Call{kind: :catalog, tool: "component", action: "push", args: %{}}
      unknown = %Binding.Call{kind: :catalog, tool: "nonesuch", action: "read", args: %{}}

      assert %Prima.Operation{sources: []} = operation("feed", "list")
      assert %Prima.Operation{sources: nil, planes: [:external]} = operation("component", "push")
      assert Policy.sources_of(list, {:ok, %{feeds: []}}, ctx) == []
      assert Policy.sources_of(push, {:ok, %{}}, ctx) == [Prima.Source.outside(nil)]
      assert Policy.sources_of(unknown, {:ok, %{}}, ctx) == [Prima.Source.outside(nil)]
      assert Policy.sources_of(unknown, {:error, "no"}, ctx) == [Prima.Source.outside(nil)]
    end

    test "source, notes and feed.list carry what their declarations say" do
      ctx = ctx()
      grant = Prima.Source.new(:files_by_grant)
      filed = Prima.Source.new(:filed)
      host = Prima.Source.outside("news.example")
      read = resolve!("source", %{"action" => "read", "path" => "components/x"})
      write = resolve!("source", %{"action" => "write", "path" => "components/x"})
      note = resolve!("notes", %{"action" => "read", "name" => "plan"})
      keep = resolve!("notes", %{"action" => "keep", "name" => "plan", "content" => "c"})
      list = resolve!("feed", %{"action" => "list"})

      assert Policy.sources_of(read, {:ok, %{content: "fn main() {}"}}, ctx) == [grant]
      assert Policy.sources_of(write, {:ok, %{written: "components/x"}}, ctx) == []

      # A note keeps the provenance it was written with.
      answer = %{name: "plan", content: "fares rise", sources: [Prima.Source.to_json(host)]}
      assert Policy.sources_of(note, {:ok, answer}, ctx) == [filed, host]
      assert Policy.sources_of(keep, {:ok, %{kept: "plan", replaced: false}}, ctx) == []

      # A listing answers each feed's binding, never a result's value.
      listing = %{
        feeds: [%{binding: "fb_1", feed: "fares", label: "Fares", revision: 3, at: nil}]
      }

      assert Policy.sources_of(list, {:ok, listing}, ctx) == []
    end

    test "a refusal at admission carries nothing; any other failure every class the action may answer" do
      ctx = ctx()

      admission = %Prima.Refusal{
        class: :forbidden,
        reason: :denied,
        message: "no",
        stage: :admission
      }

      execution = %{admission | stage: :execution}
      namespace = resolve!("registry", %{"action" => "get_namespace", "slug" => "acme"})
      note = resolve!("notes", %{"action" => "read", "name" => "plan"})
      read = resolve!("source", %{"action" => "read", "path" => "components/x"})
      write = resolve!("source", %{"action" => "write", "path" => "components/x"})

      for call <- [namespace, note, read, write],
          do: assert(Policy.sources_of(call, {:error, admission}, ctx) == [], call.tool)

      # A registry's error body may carry what the registry answered.
      assert Policy.sources_of(namespace, {:error, execution}, ctx) == [Prima.Source.outside(nil)]

      assert Policy.sources_of(namespace, {:error, "the registry said: buy now"}, ctx) ==
               [Prima.Source.outside(nil)]

      # An answer read by its own reader may carry any class; none is read
      # from a failure.
      assert Policy.sources_of(note, {:error, :not_found}, ctx) ==
               Enum.map(Prima.Source.classes(), &Prima.Source.new/1)

      assert Policy.sources_of(read, {:error, :not_found}, ctx) == [
               Prima.Source.new(:files_by_grant)
             ]

      assert Policy.sources_of(write, {:error, :not_found}, ctx) == []
    end
  end

  defp ctx, do: Sanctum.TestContext.local()

  defp operation(tool, action) do
    {:ok, {_module, %{operations: operations}}} = Sanctum.Catalog.lookup(tool)
    Enum.find(operations, &(&1.action == action))
  end

  defp registry_operation(action),
    do:
      Enum.find(
        Compendium.Providers.Registry.definition().operations,
        &(&1.action == action)
      )
end
