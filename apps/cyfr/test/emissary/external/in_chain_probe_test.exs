# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.External.InChainProbeTest do
  @moduledoc """
  The in-chain probe the bridge image suite evaluates in the running
  release (`tests/bridge-image/e2e.test.mjs`: `callTool/3` on the
  `in_chain` plane, and the stored rows it reads back), run step for step
  against this application: the caller established from a session token,
  a root execution admitted under the grant its estate stands at, a stdio
  server's tool called in-chain under the root's lineage, the root closed
  with the call's outcome, and the execution rows and payloads read as the
  suite reads them. The server process is a stub that answers as the
  bridge does once it has masked the backend's credential; the masking
  itself is the image suite's to prove. A call that names no parent has no
  grant to inherit and is refused.
  """

  use ExUnit.Case, async: false

  alias Emissary.External.Proxy

  @tool "leak:probe__echo_env"
  @arguments %{"name" => "PROBE_SECRET", "stderr" => true}

  # The server process a stdio row's calls reach, registered where the
  # supervisor finds one: under the row's configuration digest. It answers
  # every call with the bridge's masked `echo_env` and tells the test.
  defmodule BackendStub do
    use GenServer

    def start(ctx, server, test) do
      config = Emissary.External.Servers.server_config(server, ctx)
      digest = Emissary.External.ServerSupervisor.config_digest(config)
      GenServer.start(__MODULE__, {server.name, ctx.athanor_id, digest, test})
    end

    @impl true
    def init({name, athanor_id, digest, test}) do
      {:ok, _} =
        Registry.register(Emissary.External.ServerRegistry, {name, athanor_id}, digest)

      {:ok, test}
    end

    @impl true
    def handle_call({:call_tool, tool, args}, _from, test) do
      send(test, {:called, tool, args})
      text = Jason.encode!(%{"value" => "[REDACTED]"})
      {:reply, {:ok, %{"content" => [%{"type" => "text", "text" => text}]}}, test}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # A seated member with a session, as the suite's sign-in leaves it.
    issuer = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
    {:ok, session} = Sanctum.Session.create(issuer)

    {:ok, server} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(issuer), %{
        name: "leak",
        transport: "stdio",
        url: nil,
        config_json:
          Jason.encode!(%{
            "transport" => "stdio",
            "console" => true,
            "backends" => [
              %{
                "name" => "probe",
                "command" => "node /probe/probe-backend.mjs",
                "env" => %{"PROBE_SECRET" => "vault:probe-canary"}
              }
            ]
          })
      })

    {:ok, stub} = BackendStub.start(issuer, server, self())
    on_exit(fn -> Process.exit(stub, :kill) end)
    {:ok, token: session.token}
  end

  test "an in-chain call under an admitted root is kept as the root's child with its payloads",
       %{token: token} do
    {root_id, answer} = in_chain(token, @tool, @arguments)

    assert %{"ok" => %{"content" => [%{"text" => text}]}} = answer
    assert Jason.decode!(text) == %{"value" => "[REDACTED]"}
    assert_received {:called, "probe__echo_env", %{"name" => "PROBE_SECRET"}}

    stored = stored(token)

    execution =
      Enum.find(stored["executions"], &(&1["kind"] == "tool_call" and &1["reference"] == @tool))

    assert execution, "the in-chain call left no execution"
    payloads = Enum.filter(stored["payloads"], &(&1["execution_id"] == execution["id"]))
    result = Enum.find(payloads, &(&1["kind"] == "result"))
    assert result["bytes_read"] =~ "[REDACTED]"

    # The input kept is what the chain sent, never the lineage it was stamped with.
    input = Enum.find(payloads, &(&1["kind"] == "input"))
    assert Jason.decode!(input["bytes_read"]) == @arguments

    # The call is the root's child and ran under the grant the root's
    # attempt stores; the root closed with the call's answer.
    assert %{parent_execution_id: ^root_id, root_execution_id: ^root_id, status: "completed"} =
             Arca.Repo.get(Arca.Schemas.Execution, execution["id"])

    assert %{kind: "component", status: "completed"} =
             Arca.Repo.get(Arca.Schemas.Execution, root_id)

    {:ok, ctx} = Sanctum.Caller.establish(token)
    actor = Sanctum.Context.actor(ctx)
    assert {:ok, grant} = Sanctum.ExecutionStanding.capture(ctx)
    assert {:ok, ^grant} = Arca.ExecutionAttempts.grant(actor, root_id)
    assert {:ok, ^grant} = Arca.ExecutionAttempts.grant(actor, execution["id"])
  end

  test "an in-chain call that names no parent is refused missing_grant and admits nothing",
       %{token: token} do
    {:ok, ctx} = Sanctum.Caller.establish(token)

    assert {:error, %Prima.Refusal{reason: :missing_grant, message: message}} =
             Proxy.try_handle(@tool, ctx, @arguments, :in_chain)

    assert message =~ "Call to probe__echo_env on server 'leak' not admitted: "
    refute_received {:called, _, _}
    assert %{"executions" => [], "payloads" => []} = stored(token)
  end

  # `callTool(name, arguments, "in_chain")`'s snippet, step for step; the
  # root's id is answered beside it for the assertions.
  defp in_chain(token, name, arguments) do
    args = %{"token" => token, "name" => name, "arguments" => arguments, "plane" => "in_chain"}
    {:ok, ctx} = Sanctum.Caller.establish(args["token"])

    {:ok, grant} = Sanctum.ExecutionStanding.capture(ctx)

    root =
      Crucible.Record.new(ctx, "formula:local.bridge-e2e-chain:0.1.0", %{},
        component_type: :formula,
        grant: grant
      )

    :ok = Crucible.Record.write_started(root)
    lineage = %{"parent_execution_id" => root.id, "root_execution_id" => root.id}

    reply =
      Emissary.External.Proxy.try_handle(
        args["name"],
        ctx,
        Map.merge(args["arguments"], lineage),
        :in_chain
      )

    :ok =
      case reply do
        {:ok, answer} ->
          root |> Crucible.Record.complete(answer) |> Crucible.Record.write_completed()

        {:error, reason} ->
          root |> Crucible.Record.fail(Grimoire.render(reason)) |> Crucible.Record.write_failed()
      end

    answer =
      case reply do
        {:ok, result} -> %{ok: result}
        {:error, reason} when is_binary(reason) -> %{error: reason}
        {:error, reason} -> %{error: inspect(reason)}
      end

    {root.id, answer |> Jason.encode!() |> Jason.decode!()}
  end

  # The suite's stored-rows snippet: the request log, every payload read
  # back through the store's door with the caller's actor, and the
  # execution rows, as the JSON the suite receives.
  defp stored(token) do
    rows = fn sql ->
      result = Arca.Repo.query!(sql)
      Enum.map(result.rows, fn row -> result.columns |> Enum.zip(row) |> Map.new() end)
    end

    {:ok, ctx} = Sanctum.Caller.establish(token)

    payloads =
      for row <- rows.("SELECT * FROM execution_payloads") do
        {:ok, _row, bytes} =
          Arca.ExecutionPayloads.get(
            Sanctum.Context.actor(ctx),
            row["execution_id"],
            row["kind"]
          )

        Map.put(row, "bytes_read", bytes)
      end

    %{
      request_log: rows.("SELECT * FROM mcp_logs"),
      payloads: payloads,
      executions: rows.("SELECT id, kind, reference FROM executions")
    }
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
