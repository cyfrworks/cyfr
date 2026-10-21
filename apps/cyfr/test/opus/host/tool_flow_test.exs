# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Host.ToolFlowTest do
  @moduledoc """
  A guest's tool calls and the run's source ledger (`Opus.Ledger`).

  A tool server is an exit: a run whose ledger holds a class its edge
  declares no flow of to `server:<name>` is refused before the call's
  arguments leave, and the refusal is recorded. Whatever a tool server
  answers is outside material named by the server, and the call's row and
  every ancestor hold it from the call's admission, before the call
  leaves: the server's answer and its error, the error's text included,
  reach the guest only after the ledger holds it, and a sibling that reads
  the call's record through `execution.logs` joins it too, so its next
  send is decided on it.
  """

  use ExUnit.Case, async: false

  require Ecto.Query

  alias Cyfr.Test.{AttemptFixtures, ScriptedWorker}
  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Prima.Source
  alias Prima.Test.AuthorityFixtures, as: Graph

  @math_wasm_path Path.expand("../../support/test_wasm/math.wasm", __DIR__)
  @formula "formula:local.tool-flow-formula"
  @target "reagent:local.tool-flow-target"
  @server "leak"
  @tool "leak:probe__echo"

  # The server process the row's calls reach, registered where the
  # supervisor finds one: under the row's configuration digest. Each call
  # tells the test what the calling tree's ledgers held while the call was
  # in flight, then answers as the test scripted.
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
      send(state.test, {:called, tool, args, ledgers(state.athanor_id)})
      {:reply, state.answer, state}
    end

    # The running call's row and its parent, read while the call is in
    # flight.
    defp ledgers(athanor_id) do
      actor = Prima.Actor.in_athanor(athanor_id)

      [row] =
        Arca.Repo.all(
          Ecto.Query.from(e in Arca.Schemas.Execution,
            where: e.kind == "tool_call" and e.status == "running"
          )
        )

      %{
        "call" => Arca.Execution.sources(actor, row.id),
        "parent_execution_id" => Arca.Execution.sources(actor, row.parent_execution_id)
      }
    end
  end

  defmodule Resolver do
    @moduledoc false
    def getaddr(_name, :inet), do: {:ok, {203, 0, 113, 10}}
    def getaddr(_name, _family), do: {:error, :nxdomain}
  end

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "tool_flow_#{System.unique_integer([:positive])}")
    previous = Application.get_env(:arca, :base_path)
    previous_resolver = Application.fetch_env(:cyfr, :egress_resolver)
    ctx = Sanctum.TestContext.local(:api)

    on_exit(fn ->
      case previous_resolver do
        {:ok, resolver} -> Application.put_env(:cyfr, :egress_resolver, resolver)
        :error -> Application.delete_env(:cyfr, :egress_resolver)
      end
    end)

    on_exit(fn ->
      Prima.Slots.forgive_unreaped(Opus.Slots, ctx.athanor_id)
      File.rm_rf!(test_path)

      if previous,
        do: Application.put_env(:arca, :base_path, previous),
        else: Application.delete_env(:arca, :base_path)
    end)

    Application.put_env(:arca, :base_path, test_path)
    wasm = File.read!(@math_wasm_path)

    for {name, type} <- [{"tool-flow-formula", "formula"}, {"tool-flow-target", "reagent"}] do
      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, wasm, %{name: name, version: "1.0.0", type: type})
    end

    {:ok, server} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: @server,
        transport: "stdio",
        url: nil,
        config_json:
          Jason.encode!(%{
            "transport" => "stdio",
            "backends" => [%{"name" => "probe", "command" => "node /probe/probe-backend.mjs"}]
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
  # server's tool, `execution.logs`, data/ storage and egress to one host,
  # with exactly `flows`.
  defp edge(server, flows) do
    {:ok, digest} = Sanctum.ToolServerDigest.from_server(server)

    %{
      "tools" => ["execution.logs", "notes.read", "component.categories", "component.search"],
      "tool_servers" => [
        %{"server_digest" => digest, "server_name" => @server, "tool_patterns" => ["probe__echo"]}
      ],
      "storage" => %{"paths" => ["data/"], "actions" => ["read"]},
      "egress" => %{
        "domains" => ["api.example.test"],
        "methods" => [],
        "schemes" => [],
        "private_ips" => []
      }
    }
    |> then(fn edge -> if flows == [], do: edge, else: Map.put(edge, "flows", flows) end)
  end

  defp authority(server, flows) do
    nodes = %{
      @formula => %{
        "limits" => Graph.limits_map(),
        "edges" => %{"@ingress" => edge(server, flows), @target => edge(server, flows)}
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

  defp ledger(fixture) do
    {:ok, sources} =
      Arca.Execution.sources(Prima.Actor.in_athanor(fixture.athanor_id), fixture.execution_id)

    sources
  end

  defp pin(fixture, url) do
    {:ok, args} = Prima.PinnedTarget.request_args(url, :fetch, nil)
    {:ok, request} = Prima.PinnedTarget.read_request(args)
    # This one pin resolves through the fixed resolver; every other pin
    # of the test resolves as the suite's do.
    previous = Application.fetch_env(:cyfr, :egress_resolver)
    Application.put_env(:cyfr, :egress_resolver, Resolver)

    try do
      Opus.Host.Egress.pin(AttemptFixtures.caller(fixture), request)
    after
      case previous do
        {:ok, resolver} -> Application.put_env(:cyfr, :egress_resolver, resolver)
        :error -> Application.delete_env(:cyfr, :egress_resolver)
      end
    end
  end

  defp denials(fixture) do
    {:ok, rows} = Arca.PolicyLog.list(Prima.Actor.in_athanor(fixture.athanor_id), limit: 100)
    Enum.filter(rows, &(&1.component_ref == fixture.component_ref))
  end

  test "a server's error reaches the guest only after outside(server) is on the run and its ancestors",
       %{ctx: ctx, server: server} do
    stub!(ctx, server, {:error, "upstream says sentinel-41c7"})
    fixture = formula!(ctx, authority(server, []))

    assert %{"error" => "guest_error", "message" => message} =
             tool(fixture, @tool, %{"q" => "x"})

    assert message =~ "sentinel-41c7"

    # While the call was in flight, before any answer existed, the caller
    # already held the server's provenance.
    assert_received {:called, "probe__echo", _args, ledgers}
    assert {:ok, call} = ledgers["call"]
    assert Source.outside(@server) in call
    assert {:ok, during} = ledgers["parent_execution_id"]
    assert Source.outside(@server) in during
    assert Source.outside(@server) in ledger(fixture)
  end

  test "a run that read a class its edge lets flow nowhere is refused the server before anything leaves, and the refusal is recorded",
       %{ctx: ctx, server: server} do
    stub!(ctx, server, {:ok, %{"content" => []}})
    fixture = formula!(ctx, authority(server, []))
    :ok = Arca.put(Sanctum.Context.actor(fixture.ctx), ["data", "secret.txt"], "restricted")

    assert %{"ok" => _} =
             AttemptFixtures.call(fixture, "storage", %{
               "action" => "read",
               "path" => "data/secret.txt"
             })

    assert %{"error" => "guest_error", "type" => "flow_blocked", "message" => message} =
             tool(fixture, @tool, %{"q" => "restricted"})

    assert message =~ "server:#{@server}"
    refute_received {:called, _, _, _}
    assert [%{decision: "denied", decision_reason: "tool: " <> _}] = denials(fixture)
  end

  test "with flows of what it read to the server, the same call is made",
       %{ctx: ctx, server: server} do
    stub!(ctx, server, {:ok, %{"content" => []}})

    flows = [
      %{"from" => "files_by_grant", "to" => "server:#{@server}"},
      %{"from" => "outside", "to" => "server:#{@server}"}
    ]

    fixture = formula!(ctx, authority(server, flows))
    :ok = Arca.put(Sanctum.Context.actor(fixture.ctx), ["data", "secret.txt"], "restricted")

    assert %{"ok" => _} =
             AttemptFixtures.call(fixture, "storage", %{
               "action" => "read",
               "path" => "data/secret.txt"
             })

    assert %{"ok" => _} = tool(fixture, @tool, %{"q" => "restricted"})
    assert_received {:called, "probe__echo", _args, _ledgers}
  end

  test "a sibling that reads a server call's record joins its provenance, and its next send is decided on it",
       %{ctx: ctx, server: server} do
    stub!(ctx, server, {:error, "upstream says sentinel-9d2e"})
    fixture = formula!(ctx, authority(server, []))

    # The reader is admitted before the call, so it inherits nothing of it.
    reader = admit_child!(fixture)
    caller = admit_child!(fixture)

    assert %{"error" => "guest_error"} = tool(caller, @tool, %{"q" => "x"})
    assert_received {:called, "probe__echo", _args, _ledgers}
    assert Source.outside(@server) in ledger(caller)
    assert ledger(reader) == []

    [call_row] =
      Arca.Repo.all(
        Ecto.Query.from(e in Arca.Schemas.Execution,
          where: e.parent_execution_id == ^caller.execution_id and e.kind == "tool_call"
        )
      )

    # What the record carries, read as the in-chain plane reads it: the
    # call's own ledger, the server's provenance among it.
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

    assert Source.outside(@server) in Prima.Operation.answer_sources(
             op,
             Sanctum.Context.actor(ctx),
             answer
           )

    # A guest reads no execution record (the guest plane is refused the
    # read), and the refusal still joins every class the read may answer:
    # the reader's next send is decided on it.
    assert %{"error" => "guest_error"} =
             tool(reader, "execution", %{"action" => "logs", "execution_id" => call_row.id})

    assert Source.outside(nil) in ledger(reader)
    assert {:error, :flow} = pin(reader, "https://api.example.test/send")
  end

  test "a note's own provenance reaches the guest that reads it: a note kept with vault-disclosed material is never merely filed",
       %{ctx: ctx, server: server} do
    {:ok, _} =
      Aqua.Notes.keep(ctx, "key-material", "the key is k",
        sources: [Source.new(:vault_disclosed)]
      )

    fixture = formula!(ctx, authority(server, []))

    assert %{"ok" => _} = tool(fixture, "notes", %{"action" => "read", "name" => "key-material"})

    assert Source.new(:filed) in ledger(fixture)
    assert Source.new(:vault_disclosed) in ledger(fixture)
  end

  test "a catalog read of the athanor's own records carries nothing; one that reaches outside is outside, whatever it answers",
       %{ctx: ctx, server: server} do
    fixture = formula!(ctx, authority(server, []))
    assert %{"ok" => _} = tool(fixture, "component", %{"action" => "categories"})
    assert ledger(fixture) == []

    _answered =
      tool(fixture, "component", %{
        "action" => "search",
        "query" => "weather",
        "source" => "local"
      })

    assert ledger(fixture) == [Source.outside(nil)]
  end

  test "a child's restricted read is its parent's before the read returns, outlives the child, and decides the parent's next send",
       %{ctx: ctx, server: server} do
    fixture = formula!(ctx, authority(server, []))
    child = admit_child!(fixture)
    :ok = Arca.put(Sanctum.Context.actor(fixture.ctx), ["data", "secret.txt"], "restricted")

    assert ledger(fixture) == []

    assert %{"ok" => %{"content" => _}} =
             AttemptFixtures.call(child, "storage", %{
               "action" => "read",
               "path" => "data/secret.txt"
             })

    # The parent holds it now, before the child has handed it anything.
    assert Source.new(:files_by_grant) in ledger(fixture)

    # The child ends; what its read put in the parent's ledger stays.
    assert %{"ok" => _} =
             AttemptFixtures.call(child, "fail", %{
               "outcome" => AttemptFixtures.outcome(child, "failed", %{"error" => "gone"})
             })

    assert Source.new(:files_by_grant) in ledger(fixture)
    assert {:error, :flow} = pin(fixture, "https://api.example.test/send")
  end
end
