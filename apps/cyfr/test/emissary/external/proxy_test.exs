# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.External.ProxyTest do
  use ExUnit.Case, async: false

  alias Emissary.External.Proxy

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    ctx = Sanctum.TestContext.local()
    {:ok, ctx: ctx}
  end

  # An in-chain call comes from a real execution: the catalog stamps its
  # row and the attempt that owns it into the call's arguments, and the
  # call's own row inherits that attempt's grant.
  defp chained(ctx, args) do
    lineage = Cyfr.Test.AttemptFixtures.lineage!(ctx)

    Map.merge(args, %{
      "parent_execution_id" => lineage.parent_execution_id,
      "root_execution_id" => lineage.root_execution_id,
      "attempt" => lineage.attempt
    })
  end

  # The outbound calls' own rows, apart from the chains that made them.
  defp tool_calls do
    import Ecto.Query
    Arca.Repo.all(from(e in Arca.Schemas.Execution, where: e.kind == "tool_call"))
  end

  describe "try_handle/4" do
    test "returns :not_external for non-namespaced tools", %{ctx: ctx} do
      assert {:error, :not_external} =
               Proxy.try_handle("regular_tool", ctx, chained(ctx, %{}), :in_chain)
    end

    test "returns :not_external when server doesn't exist", %{ctx: ctx} do
      assert {:error, :not_external} =
               Proxy.try_handle(
                 "nonexistent:some_tool",
                 ctx,
                 chained(ctx, %{}),
                 :in_chain
               )
    end

    test "returns error for disabled server", %{ctx: ctx} do
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "disabled-srv",
        url: "https://x.com/mcp",
        enabled: false
      })

      assert {:error, "Server 'disabled-srv' is disabled"} =
               Proxy.try_handle("disabled-srv:tool", ctx, chained(ctx, %{}), :in_chain)
    end

    test "a row handed in is the revision dispatch speaks to, not a second read", %{ctx: ctx} do
      {:ok, stored} =
        Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
          name: "one-rev",
          url: "https://x.com/mcp",
          enabled: true
        })

      # The caller judged a revision that is now disabled: dispatch sees
      # that revision, whatever the row says by now.
      assert {:error, "Server 'one-rev' is disabled"} =
               Proxy.try_handle("one-rev:tool", ctx, chained(ctx, %{}), :in_chain,
                 server: %{stored | enabled: false}
               )

      # A row for another server is nobody's revision of this one.
      assert {:error, msg} =
               Proxy.try_handle("one-rev:tool", ctx, chained(ctx, %{}), :in_chain,
                 server: %{stored | name: "other"}
               )

      refute msg =~ "disabled"
      Emissary.External.ServerSupervisor.stop("one-rev", ctx.athanor_id)
    end

    test "refuses an external-plane call unless the server opts in", %{ctx: ctx} do
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "chain-only",
        url: "https://x.com/mcp"
      })

      # In-chain is the declared plane and passes the gate (the dispatch
      # itself then fails on the unreachable URL — that failure is not the
      # plane refusal).
      assert {:error, msg} = Proxy.try_handle("chain-only:tool", ctx, %{}, :external)
      assert msg =~ "only from inside a chain"

      Emissary.External.ServerSupervisor.stop("chain-only", ctx.athanor_id)
    end

    test "console opt-in admits the external plane", %{ctx: ctx} do
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "console-ok",
        url: "https://localhost:99999/mcp",
        config_json: Jason.encode!(%{"console" => true})
      })

      # Past the plane gate: the refusal (if any) is the unreachable server,
      # never the plane sentence.
      assert {:error, msg} = Proxy.try_handle("console-ok:tool", ctx, %{}, :external)
      refute msg =~ "only from inside a chain"
      refute msg == :not_external

      Emissary.External.ServerSupervisor.stop("console-ok", ctx.athanor_id)
    end

    test "the console flag is not part of the consent digest", %{ctx: ctx} do
      {:ok, without_flag} =
        Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
          name: "digest-check",
          url: "https://x.com/mcp",
          enabled: true
        })

      {:ok, digest_before} = Sanctum.ToolServerDigest.from_server(without_flag)

      {:ok, with_flag} =
        Arca.McpServerStorage.update(Sanctum.Context.actor(ctx), "digest-check", %{
          config_json: Jason.encode!(%{"console" => true})
        })

      {:ok, digest_after} = Sanctum.ToolServerDigest.from_server(with_flag)

      assert digest_before == digest_after,
             "setting \"console\": true must not move the consent digest — " <>
               "it would flip every existing grant to needs_consent"
    end

    test "call_external refuses a proxied name on the external plane", %{ctx: ctx} do
      # The registry derives the plane from its entry point: call_external
      # dispatches proxied names as :external, so without the server's
      # opt-in the refusal is the plane sentence — the gate is enforced at
      # dispatch, not left to the HTTP router's cache wiring.
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "plane-pin",
        url: "https://localhost:99999/mcp"
      })

      assert {:error, msg} =
               Grimoire.Catalog.call_external("plane-pin:sometool", ctx, %{})

      assert msg =~ "only from inside a chain"

      Emissary.External.ServerSupervisor.stop("plane-pin", ctx.athanor_id)
    end

    test "auto-starts server process on dispatch", %{ctx: ctx} do
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "autostart",
        url: "https://localhost:99999/mcp"
      })

      athanor_id = ctx.athanor_id

      # No process should be running yet
      assert [] =
               Registry.lookup(
                 Emissary.External.ServerRegistry,
                 {"autostart", athanor_id}
               )

      # try_handle should auto-start the server (connection will fail, but process starts)
      result =
        Proxy.try_handle("autostart:some_tool", ctx, chained(ctx, %{}), :in_chain)

      # The server process should now exist (started by try_handle)
      assert [{_pid, _}] =
               Registry.lookup(
                 Emissary.External.ServerRegistry,
                 {"autostart", athanor_id}
               )

      # Result will be an error since the server can't connect, but it shouldn't be :not_external
      assert {:error, msg} = result
      refute msg == :not_external

      # Cleanup
      Emissary.External.ServerSupervisor.stop("autostart", athanor_id)
    end

    test "dispatches to running server", %{ctx: ctx} do
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "dispatch-test",
        url: "https://localhost:99999/mcp"
      })

      athanor_id = ctx.athanor_id

      # Pre-start the server
      Emissary.External.ServerSupervisor.ensure_started(
        name: "dispatch-test",
        url: "https://localhost:99999/mcp",
        athanor_id: athanor_id
      )

      # try_handle should dispatch (will fail at HTTP level, but not :not_external)
      assert {:error, msg} =
               Proxy.try_handle(
                 "dispatch-test:tool",
                 ctx,
                 chained(ctx, %{}),
                 :in_chain
               )

      refute msg == :not_external

      # Cleanup
      Emissary.External.ServerSupervisor.stop("dispatch-test", athanor_id)
    end
  end

  describe "an outbound call's own row" do
    test "an in-chain call is admitted as a tool_call under the caller's lineage and closed after",
         %{ctx: ctx} do
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "rowed",
        url: "https://localhost:99999/mcp"
      })

      lineage = Cyfr.Test.AttemptFixtures.lineage!(ctx)
      parent = lineage.parent_execution_id

      assert {:error, _unreachable} =
               Proxy.try_handle(
                 "rowed:probe",
                 ctx,
                 %{"x" => 1, "parent_execution_id" => parent, "attempt" => lineage.attempt},
                 :in_chain
               )

      assert [row] = tool_calls()
      assert row.kind == "tool_call"
      assert row.component_type == "tool_server"
      assert row.reference == "rowed:probe"
      assert row.parent_execution_id == parent
      assert row.root_execution_id == parent
      assert row.status == "failed"
      assert is_binary(row.error_message)
      assert is_binary(row.component_digest)

      # The row keeps an envelope of the input, not the input.
      assert %{"envelope" => "v1", "server" => "rowed", "tool" => "probe", "keys" => ["x"]} =
               Jason.decode!(row.input)

      assert %{state: "failed", outcome: "error"} =
               Arca.ExecutionAttempts.current(Sanctum.Context.actor(ctx), row.id)

      Emissary.External.ServerSupervisor.stop("rowed", ctx.athanor_id)
    end

    test "a console call writes no row", %{ctx: ctx} do
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "console-rowless",
        url: "https://localhost:99999/mcp",
        config_json: Jason.encode!(%{"console" => true})
      })

      assert {:error, _unreachable} =
               Proxy.try_handle("console-rowless:probe", ctx, %{}, :external)

      assert [] = tool_calls()
      Emissary.External.ServerSupervisor.stop("console-rowless", ctx.athanor_id)
    end
  end

  describe "list_external_tools/1" do
    test "returns empty list when no servers configured", %{ctx: ctx} do
      assert [] = Proxy.list_external_tools(ctx)
    end

    test "skips disabled servers", %{ctx: ctx} do
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "disabled",
        url: "https://x.com/mcp",
        enabled: false
      })

      assert [] = Proxy.list_external_tools(ctx)
    end
  end

  # A server process that answers every call, registered the way the
  # supervisor finds one: under the row's configuration digest.
  defmodule AnsweringServer do
    use GenServer

    def start(ctx, server, answer) do
      config = Emissary.External.Servers.server_config(server, ctx)
      digest = Emissary.External.ServerSupervisor.config_digest(config)
      GenServer.start(__MODULE__, {server.name, ctx.athanor_id, digest, answer})
    end

    @impl true
    def init({name, athanor_id, digest, answer}) do
      {:ok, _} =
        Registry.register(Emissary.External.ServerRegistry, {name, athanor_id}, digest)

      {:ok, answer}
    end

    @impl true
    def handle_call({:call_tool, _tool, _args}, _from, answer),
      do: {:reply, {:ok, answer}, answer}
  end

  defmodule RefusingStore do
    @moduledoc false
    @behaviour Arca.ExecutionPayloads.Store
    @impl true
    def put(_ctx, _segments, _bytes), do: {:error, :disk_full}
    @impl true
    def get(_ctx, _segments), do: {:error, :not_found}
    @impl true
    def delete(_ctx, _segments), do: :ok
  end

  # A store that keeps the first put and refuses the rest.
  defmodule OnceStore do
    @moduledoc false
    @behaviour Arca.ExecutionPayloads.Store

    def reset, do: :persistent_term.put({__MODULE__, :puts}, 0)

    @impl true
    def put(ctx, segments, bytes) do
      n = :persistent_term.get({__MODULE__, :puts}, 0)
      :persistent_term.put({__MODULE__, :puts}, n + 1)

      if n == 0,
        do: Arca.ExecutionPayloads.Store.Overlay.put(ctx, segments, bytes),
        else: {:error, :disk_full}
    end

    @impl true
    def get(ctx, segments), do: Arca.ExecutionPayloads.Store.Overlay.get(ctx, segments)
    @impl true
    def delete(ctx, segments), do: Arca.ExecutionPayloads.Store.Overlay.delete(ctx, segments)
  end

  describe "an outbound call's payloads and identity" do
    setup %{ctx: ctx} do
      on_exit(fn -> Application.delete_env(:arca, :execution_payload_store) end)

      {:ok, server} =
        Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
          name: "kept",
          url: "https://localhost:99999/mcp"
        })

      {:ok, server: server}
    end

    test "the row is the step's execution when one is handed in, its input retained under the caller's class",
         %{ctx: ctx} do
      id = Prima.UUID7.execution_id()

      assert {:error, _unreachable} =
               Proxy.try_handle(
                 "kept:probe",
                 ctx,
                 chained(ctx, %{"x" => 1}),
                 :in_chain,
                 execution_id: id,
                 retention_class: "chat_step"
               )

      assert %{id: ^id, kind: "tool_call"} = Arca.Repo.get(Arca.Schemas.Execution, id)

      assert {:ok, %{retention_class: "chat_step"}, bytes} =
               Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), id, "input")

      assert Jason.decode!(bytes) == %{"x" => 1}

      assert {:error, :not_found} =
               Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), id, "result")

      Emissary.External.ServerSupervisor.stop("kept", ctx.athanor_id)
    end

    test "a call with no step is admitted under a minted id, in the caller's default class",
         %{ctx: ctx} do
      assert {:error, _unreachable} =
               Proxy.try_handle("kept:probe", ctx, chained(ctx, %{}), :in_chain)

      assert [row] = tool_calls()

      assert {:ok, %{retention_class: class}, _} =
               Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), row.id, "input")

      assert class == Arca.Retention.default_class(Sanctum.Context.actor(ctx))
      Emissary.External.ServerSupervisor.stop("kept", ctx.athanor_id)
    end

    test "a hold or a step the barriers cannot find refuses admission", %{ctx: ctx} do
      assert {:error, {:refused, why}} =
               Proxy.try_handle("kept:probe", ctx, chained(ctx, %{}), :in_chain,
                 hold: %{reservation_id: "bgt_gone", id: "chg_gone"}
               )

      assert why =~ "not admitted"

      assert {:error, {:refused, _}} =
               Proxy.try_handle("kept:probe", ctx, chained(ctx, %{}), :in_chain,
                 step: %{id: "stp_gone", generation: 0}
               )

      assert [] = tool_calls()
    end

    test "an input the store cannot keep admits nothing", %{ctx: ctx} do
      args = chained(ctx, %{"x" => 1})
      Application.put_env(:arca, :execution_payload_store, __MODULE__.RefusingStore)

      assert {:error, {:refused, why}} =
               Proxy.try_handle("kept:probe", ctx, args, :in_chain)

      assert why =~ "not admitted"
      assert [] = tool_calls()
    end

    test "the answer is the caller's once its result is kept and the row closed", %{
      ctx: ctx,
      server: server
    } do
      {:ok, pid} =
        __MODULE__.AnsweringServer.start(ctx, server, %{
          "content" => [%{"type" => "text", "text" => "hi"}]
        })

      id = Prima.UUID7.execution_id()

      assert {:ok, %{"content" => [_]} = answer} =
               Proxy.try_handle(
                 "kept:probe",
                 ctx,
                 chained(ctx, %{"q" => 1}),
                 :in_chain,
                 execution_id: id
               )

      assert %{status: "completed"} = row = Arca.Repo.get(Arca.Schemas.Execution, id)

      assert {:ok, _, bytes} =
               Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), id, "result")

      assert Jason.decode!(bytes) == answer
      assert %{"output_hash" => hash} = Jason.decode!(row.output)
      assert hash == Prima.Digest.sha256(bytes)
      GenServer.stop(pid)
    end

    test "a result the store cannot keep closes the attempt result_lost and hands nothing back",
         %{ctx: ctx, server: server} do
      {:ok, pid} = __MODULE__.AnsweringServer.start(ctx, server, %{"content" => []})
      args = chained(ctx, %{})
      __MODULE__.OnceStore.reset()
      Application.put_env(:arca, :execution_payload_store, __MODULE__.OnceStore)
      id = Prima.UUID7.execution_id()

      assert {:error, {:result_lost, _}} =
               Proxy.try_handle("kept:probe", ctx, args, :in_chain, execution_id: id)

      assert %{status: "failed", error_message: "result not retained"} =
               Arca.Repo.get(Arca.Schemas.Execution, id)

      assert %{state: "failed", outcome: "result_lost"} =
               Arca.ExecutionAttempts.current(Sanctum.Context.actor(ctx), id)

      assert {:error, :not_found} =
               Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), id, "result")

      GenServer.stop(pid)
    end
  end
end
