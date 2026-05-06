defmodule Arca.McpServerStorageTest do
  use ExUnit.Case, async: false

  alias Arca.McpServerStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    ctx = Sanctum.TestContext.local()
    {:ok, ctx: ctx}
  end

  describe "put/2" do
    test "creates a new server config", %{ctx: ctx} do
      attrs = %{name: "notion", url: "https://mcp.notion.com/mcp"}

      assert {:ok, server} = McpServerStorage.put(ctx, attrs)
      assert server.name == "notion"
      assert server.url == "https://mcp.notion.com/mcp"
      assert server.enabled == true
    end

    test "stores config_json as map", %{ctx: ctx} do
      attrs = %{
        name: "github",
        url: "https://mcp.github.com/mcp",
        config_json: %{
          "headers" => %{"Authorization" => "secret:GH_TOKEN"},
          "timeout_ms" => 15_000
        }
      }

      assert {:ok, server} = McpServerStorage.put(ctx, attrs)
      assert server.config["headers"]["Authorization"] == "secret:GH_TOKEN"
      assert server.config["timeout_ms"] == 15_000
    end

    test "upserts on conflict", %{ctx: ctx} do
      attrs = %{name: "test-server", url: "https://old.example.com/mcp"}
      assert {:ok, _} = McpServerStorage.put(ctx, attrs)

      attrs2 = %{name: "test-server", url: "https://new.example.com/mcp"}
      assert {:ok, server} = McpServerStorage.put(ctx, attrs2)
      assert server.url == "https://new.example.com/mcp"

      # Should still be one record
      assert {:ok, [_single]} = McpServerStorage.list(ctx)
    end
  end

  describe "get/2" do
    test "returns server by name", %{ctx: ctx} do
      assert {:ok, _} = McpServerStorage.put(ctx, %{name: "myserver", url: "https://a.com/mcp"})
      assert {:ok, server} = McpServerStorage.get(ctx, "myserver")
      assert server.name == "myserver"
    end

    test "returns not_found for missing server", %{ctx: ctx} do
      assert {:error, :not_found} = McpServerStorage.get(ctx, "nonexistent")
    end
  end

  describe "list/1" do
    test "returns all servers for tenant", %{ctx: ctx} do
      assert {:ok, _} = McpServerStorage.put(ctx, %{name: "s1", url: "https://a.com/mcp"})
      assert {:ok, _} = McpServerStorage.put(ctx, %{name: "s2", url: "https://b.com/mcp"})

      assert {:ok, servers} = McpServerStorage.list(ctx)
      assert length(servers) == 2
      names = Enum.map(servers, & &1.name)
      assert "s1" in names
      assert "s2" in names
    end

    test "returns empty list when no servers", %{ctx: ctx} do
      assert {:ok, []} = McpServerStorage.list(ctx)
    end
  end

  describe "delete/2" do
    test "removes a server", %{ctx: ctx} do
      assert {:ok, _} = McpServerStorage.put(ctx, %{name: "deleteme", url: "https://x.com/mcp"})
      assert :ok = McpServerStorage.delete(ctx, "deleteme")
      assert {:error, :not_found} = McpServerStorage.get(ctx, "deleteme")
    end

    test "succeeds even if server doesn't exist", %{ctx: ctx} do
      assert :ok = McpServerStorage.delete(ctx, "nonexistent")
    end
  end

  describe "update/3" do
    test "updates specific fields", %{ctx: ctx} do
      assert {:ok, _} =
               McpServerStorage.put(ctx, %{name: "updatable", url: "https://old.com/mcp"})

      assert {:ok, server} = McpServerStorage.update(ctx, "updatable", %{enabled: false})
      assert server.enabled == false
      assert server.url == "https://old.com/mcp"
    end

    test "returns not_found for missing server", %{ctx: ctx} do
      assert {:error, :not_found} = McpServerStorage.update(ctx, "nope", %{enabled: false})
    end
  end

  describe "tenant isolation" do
    test "different tenants see different servers", %{ctx: _ctx} do
      {ctx_a, ctx_b} = Arca.TenantTestHelper.two_contexts()

      assert {:ok, _} =
               McpServerStorage.put(ctx_a, %{name: "shared-name", url: "https://a.com/mcp"})

      assert {:ok, _} =
               McpServerStorage.put(ctx_b, %{name: "shared-name", url: "https://b.com/mcp"})

      assert {:ok, server_a} = McpServerStorage.get(ctx_a, "shared-name")
      assert server_a.url == "https://a.com/mcp"

      assert {:ok, server_b} = McpServerStorage.get(ctx_b, "shared-name")
      assert server_b.url == "https://b.com/mcp"
    end

    test "delete only affects own tenant", %{ctx: _ctx} do
      {ctx_a, ctx_b} = Arca.TenantTestHelper.two_contexts()

      assert {:ok, _} =
               McpServerStorage.put(ctx_a, %{name: "isolated", url: "https://a.com/mcp"})

      assert {:ok, _} =
               McpServerStorage.put(ctx_b, %{name: "isolated", url: "https://b.com/mcp"})

      assert :ok = McpServerStorage.delete(ctx_a, "isolated")
      assert {:error, :not_found} = McpServerStorage.get(ctx_a, "isolated")
      assert {:ok, _} = McpServerStorage.get(ctx_b, "isolated")
    end
  end
end
