# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.PolicyTest do
  @moduledoc """
  A call runs or is refused by its member's offered set, and is never
  asked: every offered call runs, a launch with its call and its account,
  and the `ui` event and the turn's own start of its program brain run
  offered or not. A call not offered is refused. Reads overlap and
  nothing else does.
  """

  use ExUnit.Case, async: true

  alias Aqua.Loop.{Binding, Policy}

  defp resolve!(name, args) do
    {:ok, call} = Binding.resolve(name, args)
    call
  end

  # Every call of section 2's table, offered: a soul's read, a write, an
  # execute, a destructive and an external action, a component's launch,
  # a model's program start, the browser's external and write actions,
  # the notes writes, the workspace thread's writes, a hand-off, a post
  # and an outside server's tool.
  @rows [
    {"a file read", "files", %{"action" => "read", "path" => "a"}},
    {"a notes read", "notes", %{"action" => "list"}},
    {"a web read", "http", %{"action" => "get", "url" => "https://example.com/"}},
    {"a thread search", "thread", %{"action" => "search", "query" => "q"}},
    {"the crew's list", "crew", %{"action" => "list"}},
    {"the browser's read", "browser", %{"action" => "read"}},
    {"the browser's status", "browser", %{"action" => "status"}},
    {"a file write", "files", %{"action" => "write", "path" => "a", "content" => "b"}},
    {"a file delete", "files", %{"action" => "delete", "path" => "a"}},
    {"a web post", "http", %{"action" => "post", "url" => "https://example.com/"}},
    {"a launch", "execution",
     %{"action" => "run", "reference" => "reagent:local.app:1.0.0", "input" => %{}}},
    {"a model's program start", "program", %{"action" => "start", "program" => "srv_1"}},
    {"the browser's open", "browser", %{"action" => "open", "url" => "https://example.com/"}},
    {"the browser's click", "browser", %{"action" => "click", "ref" => "e1"}},
    {"the browser's close", "browser", %{"action" => "close"}},
    {"the browser's turn off", "browser", %{"action" => "turn_off"}},
    {"a kept note", "notes", %{"action" => "keep", "name" => "n", "content" => "c"}},
    {"the pinned page", "notes", %{"action" => "pin", "content" => "c"}},
    {"a workspace's notes", "notes", %{"action" => "workspace", "content" => "c"}},
    {"a forgotten note", "notes", %{"action" => "forget", "name" => "n"}},
    {"a workspace opened", "workspace", %{"action" => "open", "title" => "t", "ask" => "a"}},
    {"a workspace report", "workspace",
     %{"action" => "report", "outcome" => "done", "summary" => "s"}},
    {"a hand-off", "crew", %{"action" => "ask", "member" => "explorer", "task" => "t"}},
    {"a post", "thread", %{"action" => "post", "content" => "c"}},
    {"an outside server's tool", "github__search", %{"q" => "x"}}
  ]

  defp offered(rows) do
    keys =
      for {_label, name, args} <- rows do
        case resolve!(name, args) do
          %{kind: :external, tool: tool} -> tool
          %{tool: tool, action: action} -> "#{tool}.#{action}"
        end
      end

    Aqua.Offered.resolve(keys, {:ok, true})
  end

  @opts [title: "Aqua"]

  test "each row of the table, offered, runs: a launch with its call and its account" do
    offered = offered(@rows)

    for {label, name, args} <- @rows do
      call = resolve!(name, args)

      if call.kind == :launch do
        assert Policy.decide(call, offered, @opts) ==
                 {:run, %{call: %{action: call.action, args: call.args}, account: nil}},
               label
      else
        assert Policy.decide(call, offered, @opts) == :run, label
      end
    end
  end

  test "what only shows the person something runs, offered or not" do
    for call <- [resolve!("ui", %{"kind" => "ui.navigate"}), resolve!("request_setup.open", %{})] do
      assert :run = Policy.decide(call, %{}, @opts)
    end
  end

  test "the turn's own start of its program brain runs, offered or not" do
    start = resolve!("program", %{"action" => "start", "program" => "srv_1", "epoch" => 1})

    assert :run = Policy.decide(start, %{}, host_start: true)

    # A model's start of a program is a call like any other.
    assert {:deny, _} = Policy.decide(start, %{}, @opts)
  end

  test "a call not offered is refused, a browser action the setting turned off in the browser's words" do
    offered = Aqua.Offered.resolve(["files.read", "browser.open"], {:ok, false})
    assert offered == %{"files.read" => "offered", "browser.open" => "off"}

    write = resolve!("files", %{"action" => "write", "path" => "a", "content" => "b"})
    open = resolve!("browser", %{"action" => "open", "url" => "https://example.com/"})
    tool = resolve!("github__search", %{})

    assert {:deny, "files.write is not among the tools Aqua is offered"} =
             Policy.decide(write, offered, @opts)

    assert {:deny, sentence} = Policy.decide(open, offered, @opts)
    assert sentence == Aqua.Providers.Browser.turned_off()

    assert {:deny, "github:search is not among the tools Aqua is offered"} =
             Policy.decide(tool, offered, @opts)
  end

  test "a launch naming no component is refused" do
    bad = resolve!("execution", %{"action" => "run", "reference" => "not a ref"})
    offered = Aqua.Offered.resolve(["execution.run"], {:ok, true})

    assert {:refuse, _} = Policy.decide(bad, offered, @opts)
  end

  test "a launch's decision is its call and its account, and binds nothing of what the turn read" do
    args = %{"action" => "run", "reference" => "reagent:local.app:1.0.0", "input" => %{}}
    launch = resolve!("execution", args)
    offered = Aqua.Offered.resolve(["execution.run"], {:ok, true})

    assert launch.action == "run"

    assert Policy.decide(launch, offered, title: "Aqua") ==
             {:run, %{call: %{action: "run", args: launch.args}, account: nil}}
  end

  test "the offered set is each entry as written: an action the tool lacks, or a wildcard, " <>
         "offers nothing, and the rest pass" do
    offered =
      Aqua.Offered.resolve(
        ["notes.keep", "notes.*", "files.nope", "native_search", "github:search"],
        {:ok, true}
      )

    assert offered == %{
             "notes.keep" => "offered",
             "native_search" => "offered",
             "github:search" => "offered"
           }
  end

  test "the browser's own actions are offered with the person's setting on, and off with it " <>
         "off or with a setting store that could not answer; the setting's own actions stay " <>
         "offered" do
    actions = Aqua.Kinds.actions_of("browser")
    listed = Enum.map(actions, &"browser.#{&1}")
    follows? = &Sanctum.Catalog.follows_setting?("browser", &1)
    assert follows?.("open") and not follows?.("status")

    turned_off =
      Map.new(actions, &{"browser.#{&1}", if(follows?.(&1), do: "off", else: "offered")})

    assert Aqua.Offered.resolve(listed, {:ok, true}) == Map.new(listed, &{&1, "offered"})

    for setting <- [{:ok, false}, {:error, :unavailable}] do
      assert Aqua.Offered.resolve(listed, setting) == turned_off, inspect(setting)
    end
  end

  test "reads overlap; everything else runs alone" do
    assert :concurrent = Policy.overlap(resolve!("files", %{"action" => "read"}))
    assert :concurrent = Policy.overlap(resolve!("notes", %{"action" => "read"}))
    assert :exclusive = Policy.overlap(resolve!("files", %{"action" => "write"}))
    assert :exclusive = Policy.overlap(resolve!("github__search", %{}))
  end

  # The loop runs only these in a restricted turn (loop_test's stopped
  # turn carried on: a read runs, a write is denied).
  test "a read is replay-safe; a write and a ui event are not" do
    assert Policy.replay_safe?(resolve!("files", %{"action" => "read", "path" => "a"}))

    refute Policy.replay_safe?(
             resolve!("files", %{"action" => "write", "path" => "a", "content" => "b"})
           )

    refute Policy.replay_safe?(resolve!("ui", %{"kind" => "ui.navigate"}))
  end

  test "a child's answer carries its read threads, says nothing ran, or leaves them to the row" do
    assert Policy.child_threads(
             {:ok, %{status: :completed, output: %{}, read_threads: ["thr_a"]}}
           ) == {:carried, ["thr_a"]}

    admission = %Prima.Refusal{
      class: :forbidden,
      reason: :denied,
      message: "no",
      stage: :admission
    }

    assert Policy.child_threads({:error, admission}) == :nothing_ran

    # A refusal of the execution, a failure's text, an answer with no read
    # threads or with ones that are no thread ids, and a death leave them
    # to the row.
    assert Policy.child_threads({:error, %{admission | stage: :execution}}) == :unknown
    assert Policy.child_threads({:error, "the run failed"}) == :unknown
    assert Policy.child_threads({:ok, %{output: %{}}}) == :unknown

    assert Policy.child_threads({:ok, %{output: %{}, read_threads: [%{"thread" => "thr_a"}]}}) ==
             :unknown

    assert Policy.child_threads({:error, {:invoke_denied, :edge_missing}}) == :unknown

    # A hand's result carries its child's read threads, and nothing of its own.
    get = resolve!("http", %{"action" => "get", "url" => "https://news.example/today"})

    assert Policy.threads_of(get, {:ok, %{output: %{}, read_threads: ["thr_a"]}}, ctx()) ==
             ["thr_a"]

    assert Policy.threads_of(get, {:error, "the run failed"}, ctx()) == []
  end

  describe "a catalog call's read threads are its operation's" do
    test "every catalogued action's success is what its declaration reads from the answer" do
      ctx = ctx()
      actor = Sanctum.Context.actor(ctx)
      answer = %{content: "an answer", read_threads: ["thr_a"]}

      carried =
        for {tool, {_module, %{operations: operations}}} <- Sanctum.Catalog.operations(),
            %Prima.Operation{action: action} = operation <- operations do
          call = %Binding.Call{kind: :catalog, tool: tool, action: action, args: %{}}
          threads = Policy.threads_of(call, {:ok, answer}, ctx)

          assert threads == Prima.Operation.read_threads(operation, actor, {:ok, answer}),
                 "#{tool}.#{action}"

          {"#{tool}.#{action}", threads}
        end

      # The answer names one thread and no execution: the reads whose
      # declaration reads the answer's own ids carry it, every other none.
      assert for({name, ["thr_a"]} <- carried, do: name) |> Enum.sort() ==
               ["file.read", "thread.events", "thread.search"]

      assert for({name, [_ | _] = threads} <- carried, threads != ["thr_a"], do: name) == []
    end

    test "an action that declares no threads, and one nothing declares, carries none" do
      ctx = ctx()
      list = %Binding.Call{kind: :catalog, tool: "feed", action: "list", args: %{}}
      push = %Binding.Call{kind: :catalog, tool: "component", action: "push", args: %{}}
      unknown = %Binding.Call{kind: :catalog, tool: "nonesuch", action: "read", args: %{}}

      assert %Prima.Operation{threads: nil} = operation("feed", "list")
      assert %Prima.Operation{threads: nil, planes: [:external]} = operation("component", "push")
      assert Policy.threads_of(list, {:ok, %{feeds: []}}, ctx) == []
      assert Policy.threads_of(push, {:ok, %{}}, ctx) == []
      assert Policy.threads_of(unknown, {:ok, %{}}, ctx) == []
      assert Policy.threads_of(unknown, {:error, "no"}, ctx) == []
    end

    test "a thread read and a file read carry the threads their answers name; source, notes " <>
           "and feed.list carry none" do
      ctx = ctx()
      search = %Binding.Call{kind: :catalog, tool: "thread", action: "search", args: %{}}
      events = %Binding.Call{kind: :catalog, tool: "thread", action: "events", args: %{}}
      file = %Binding.Call{kind: :catalog, tool: "file", action: "read", args: %{}}
      read = resolve!("source", %{"action" => "read", "path" => "components/x"})
      write = resolve!("source", %{"action" => "write", "path" => "components/x"})
      note = resolve!("notes", %{"action" => "read", "name" => "plan"})
      keep = resolve!("notes", %{"action" => "keep", "name" => "plan", "content" => "c"})
      list = resolve!("feed", %{"action" => "list"})

      # Sorted and once each, whatever order the answer names them in.
      answer = %{results: [], read_threads: ["thr_b", "thr_a", "thr_b"]}
      assert Policy.threads_of(search, {:ok, answer}, ctx) == ["thr_a", "thr_b"]
      assert Policy.threads_of(events, {:ok, answer}, ctx) == ["thr_a", "thr_b"]
      # The person's own read at the door names none.
      assert Policy.threads_of(search, {:ok, %{results: []}}, ctx) == []

      assert Policy.threads_of(file, {:ok, %{content: "x", read_threads: ["thr_a"]}}, ctx) ==
               ["thr_a"]

      assert Policy.threads_of(file, {:ok, %{content: "x"}}, ctx) == []

      assert Policy.threads_of(read, {:ok, %{content: "fn main() {}"}}, ctx) == []
      assert Policy.threads_of(write, {:ok, %{written: "components/x"}}, ctx) == []
      assert Policy.threads_of(note, {:ok, %{name: "plan", content: "fares rise"}}, ctx) == []
      assert Policy.threads_of(keep, {:ok, %{kept: "plan", replaced: false}}, ctx) == []

      # A listing answers each feed's binding, never a result's value.
      listing = %{
        feeds: [%{binding: "fb_1", feed: "fares", label: "Fares", revision: 3, at: nil}]
      }

      assert Policy.threads_of(list, {:ok, listing}, ctx) == []
    end

    test "a failure carries none, a refusal at admission or any other" do
      ctx = ctx()

      admission = %Prima.Refusal{
        class: :forbidden,
        reason: :denied,
        message: "no",
        stage: :admission
      }

      execution = %{admission | stage: :execution}
      search = %Binding.Call{kind: :catalog, tool: "thread", action: "search", args: %{}}
      namespace = resolve!("registry", %{"action" => "get_namespace", "slug" => "acme"})
      note = resolve!("notes", %{"action" => "read", "name" => "plan"})
      read = resolve!("source", %{"action" => "read", "path" => "components/x"})
      write = resolve!("source", %{"action" => "write", "path" => "components/x"})

      failures = [
        {:error, admission},
        {:error, execution},
        {:error, :not_found},
        {:error, "the registry said: buy now"}
      ]

      for call <- [search, namespace, note, read, write],
          failure <- failures,
          do: assert(Policy.threads_of(call, failure, ctx) == [], "#{call.tool}.#{call.action}")
    end
  end

  describe "group/1" do
    test "a write between reads runs alone, and the reads on either side do not join it" do
      read1 = item("files", %{"action" => "read", "path" => "a"})
      write = item("files", %{"action" => "write", "path" => "b", "content" => "x"})
      read2 = item("files", %{"action" => "read", "path" => "c"})

      assert [{:concurrent, [^read1]}, {:exclusive, ^write}, {:concurrent, [^read2]}] =
               Policy.group([read1, write, read2])
    end

    test "consecutive reads share a group and consecutive writes do not" do
      r1 = item("files", %{"action" => "read", "path" => "a"})
      r2 = item("files", %{"action" => "read", "path" => "b"})
      w1 = item("files", %{"action" => "write", "path" => "c", "content" => "x"})
      w2 = item("files", %{"action" => "write", "path" => "d", "content" => "y"})

      assert [{:concurrent, [^r1, ^r2]}, {:exclusive, ^w1}, {:exclusive, ^w2}] =
               Policy.group([r1, r2, w1, w2])
    end

    test "a write last, and a write first, each stand alone" do
      read = item("files", %{"action" => "read", "path" => "a"})
      write = item("files", %{"action" => "write", "path" => "b", "content" => "x"})

      assert [{:concurrent, [^read]}, {:exclusive, ^write}] = Policy.group([read, write])
      assert [{:exclusive, ^write}, {:concurrent, [^read]}] = Policy.group([write, read])
    end

    test "a launch stands alone and flushes the reads before it" do
      read = item("files", %{"action" => "read", "path" => "a"})
      launch = %{step: %{kind: "launch"}, call: {:ok, :launch}}

      assert [{:concurrent, [^read]}, {:launch, ^launch}] = Policy.group([read, launch])
    end
  end

  defp item(name, args) do
    {:ok, call} = Binding.resolve(name, args)
    %{step: %{kind: "tool"}, call: {:ok, call}}
  end

  defp ctx, do: Sanctum.TestContext.local()

  defp operation(tool, action) do
    {:ok, {_module, %{operations: operations}}} = Sanctum.Catalog.lookup(tool)
    Enum.find(operations, &(&1.action == action))
  end

  # What each answer is to the model that asked: a scroll read by name,
  # CYFR's own words, or what an outside source returned, which the
  # browser's page text and a program's output are though both are
  # catalog actions, as is any family not named.
  test "each call's answer is a scroll, CYFR's own, or outside" do
    rows = [
      {:scroll, "aqua.skill_get", %{"name" => "research"}},
      {:own, "aqua.get", %{"name" => "component-guide"}},
      {:own, "aqua.skill_list", %{}},
      {:own, "notes.read", %{"name" => "todo"}},
      {:own, "crew.ask", %{"member" => "planner", "task" => "t"}},
      {:own, "thread.post", %{"text" => "t"}},
      {:own, "threads.read", %{"thread" => "thr_1"}},
      {:own, "workspace.list", %{}},
      {:own, "schedule.list", %{}},
      {:own, "ui", %{"action" => "navigate"}},
      {:own, "request_setup.open", %{}},
      {:outside, "gh__search", %{"q" => "x"}},
      {:outside, "gh__resources", %{"method" => "list"}},
      {:outside, "files.read", %{"path" => "a"}},
      {:outside, "http.get", %{"url" => "https://example.com/"}},
      {:outside, "browser.read", %{}},
      {:outside, "program.start", %{"program" => "gh"}},
      {:outside, "execution.run", %{"reference" => "component:local.app:1.0.0"}},
      {:outside, "component.search", %{"query" => "x"}},
      {:outside, "vault.list", %{}}
    ]

    for {class, name, args} <- rows do
      assert Policy.answer_of(resolve!(name, args)) == class, name
    end
  end
end
