# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.McpServerStorageTest do
  use ExUnit.Case, async: false

  alias Arca.McpServerStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    ctx = Sanctum.TestContext.local()
    {:ok, ctx: ctx}
  end

  describe "insert/2" do
    test "creates a new server config", %{ctx: ctx} do
      attrs = %{name: "notion", url: "https://mcp.notion.com/mcp"}

      assert {:ok, server} = McpServerStorage.insert(ctx, attrs)
      assert server.name == "notion"
      assert server.url == "https://mcp.notion.com/mcp"
      assert server.enabled == true
    end

    test "records the context's user as the row's creator, whatever the attrs say", %{ctx: ctx} do
      attrs = %{name: "created", url: "https://a.com/mcp", created_by: "usr_someone_else"}

      assert {:ok, %{created_by: creator}} = McpServerStorage.insert(ctx, attrs)
      assert creator == ctx.user_id

      {:ok, updated} = McpServerStorage.update(ctx, "created", %{enabled: false})
      assert updated.created_by == ctx.user_id
    end

    test "stores config_json verbatim (caller serializes)", %{ctx: ctx} do
      json = ~s({"headers":{"Authorization":"vault:GH_TOKEN"},"timeout_ms":15000})

      attrs = %{
        name: "github",
        url: "https://mcp.github.com/mcp",
        config_json: json
      }

      assert {:ok, _} = McpServerStorage.insert(ctx, attrs)
      assert {:ok, server} = McpServerStorage.get(ctx, "github")
      assert server.config_json == json
    end

    test "a name the athanor already uses is refused, and the stored row is kept", %{ctx: ctx} do
      attrs = %{name: "test-server", url: "https://old.example.com/mcp"}
      assert {:ok, %{id: id}} = McpServerStorage.insert(ctx, attrs)

      attrs2 = %{name: "test-server", url: "https://new.example.com/mcp"}
      assert {:error, :exists} = McpServerStorage.insert(ctx, attrs2)

      assert {:ok, [%{id: ^id, url: "https://old.example.com/mcp"}]} =
               McpServerStorage.list(ctx)
    end
  end

  describe "get/2" do
    test "returns server by name", %{ctx: ctx} do
      assert {:ok, _} =
               McpServerStorage.insert(ctx, %{name: "myserver", url: "https://a.com/mcp"})

      assert {:ok, server} = McpServerStorage.get(ctx, "myserver")
      assert server.name == "myserver"
    end

    test "returns not_found for missing server", %{ctx: ctx} do
      assert {:error, :not_found} = McpServerStorage.get(ctx, "nonexistent")
    end
  end

  describe "list/1" do
    test "returns all servers for tenant", %{ctx: ctx} do
      assert {:ok, _} = McpServerStorage.insert(ctx, %{name: "s1", url: "https://a.com/mcp"})
      assert {:ok, _} = McpServerStorage.insert(ctx, %{name: "s2", url: "https://b.com/mcp"})

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
    test "removes a server and answers the row it removed", %{ctx: ctx} do
      assert {:ok, %{id: id}} =
               McpServerStorage.insert(ctx, %{name: "deleteme", url: "https://x.com/mcp"})

      assert {:ok, %{id: ^id, name: "deleteme"}} = McpServerStorage.delete(ctx, "deleteme")
      assert {:error, :not_found} = McpServerStorage.get(ctx, "deleteme")
    end

    test "a server that does not exist is not found", %{ctx: ctx} do
      assert {:error, :not_found} = McpServerStorage.delete(ctx, "nonexistent")
    end
  end

  describe "update/4" do
    test "updates specific fields", %{ctx: ctx} do
      assert {:ok, _} =
               McpServerStorage.insert(ctx, %{name: "updatable", url: "https://old.com/mcp"})

      assert {:ok, server} = McpServerStorage.update(ctx, "updatable", %{enabled: false})
      assert server.enabled == false
      assert server.url == "https://old.com/mcp"
    end

    test "returns not_found for missing server", %{ctx: ctx} do
      assert {:error, :not_found} = McpServerStorage.update(ctx, "nope", %{enabled: false})
    end
  end

  describe "epochs" do
    test "a row is inserted at epoch 1 and every write raises it in the same statement",
         %{ctx: ctx} do
      assert {:ok, %{id: id, epoch: 1}} =
               McpServerStorage.insert(ctx, %{name: "epochal", url: "https://x.com/mcp"})

      assert {:ok, %{epoch: 2}} = McpServerStorage.update(ctx, "epochal", %{enabled: false})
      assert {:ok, %{epoch: 3}} = McpServerStorage.bump_epoch(ctx, id)
      assert {:ok, %{epoch: 3}} = McpServerStorage.get_by_id(ctx, id)
    end

    test "a write naming the epoch it read is refused once the row has moved on", %{ctx: ctx} do
      assert {:ok, %{id: id}} =
               McpServerStorage.insert(ctx, %{name: "casrow", url: "https://x.com/mcp"})

      assert {:ok, %{epoch: 2}} =
               McpServerStorage.update(ctx, "casrow", %{url: "https://y.com/mcp"}, 1)

      assert {:error, :stale_epoch} =
               McpServerStorage.update(ctx, "casrow", %{url: "https://z.com/mcp"}, 1)

      assert {:error, :stale_epoch} = McpServerStorage.bump_epoch(ctx, id, 1)
      assert {:ok, %{url: "https://y.com/mcp", epoch: 2}} = McpServerStorage.get(ctx, "casrow")
      assert {:error, :not_found} = McpServerStorage.update(ctx, "absent", %{enabled: true}, 1)
    end

    test "an http row has a url and a stdio row has none", %{ctx: ctx} do
      stdio = Jason.encode!(%{"backends" => []})

      assert {:ok, %{transport: "stdio", url: nil}} =
               McpServerStorage.insert(ctx, %{
                 name: "piped",
                 transport: "stdio",
                 url: nil,
                 config_json: stdio
               })

      for attrs <- [
            %{name: "bad-http", transport: "http", url: nil},
            %{name: "bad-stdio", transport: "stdio", url: "https://x.com/mcp"}
          ] do
        assert {:error, _} = McpServerStorage.insert(ctx, attrs)
      end
    end

    test "the fence reads each named row with its athanor's status, in its own athanor only" do
      {ctx_a, ctx_b} = Arca.TenantTestHelper.two_contexts()
      {:ok, a} = McpServerStorage.insert(ctx_a, %{name: "fenced", url: "https://a.com/mcp"})
      {:ok, b} = McpServerStorage.insert(ctx_b, %{name: "fenced", url: "https://b.com/mcp"})

      assert {:ok, rows} =
               McpServerStorage.fenced([
                 {ctx_a.athanor_id, a.id},
                 {ctx_a.athanor_id, b.id},
                 {ctx_b.athanor_id, b.id}
               ])

      assert %{row: %{id: a_id}} = rows[{ctx_a.athanor_id, a.id}]
      assert a_id == a.id
      assert %{row: %{id: b_id}} = rows[{ctx_b.athanor_id, b.id}]
      assert b_id == b.id
      refute Map.has_key?(rows, {ctx_a.athanor_id, b.id})
    end
  end

  describe "tenant isolation" do
    test "different tenants see different servers", %{ctx: _ctx} do
      {ctx_a, ctx_b} = Arca.TenantTestHelper.two_contexts()

      assert {:ok, _} =
               McpServerStorage.insert(ctx_a, %{name: "shared-name", url: "https://a.com/mcp"})

      assert {:ok, _} =
               McpServerStorage.insert(ctx_b, %{name: "shared-name", url: "https://b.com/mcp"})

      assert {:ok, server_a} = McpServerStorage.get(ctx_a, "shared-name")
      assert server_a.url == "https://a.com/mcp"

      assert {:ok, server_b} = McpServerStorage.get(ctx_b, "shared-name")
      assert server_b.url == "https://b.com/mcp"
    end

    test "delete only affects own tenant", %{ctx: _ctx} do
      {ctx_a, ctx_b} = Arca.TenantTestHelper.two_contexts()

      assert {:ok, _} =
               McpServerStorage.insert(ctx_a, %{name: "isolated", url: "https://a.com/mcp"})

      assert {:ok, _} =
               McpServerStorage.insert(ctx_b, %{name: "isolated", url: "https://b.com/mcp"})

      assert {:ok, _} = McpServerStorage.delete(ctx_a, "isolated")
      assert {:error, :not_found} = McpServerStorage.get(ctx_a, "isolated")
      assert {:ok, _} = McpServerStorage.get(ctx_b, "isolated")
    end
  end

  describe "config/1" do
    test "decodes a stored row's config_json" do
      assert McpServerStorage.config(%{config_json: ~s({"headers":{"X":"1"},"timeout_ms":5})}) ==
               %{"headers" => %{"X" => "1"}, "timeout_ms" => 5}
    end

    test "reads as empty rather than raising, for every shape a row can hold" do
      # The consent digest, the header resolver and the vault reconciler all
      # decode here; if they disagreed about a malformed row the digest would
      # describe a server that is not the one being called.
      for server <- [
            %{config_json: nil},
            %{config_json: ""},
            %{config_json: "not json"},
            # valid JSON, but not an object
            %{config_json: "[1,2,3]"},
            %{config_json: "42"},
            %{},
            nil
          ] do
        assert McpServerStorage.config(server) == %{}, "expected #{inspect(server)} to read empty"
      end
    end

    test "round-trips what put/2 stored", %{ctx: ctx} do
      config = %{"headers" => %{"Authorization" => "vault:NOTION"}, "tool_patterns" => ["a_*"]}

      {:ok, _} =
        McpServerStorage.insert(ctx, %{
          name: "roundtrip",
          url: "https://example.test",
          config_json: Jason.encode!(config)
        })

      {:ok, row} = McpServerStorage.get(ctx, "roundtrip")
      assert McpServerStorage.config(row) == config
    end
  end
end
