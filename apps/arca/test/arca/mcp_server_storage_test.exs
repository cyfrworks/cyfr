# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.McpServerStorageTest do
  use ExUnit.Case, async: false

  alias Arca.McpServerStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, actor: Arca.Test.Actor.local()}
  end

  describe "insert/2" do
    test "creates a new server config", %{actor: actor} do
      attrs = %{name: "notion", url: "https://mcp.notion.com/mcp"}

      assert {:ok, server} = McpServerStorage.insert(actor, attrs)
      assert server.name == "notion"
      assert server.url == "https://mcp.notion.com/mcp"
      assert server.enabled == true
    end

    test "records the actor's user as the row's creator, whatever the attrs say",
         %{actor: actor} do
      attrs = %{name: "created", url: "https://a.com/mcp", created_by: "usr_someone_else"}

      assert {:ok, %{created_by: creator}} = McpServerStorage.insert(actor, attrs)

      assert creator == actor.user_id

      {:ok, updated} = McpServerStorage.update(actor, "created", %{enabled: false})

      assert updated.created_by == actor.user_id
    end

    test "stores config_json verbatim (caller serializes)", %{actor: actor} do
      json = ~s({"headers":{"Authorization":"vault:GH_TOKEN"},"timeout_ms":15000})

      attrs = %{
        name: "github",
        url: "https://mcp.github.com/mcp",
        config_json: json
      }

      assert {:ok, _} = McpServerStorage.insert(actor, attrs)
      assert {:ok, server} = McpServerStorage.get(actor, "github")
      assert server.config_json == json
    end

    test "a name the athanor already uses is refused, and the stored row is kept",
         %{actor: actor} do
      attrs = %{name: "test-server", url: "https://old.example.com/mcp"}
      assert {:ok, %{id: id}} = McpServerStorage.insert(actor, attrs)

      attrs2 = %{name: "test-server", url: "https://new.example.com/mcp"}
      assert {:error, :exists} = McpServerStorage.insert(actor, attrs2)

      assert {:ok, [%{id: ^id, url: "https://old.example.com/mcp"}]} =
               McpServerStorage.list(actor)
    end
  end

  describe "get/2" do
    test "returns server by name", %{actor: actor} do
      assert {:ok, _} =
               McpServerStorage.insert(actor, %{
                 name: "myserver",
                 url: "https://a.com/mcp"
               })

      assert {:ok, server} = McpServerStorage.get(actor, "myserver")
      assert server.name == "myserver"
    end

    test "returns not_found for missing server", %{actor: actor} do
      assert {:error, :not_found} = McpServerStorage.get(actor, "nonexistent")
    end
  end

  describe "list/1" do
    test "returns all servers for tenant", %{actor: actor} do
      assert {:ok, _} =
               McpServerStorage.insert(actor, %{
                 name: "s1",
                 url: "https://a.com/mcp"
               })

      assert {:ok, _} =
               McpServerStorage.insert(actor, %{
                 name: "s2",
                 url: "https://b.com/mcp"
               })

      assert {:ok, servers} = McpServerStorage.list(actor)
      assert length(servers) == 2
      names = Enum.map(servers, & &1.name)
      assert "s1" in names
      assert "s2" in names
    end

    test "returns empty list when no servers", %{actor: actor} do
      assert {:ok, []} = McpServerStorage.list(actor)
    end
  end

  describe "delete/2" do
    test "removes a server and answers the row it removed", %{actor: actor} do
      assert {:ok, %{id: id}} =
               McpServerStorage.insert(actor, %{
                 name: "deleteme",
                 url: "https://x.com/mcp"
               })

      assert {:ok, %{id: ^id, name: "deleteme"}} = McpServerStorage.delete(actor, "deleteme")

      assert {:error, :not_found} = McpServerStorage.get(actor, "deleteme")
    end

    test "a server that does not exist is not found", %{actor: actor} do
      assert {:error, :not_found} = McpServerStorage.delete(actor, "nonexistent")
    end
  end

  describe "update/4" do
    test "updates specific fields", %{actor: actor} do
      assert {:ok, _} =
               McpServerStorage.insert(actor, %{
                 name: "updatable",
                 url: "https://old.com/mcp"
               })

      assert {:ok, server} = McpServerStorage.update(actor, "updatable", %{enabled: false})

      assert server.enabled == false
      assert server.url == "https://old.com/mcp"
    end

    test "returns not_found for missing server", %{actor: actor} do
      assert {:error, :not_found} = McpServerStorage.update(actor, "nope", %{enabled: false})
    end
  end

  describe "epochs" do
    test "a row is inserted at epoch 1 and every write raises it in the same statement",
         %{actor: actor} do
      assert {:ok, %{id: id, epoch: 1}} =
               McpServerStorage.insert(actor, %{
                 name: "epochal",
                 url: "https://x.com/mcp"
               })

      assert {:ok, %{epoch: 2}} = McpServerStorage.update(actor, "epochal", %{enabled: false})

      assert {:ok, %{epoch: 3}} = McpServerStorage.bump_epoch(actor, id)
      assert {:ok, %{epoch: 3}} = McpServerStorage.get_by_id(actor, id)
    end

    test "a write naming the epoch it read is refused once the row has moved on",
         %{actor: actor} do
      assert {:ok, %{id: id}} =
               McpServerStorage.insert(actor, %{
                 name: "casrow",
                 url: "https://x.com/mcp"
               })

      assert {:ok, %{epoch: 2}} =
               McpServerStorage.update(actor, "casrow", %{url: "https://y.com/mcp"}, 1)

      assert {:error, :stale_epoch} =
               McpServerStorage.update(actor, "casrow", %{url: "https://z.com/mcp"}, 1)

      assert {:error, :stale_epoch} = McpServerStorage.bump_epoch(actor, id, 1)

      assert {:ok, %{url: "https://y.com/mcp", epoch: 2}} = McpServerStorage.get(actor, "casrow")

      assert {:error, :not_found} = McpServerStorage.update(actor, "absent", %{enabled: true}, 1)
    end

    test "an http row has a url and a stdio row has none", %{actor: actor} do
      stdio = Jason.encode!(%{"backends" => []})

      assert {:ok, %{transport: "stdio", url: nil}} =
               McpServerStorage.insert(actor, %{
                 name: "piped",
                 transport: "stdio",
                 url: nil,
                 config_json: stdio
               })

      for attrs <- [
            %{name: "bad-http", transport: "http", url: nil},
            %{name: "bad-stdio", transport: "stdio", url: "https://x.com/mcp"}
          ] do
        assert {:error, _} = McpServerStorage.insert(actor, attrs)
      end
    end

    test "the fence reads each named row with its athanor's status, in its own athanor only" do
      actor_a = Arca.Test.Actor.local(athanor_id: "ath_a", user_id: "user_a")
      actor_b = Arca.Test.Actor.local(athanor_id: "ath_b", user_id: "user_b")

      {:ok, a} =
        McpServerStorage.insert(actor_a, %{
          name: "fenced",
          url: "https://a.com/mcp"
        })

      {:ok, b} =
        McpServerStorage.insert(actor_b, %{
          name: "fenced",
          url: "https://b.com/mcp"
        })

      assert {:ok, rows} =
               McpServerStorage.fenced([
                 {actor_a.athanor_id, a.id},
                 {actor_a.athanor_id, b.id},
                 {actor_b.athanor_id, b.id}
               ])

      assert %{row: %{id: a_id}} = rows[{actor_a.athanor_id, a.id}]
      assert a_id == a.id
      assert %{row: %{id: b_id}} = rows[{actor_b.athanor_id, b.id}]
      assert b_id == b.id
      refute Map.has_key?(rows, {actor_a.athanor_id, b.id})
    end
  end

  describe "tenant isolation" do
    test "different tenants see different servers", %{actor: _actor} do
      actor_a = Arca.Test.Actor.local(athanor_id: "ath_a", user_id: "user_a")
      actor_b = Arca.Test.Actor.local(athanor_id: "ath_b", user_id: "user_b")

      assert {:ok, _} =
               McpServerStorage.insert(actor_a, %{
                 name: "shared-name",
                 url: "https://a.com/mcp"
               })

      assert {:ok, _} =
               McpServerStorage.insert(actor_b, %{
                 name: "shared-name",
                 url: "https://b.com/mcp"
               })

      assert {:ok, server_a} = McpServerStorage.get(actor_a, "shared-name")
      assert server_a.url == "https://a.com/mcp"

      assert {:ok, server_b} = McpServerStorage.get(actor_b, "shared-name")
      assert server_b.url == "https://b.com/mcp"
    end

    test "delete only affects own tenant", %{actor: _actor} do
      actor_a = Arca.Test.Actor.local(athanor_id: "ath_a", user_id: "user_a")
      actor_b = Arca.Test.Actor.local(athanor_id: "ath_b", user_id: "user_b")

      assert {:ok, _} =
               McpServerStorage.insert(actor_a, %{
                 name: "isolated",
                 url: "https://a.com/mcp"
               })

      assert {:ok, _} =
               McpServerStorage.insert(actor_b, %{
                 name: "isolated",
                 url: "https://b.com/mcp"
               })

      assert {:ok, _} = McpServerStorage.delete(actor_a, "isolated")
      assert {:error, :not_found} = McpServerStorage.get(actor_a, "isolated")
      assert {:ok, _} = McpServerStorage.get(actor_b, "isolated")
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

    test "round-trips what put/2 stored", %{actor: actor} do
      config = %{"headers" => %{"Authorization" => "vault:NOTION"}, "tool_patterns" => ["a_*"]}

      {:ok, _} =
        McpServerStorage.insert(actor, %{
          name: "roundtrip",
          url: "https://example.test",
          config_json: Jason.encode!(config)
        })

      {:ok, row} = McpServerStorage.get(actor, "roundtrip")
      assert McpServerStorage.config(row) == config
    end
  end
end
