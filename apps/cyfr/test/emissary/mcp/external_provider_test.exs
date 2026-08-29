# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ExternalProviderTest do
  use ExUnit.Case, async: false

  alias Emissary.MCP.ExternalProvider

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    ctx = Sanctum.TestContext.local()
    {:ok, ctx: ctx}
  end

  describe "try_handle/4" do
    test "returns :not_external for non-namespaced tools", %{ctx: ctx} do
      assert {:error, :not_external} =
               ExternalProvider.try_handle("regular_tool", ctx, %{}, :in_chain)
    end

    test "returns :not_external when server doesn't exist", %{ctx: ctx} do
      assert {:error, :not_external} =
               ExternalProvider.try_handle("nonexistent:some_tool", ctx, %{}, :in_chain)
    end

    test "returns error for disabled server", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{
        name: "disabled-srv",
        url: "https://x.com/mcp",
        enabled: false
      })

      assert {:error, "Server 'disabled-srv' is disabled"} =
               ExternalProvider.try_handle("disabled-srv:tool", ctx, %{}, :in_chain)
    end

    test "refuses an external-plane call unless the server opts in", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{
        name: "chain-only",
        url: "https://x.com/mcp"
      })

      # In-chain is the declared plane and passes the gate (the dispatch
      # itself then fails on the unreachable URL — that failure is not the
      # plane refusal).
      assert {:error, msg} = ExternalProvider.try_handle("chain-only:tool", ctx, %{}, :external)
      assert msg =~ "only from inside a chain"

      Emissary.MCP.ExternalServerSupervisor.stop("chain-only", ctx.athanor_id)
    end

    test "console opt-in admits the external plane", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{
        name: "console-ok",
        url: "https://localhost:99999/mcp",
        config_json: Jason.encode!(%{"console" => true})
      })

      # Past the plane gate: the refusal (if any) is the unreachable server,
      # never the plane sentence.
      assert {:error, msg} = ExternalProvider.try_handle("console-ok:tool", ctx, %{}, :external)
      refute msg =~ "only from inside a chain"
      refute msg == :not_external

      Emissary.MCP.ExternalServerSupervisor.stop("console-ok", ctx.athanor_id)
    end

    test "the console flag is not part of the consent digest", %{ctx: ctx} do
      {:ok, without_flag} =
        Arca.McpServerStorage.put(ctx, %{
          name: "digest-check",
          url: "https://x.com/mcp",
          enabled: true
        })

      {:ok, digest_before} = Sanctum.ToolServerDigest.from_server(without_flag)

      {:ok, with_flag} =
        Arca.McpServerStorage.put(ctx, %{
          name: "digest-check2",
          url: "https://x.com/mcp",
          enabled: true,
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
      Arca.McpServerStorage.put(ctx, %{
        name: "plane-pin",
        url: "https://localhost:99999/mcp"
      })

      assert {:error, msg} =
               Emissary.MCP.ToolRegistry.call_external("plane-pin:sometool", ctx, %{})

      assert msg =~ "only from inside a chain"

      Emissary.MCP.ExternalServerSupervisor.stop("plane-pin", ctx.athanor_id)
    end

    test "auto-starts server process on dispatch", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{
        name: "autostart",
        url: "https://localhost:99999/mcp"
      })

      athanor_id = ctx.athanor_id

      # No process should be running yet
      assert [] =
               Registry.lookup(
                 Emissary.MCP.ExternalServerRegistry,
                 {"autostart", athanor_id}
               )

      # try_handle should auto-start the server (connection will fail, but process starts)
      result = ExternalProvider.try_handle("autostart:some_tool", ctx, %{}, :in_chain)

      # The server process should now exist (started by try_handle)
      assert [{_pid, _}] =
               Registry.lookup(
                 Emissary.MCP.ExternalServerRegistry,
                 {"autostart", athanor_id}
               )

      # Result will be an error since the server can't connect, but it shouldn't be :not_external
      assert {:error, msg} = result
      refute msg == :not_external

      # Cleanup
      Emissary.MCP.ExternalServerSupervisor.stop("autostart", athanor_id)
    end

    test "dispatches to running server", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{
        name: "dispatch-test",
        url: "https://localhost:99999/mcp"
      })

      athanor_id = ctx.athanor_id

      # Pre-start the server
      Emissary.MCP.ExternalServerSupervisor.ensure_started(
        name: "dispatch-test",
        url: "https://localhost:99999/mcp",
        athanor_id: athanor_id
      )

      # try_handle should dispatch (will fail at HTTP level, but not :not_external)
      assert {:error, msg} =
               ExternalProvider.try_handle("dispatch-test:tool", ctx, %{}, :in_chain)

      refute msg == :not_external

      # Cleanup
      Emissary.MCP.ExternalServerSupervisor.stop("dispatch-test", athanor_id)
    end
  end

  describe "list_external_tools/1" do
    test "returns empty list when no servers configured", %{ctx: ctx} do
      assert [] = ExternalProvider.list_external_tools(ctx)
    end

    test "skips disabled servers", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{
        name: "disabled",
        url: "https://x.com/mcp",
        enabled: false
      })

      assert [] = ExternalProvider.list_external_tools(ctx)
    end
  end
end
