# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.PolicyTest do
  @moduledoc """
  A call runs or is refused by its member's offered set and mode, and is
  never asked: read-only runs a read, the `ui` event and the turn's own
  start of its program brain, and refuses every other call with one
  sentence; auto runs every offered call. A call not offered, or outside
  a job's narrowing, is refused in either mode. Reads overlap and nothing
  else does.
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
    {"a file read", "files", %{"action" => "read", "path" => "a"}, :read},
    {"a notes read", "notes", %{"action" => "list"}, :read},
    {"a web read", "http", %{"action" => "get", "url" => "https://example.com/"}, :read},
    {"a thread search", "thread", %{"action" => "search", "query" => "q"}, :read},
    {"the crew's list", "crew", %{"action" => "list"}, :read},
    {"the browser's read", "browser", %{"action" => "read"}, :read},
    {"the browser's status", "browser", %{"action" => "status"}, :read},
    {"a file write", "files", %{"action" => "write", "path" => "a", "content" => "b"}, :other},
    {"a file delete", "files", %{"action" => "delete", "path" => "a"}, :other},
    {"a web post", "http", %{"action" => "post", "url" => "https://example.com/"}, :other},
    {"a launch", "execution",
     %{"action" => "run", "reference" => "reagent:local.app:1.0.0", "input" => %{}}, :launch},
    {"a model's program start", "program", %{"action" => "start", "program" => "srv_1"}, :other},
    {"the browser's open", "browser", %{"action" => "open", "url" => "https://example.com/"},
     :other},
    {"the browser's click", "browser", %{"action" => "click", "ref" => "e1"}, :other},
    {"the browser's close", "browser", %{"action" => "close"}, :other},
    {"the browser's turn off", "browser", %{"action" => "turn_off"}, :other},
    {"a kept note", "notes", %{"action" => "keep", "name" => "n", "content" => "c"}, :other},
    {"the pinned page", "notes", %{"action" => "pin", "content" => "c"}, :other},
    {"a workspace's notes", "notes", %{"action" => "workspace", "content" => "c"}, :other},
    {"a forgotten note", "notes", %{"action" => "forget", "name" => "n"}, :other},
    {"a workspace opened", "workspace", %{"action" => "open", "title" => "t", "ask" => "a"},
     :other},
    {"a workspace report", "workspace",
     %{"action" => "report", "outcome" => "done", "summary" => "s"}, :other},
    {"a hand-off", "crew", %{"action" => "ask", "member" => "explorer", "task" => "t"}, :other},
    {"a post", "thread", %{"action" => "post", "content" => "c"}, :other},
    {"an outside server's tool", "github__search", %{"q" => "x"}, :other}
  ]

  defp offered(rows) do
    keys =
      for {_label, name, args, _row} <- rows do
        case resolve!(name, args) do
          %{kind: :external, tool: tool} -> tool
          %{tool: tool, action: action} -> "#{tool}.#{action}"
        end
      end

    Aqua.Offered.resolve(keys, {:ok, true})
  end

  @opts [title: "Aqua"]

  test "each row of the table in both modes: read-only runs reads alone, auto runs every one" do
    offered = offered(@rows)

    for {label, name, args, row} <- @rows do
      call = resolve!(name, args)
      read_only = Policy.decide(call, offered, "read-only", @opts)
      auto = Policy.decide(call, offered, "auto", @opts)

      case row do
        :read ->
          assert read_only == :run, label
          assert auto == :run, label

        :launch ->
          assert read_only == {:read_only, Policy.read_only_sentence("Aqua")}, label

          assert auto ==
                   {:run, %{call: %{action: call.action, args: call.args}, account: nil}},
                 label

        :other ->
          assert read_only == {:read_only, Policy.read_only_sentence("Aqua")}, label
          assert auto == :run, label
      end
    end
  end

  test "the sentence names the member by its title and the one way to let it" do
    assert Policy.read_only_sentence("Explorer") ==
             "Explorer is read-only, so it refused a step that does more than read. " <>
               "To let it, switch Explorer to auto on the Aqua page."

    write = resolve!("files", %{"action" => "write", "path" => "a", "content" => "b"})

    assert {:read_only, sentence} =
             Policy.decide(write, offered(@rows), "read-only", title: "Explorer")

    assert sentence == Policy.read_only_sentence("Explorer")
  end

  test "what only shows the person something runs in either mode, offered or not" do
    for call <- [resolve!("ui", %{"kind" => "ui.navigate"}), resolve!("request_setup.open", %{})],
        mode <- ["read-only", "auto"] do
      assert :run = Policy.decide(call, %{}, mode, @opts)
    end
  end

  test "the turn's own start of its program brain runs in either mode, unnarrowed" do
    start = resolve!("program", %{"action" => "start", "program" => "srv_1", "epoch" => 1})

    for mode <- ["read-only", "auto"] do
      assert :run = Policy.decide(start, %{}, mode, host_start: true, narrowed: nil)
    end

    # A model's start of a program is a call like any other.
    assert {:deny, _} = Policy.decide(start, %{}, "auto", @opts)
  end

  test "a call not offered is refused in either mode, a browser action the setting turned off in the browser's words" do
    offered = Aqua.Offered.resolve(["files.read", "browser.open"], {:ok, false})
    assert offered == %{"files.read" => "offered", "browser.open" => "off"}

    write = resolve!("files", %{"action" => "write", "path" => "a", "content" => "b"})
    open = resolve!("browser", %{"action" => "open", "url" => "https://example.com/"})
    tool = resolve!("github__search", %{})

    for mode <- ["read-only", "auto"] do
      assert {:deny, "files.write is not among the tools Aqua is offered"} =
               Policy.decide(write, offered, mode, @opts)

      assert {:deny, sentence} = Policy.decide(open, offered, mode, @opts)
      assert sentence == Aqua.Providers.Browser.turned_off()

      assert {:deny, "github:search is not among the tools Aqua is offered"} =
               Policy.decide(tool, offered, mode, @opts)
    end
  end

  test "a job narrowed to some tools refuses every other call, whatever its kind and mode" do
    offered = offered(@rows)
    narrowed = Keyword.put(@opts, :narrowed, ["files.read"])

    assert :run =
             Policy.decide(
               resolve!("files", %{"action" => "read", "path" => "a"}),
               offered,
               "auto",
               narrowed
             )

    for {name, args} <- [
          {"files", %{"action" => "write", "path" => "a"}},
          {"notes", %{"action" => "keep"}},
          {"github__search", %{}},
          {"execution", %{"action" => "run", "reference" => "formula:local.demo:1.0.0"}}
        ],
        mode <- ["read-only", "auto"] do
      assert {:deny, sentence} = Policy.decide(resolve!(name, args), offered, mode, narrowed)
      assert sentence =~ "outside the tools this job was narrowed to"
    end

    # Narrowed to a bare tool, the job runs every action of it and nothing else.
    by_tool = Keyword.put(@opts, :narrowed, ["notes"])

    for args <- [%{"action" => "keep", "name" => "n", "content" => "c"}, %{"action" => "list"}] do
      assert Policy.decide(resolve!("notes", args), offered, "auto", by_tool) == :run
    end

    assert Policy.decide(
             resolve!("files", %{"action" => "read", "path" => "a"}),
             offered,
             "auto",
             by_tool
           ) == {:deny, "files.read is outside the tools this job was narrowed to"}

    assert :run =
             Policy.decide(
               resolve!("github__search", %{"q" => "x"}),
               offered,
               "auto",
               Keyword.put(@opts, :narrowed, ["github:search"])
             )

    assert :run =
             Policy.decide(
               resolve!("ui", %{"kind" => "ui.navigate"}),
               offered,
               "read-only",
               narrowed
             )

    assert Policy.within?(resolve!("request_setup.open", %{}), ["files.read"])
  end

  test "a launch naming no component is refused before the mode" do
    bad = resolve!("execution", %{"action" => "run", "reference" => "not a ref"})
    offered = Aqua.Offered.resolve(["execution.run"], {:ok, true})

    for mode <- ["read-only", "auto"],
        do: assert({:refuse, _} = Policy.decide(bad, offered, mode, @opts))
  end

  test "a launch's decision is its call and its account, and binds nothing of what the turn read" do
    args = %{"action" => "run", "reference" => "reagent:local.app:1.0.0", "input" => %{}}
    launch = resolve!("execution", args)
    offered = Aqua.Offered.resolve(["execution.run"], {:ok, true})

    assert launch.action == "run"

    assert Policy.decide(launch, offered, "auto", title: "Aqua") ==
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
      answer = %{content: "an answer"}

      for {tool, {_module, %{operations: operations}}} <- Sanctum.Catalog.operations(),
          %Prima.Operation{action: action} = operation <- operations do
        call = %Binding.Call{kind: :catalog, tool: tool, action: action, args: %{}}

        assert Policy.threads_of(call, {:ok, answer}, ctx) ==
                 Prima.Operation.read_threads(operation, actor, {:ok, answer}),
               "#{tool}.#{action}"
      end
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

      for call <- [search, namespace, note, read],
          failure <- [{:error, admission}, {:error, execution}, {:error, :not_found}],
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
end
