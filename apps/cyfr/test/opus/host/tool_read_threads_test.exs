# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Host.ToolReadThreadsTest do
  @moduledoc """
  A guest's tool calls and the run's read threads.

  A tool server's call is decided by the grant alone, whatever the run
  has read, and its answer joins no thread. A catalog action whose answer
  carries a thread's posts names those threads (`Prima.Operation`'s
  `threads`), and the run and every ancestor hold them before the answer
  reaches the guest; an answer whose threads cannot be joined is refused.
  A call's record, read through `execution.logs`, carries the call's
  read threads. A child's read is its parent's before the read returns,
  and outlives the child.
  """

  use ExUnit.Case, async: false

  require Ecto.Query

  alias Cyfr.Test.{AttemptFixtures, ScriptedWorker}
  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Prima.Test.AuthorityFixtures, as: Graph

  @formula "formula:local.tool-flow-formula"
  @target "reagent:local.tool-flow-target"
  @server "leak"
  @tool "leak:echo"

  # A catalog read whose answer carries the posts of the threads it names
  # (`"threads"`). A read that names a run under `"gone"` purges that
  # run's row first, so its threads cannot be joined.
  defmodule ThreadProbe do
    @moduledoc false
    @behaviour Prima.Provider

    alias Prima.{Arg, Operation}

    @impl true
    def service, do: "thread-probe"

    @impl true
    def tools do
      [
        Operation.tool([
          Operation.new(
            "thread_probe",
            "read",
            "Read posts of threads",
            [
              Arg.new("threads", {:array, Arg.new(nil, :string)}, required: true),
              Arg.new("gone", :string)
            ],
            kind: :read,
            planes: [:in_chain],
            threads: {__MODULE__, :read_threads}
          )
        ])
      ]
    end

    @impl true
    def handle("thread_probe", ctx, %{"action" => "read", "threads" => threads} = args) do
      with id when is_binary(id) <- args["gone"] do
        actor = Sanctum.Context.actor(ctx)
        {:ok, _released} = Arca.ExecutionPayloads.release(actor, [id])
        {:ok, 1} = Arca.Execution.delete_ids([id], athanor_id: ctx.athanor_id)
      end

      {:ok, %{"threads" => threads}}
    end

    def read_threads(_actor, %{"threads" => threads}), do: threads
    def read_threads(_actor, _answer), do: []
  end

  # The server process the row's calls reach, registered where the
  # supervisor finds one: under the row's configuration digest. Each call
  # tells the test it was made, then answers as the test scripted.
  defmodule ServerStub do
    use GenServer

    def start(ctx, server, test, answer) do
      config = Emissary.External.Servers.server_config(server, ctx)
      digest = Emissary.External.ServerSupervisor.config_digest(config)
      GenServer.start(__MODULE__, {server.name, ctx.athanor_id, digest, test, answer})
    end

    @impl true
    def init({name, athanor_id, digest, test, answer}) do
      {:ok, _} =
        Registry.register(Emissary.External.ServerRegistry, {name, athanor_id}, digest)

      {:ok, %{athanor_id: athanor_id, test: test, answer: answer}}
    end

    @impl true
    def handle_call({:call_tool, tool, args}, _from, state) do
      send(state.test, {:called, tool, args})
      {:reply, state.answer, state}
    end
  end

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path =
      Path.join(System.tmp_dir!(), "tool_read_threads_#{System.unique_integer([:positive])}")

    previous = Application.get_env(:arca, :base_path)
    ctx = Sanctum.TestContext.local(:api)

    on_exit(fn ->
      Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id)
      File.rm_rf!(test_path)

      if previous,
        do: Application.put_env(:arca, :base_path, previous),
        else: Application.delete_env(:arca, :base_path)
    end)

    Application.put_env(:arca, :base_path, test_path)

    for {name, type} <- [{"tool-flow-formula", "formula"}, {"tool-flow-target", "reagent"}] do
      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(type), %{
          name: name,
          version: "1.0.0",
          type: type
        })
    end

    {:ok, server} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: @server,
        transport: "program",
        mark: "mcp",
        url: nil,
        config_json:
          Jason.encode!(%{
            "transport" => "program",
            "mark" => "mcp",
            "command" => "node /probe/probe-backend.mjs",
            "env" => %{}
          })
      })

    Cyfr.Test.Sandbox.stop_work_on_exit()
    start_supervised!({ScriptedWorker, ref: "reagent:local.unscripted", script: []})

    {:ok, ctx: ctx, server: server}
  end

  defp stub!(ctx, server, answer) do
    {:ok, stub} = ServerStub.start(ctx, server, self(), answer)
    on_exit(fn -> Process.exit(stub, :kill) end)
    stub
  end

  # The edge a run calls the server and reads executions under: the
  # server's tool, `execution.logs`, the thread probe, data/ storage and
  # egress to one host.
  defp edge(server) do
    {:ok, digest} = Sanctum.ToolServerDigest.from_server(server)
    {:ok, record} = Sanctum.ToolServerDigest.recorded(server)

    %{
      "tools" => ["execution.logs", "thread_probe.read"],
      "tool_servers" => [
        %{
          "server_digest" => digest,
          "server_name" => @server,
          "tool_patterns" => ["echo"],
          "record" => record
        }
      ],
      "storage" => %{"paths" => ["data/"], "actions" => ["read"]},
      "egress" => %{
        "domains" => ["api.example.test"],
        "methods" => [],
        "schemes" => [],
        "private_ips" => []
      }
    }
  end

  defp authority(server) do
    nodes = %{
      @formula => %{
        "limits" => Graph.limits_map(),
        "edges" => %{"@ingress" => edge(server), @target => edge(server)}
      },
      @target => %{"limits" => Graph.limits_map(), "edges" => %{}}
    }

    {:ok, blob} = Blob.parse(%{"canonical" => "jcs-1", "nodes" => nodes})

    {:ok, authority} =
      Authority.root(
        %{
          profile_id: "prof-tool-flow",
          consent_id: "consent-tool-flow",
          source_ref: @formula,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{@formula => Prima.Digest.sha256("tool-flow-formula")}
        },
        blob,
        ceiling: Graph.ceiling()
      )

    authority
  end

  defp formula!(ctx, authority) do
    AttemptFixtures.attached!(
      ctx: ctx,
      authority: authority,
      component_ref: "#{@formula}:1.0.0",
      component_type: :formula,
      worker: ScriptedWorker.endpoint(),
      reservation: true
    )
  end

  defp tool(fixture, name, args) do
    AttemptFixtures.call(fixture, "tool_call", %{
      "name" => name,
      "args" => args,
      "guest_fn" => "call"
    })
  end

  defp admit_child!(fixture) do
    assert %{"ok" => answer} =
             AttemptFixtures.call(fixture, "admit_child", %{
               "reference" => "#{@target}:1.0.0",
               "input" => %{},
               "guest_fn" => "spawn",
               "child_key" => "ck_#{System.unique_integer([:positive])}"
             })

    assert %{"assignment" => token, "attempt_keys" => sealed} = answer
    {:ok, keys} = Prima.WorkerAuth.open_attempt_keys(fixture.keys.seal, sealed)
    {:ok, assignment} = Prima.Assignment.read(token)

    keys.attempt
    |> Map.merge(%{
      boot: fixture.boot,
      runner: fixture.runner,
      member: assignment.member,
      keys: keys,
      call_key: keys.call
    })
  end

  defp read_threads(fixture) do
    {:ok, threads} =
      Arca.Execution.read_threads(
        Prima.Actor.in_athanor(fixture.athanor_id),
        fixture.execution_id
      )

    threads
  end

  defp join!(fixture, threads) do
    :ok =
      Arca.Execution.join_threads(
        Prima.Actor.in_athanor(fixture.athanor_id),
        fixture.execution_id,
        threads
      )
  end

  defp denials(fixture) do
    {:ok, rows} = Arca.PolicyLog.list(Prima.Actor.in_athanor(fixture.athanor_id), limit: 100)
    Enum.filter(rows, &(&1.component_ref == fixture.component_ref))
  end

  test "a run that read a thread calls the server, nothing of what it read is checked, and the server's answer joins nothing",
       %{ctx: ctx, server: server} do
    stub!(ctx, server, {:ok, %{"content" => []}})
    fixture = formula!(ctx, authority(server))

    :ok =
      Arca.put(Sanctum.Context.actor(fixture.ctx), ["data", "secret.txt"], "restricted",
        threads: ["thr_secret"]
      )

    assert %{"ok" => _} =
             AttemptFixtures.call(fixture, "storage", %{
               "action" => "read",
               "path" => "data/secret.txt"
             })

    assert read_threads(fixture) == ["thr_secret"]
    assert %{"ok" => _} = tool(fixture, @tool, %{"q" => "restricted"})
    assert_received {:called, "echo", %{"q" => "restricted"}}
    assert denials(fixture) == []
    assert read_threads(fixture) == ["thr_secret"]
  end

  test "a server call's record carries the call's read threads to the one that reads it",
       %{ctx: ctx, server: server} do
    stub!(ctx, server, {:error, "upstream says sentinel-9d2e"})
    fixture = formula!(ctx, authority(server))

    # The reader is admitted before the caller reads a thread, so it
    # inherits nothing of it.
    reader = admit_child!(fixture)
    caller = admit_child!(fixture)
    join!(caller, ["thr_caller"])

    assert %{"error" => "guest_error", "message" => message} = tool(caller, @tool, %{"q" => "x"})
    assert message =~ "sentinel-9d2e"
    assert_received {:called, "echo", _args}
    assert read_threads(caller) == ["thr_caller"]
    assert read_threads(reader) == []

    [call_row] =
      Arca.Repo.all(
        Ecto.Query.from(e in Arca.Schemas.Execution,
          where: e.parent_execution_id == ^caller.execution_id and e.kind == "tool_call"
        )
      )

    # What the record carries, read as the in-chain plane reads it: the
    # call's own read threads, its caller's from its admission.
    {:ok, logs} = Sanctum.Catalog.lookup("execution")
    {_module, %{operations: operations}} = logs
    op = Enum.find(operations, &(&1.action == "logs"))

    {:ok, answer} =
      Opus.Provider.handle("execution", ctx, %{
        "action" => "logs",
        "execution_id" => call_row.id,
        "root_execution_id" => fixture.execution_id
      })

    assert answer.error =~ "sentinel-9d2e"

    assert Prima.Operation.read_threads(op, Sanctum.Context.actor(ctx), {:ok, answer}) ==
             ["thr_caller"]

    # A guest reads no execution record (the guest plane is refused the
    # read), and the refusal joins nothing.
    assert %{"error" => "guest_error"} =
             tool(reader, "execution", %{"action" => "logs", "execution_id" => call_row.id})

    assert read_threads(reader) == []
  end

  test "a catalog read's answer reaches the guest once the run and its ancestors hold the threads it names",
       %{ctx: ctx, server: server} do
    Sanctum.Catalog.with_providers([ThreadProbe], fn ->
      fixture = formula!(ctx, authority(server))
      child = admit_child!(fixture)

      assert %{"ok" => %{"threads" => ["thr_b", "thr_a"]}} =
               tool(child, "thread_probe", %{"action" => "read", "threads" => ["thr_b", "thr_a"]})

      assert read_threads(child) == ["thr_a", "thr_b"]
      assert read_threads(fixture) == ["thr_a", "thr_b"]

      # An answer that names no thread joins none.
      assert %{"ok" => %{"threads" => []}} =
               tool(fixture, "thread_probe", %{"action" => "read", "threads" => []})

      assert read_threads(fixture) == ["thr_a", "thr_b"]
    end)
  end

  @tag :capture_log
  test "a catalog read's answer whose threads cannot be joined is refused as unavailable",
       %{ctx: ctx, server: server} do
    Sanctum.Catalog.with_providers([ThreadProbe], fn ->
      fixture = formula!(ctx, authority(server))
      child = admit_child!(fixture)

      assert %{"error" => "unavailable"} =
               tool(child, "thread_probe", %{
                 "action" => "read",
                 "threads" => ["thr_gone"],
                 "gone" => child.execution_id
               })

      assert read_threads(fixture) == []
    end)
  end

  test "a child's read is its parent's before the read returns, and outlives the child",
       %{ctx: ctx, server: server} do
    fixture = formula!(ctx, authority(server))
    child = admit_child!(fixture)

    :ok =
      Arca.put(Sanctum.Context.actor(fixture.ctx), ["data", "secret.txt"], "restricted",
        threads: ["thr_secret"]
      )

    assert read_threads(fixture) == []

    assert %{"ok" => %{"content" => _}} =
             AttemptFixtures.call(child, "storage", %{
               "action" => "read",
               "path" => "data/secret.txt"
             })

    # The parent holds it now, before the child has handed it anything.
    assert read_threads(fixture) == ["thr_secret"]

    # The child ends; what its read put in the parent's read threads stays.
    assert %{"ok" => _} =
             AttemptFixtures.call(child, "fail", %{
               "outcome" => AttemptFixtures.outcome(child, "failed", %{"error" => "gone"})
             })

    assert read_threads(fixture) == ["thr_secret"]
  end
end
