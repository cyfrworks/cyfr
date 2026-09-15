# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.McpServersConsentTest do
  @moduledoc """
  A server definition binds vault entries to what the server runs and
  where it sends them, so `mcp_servers.create` and `update` are an
  interactive session's acts: an admin API key is refused at the dispatch
  gate and is not shown them in `tools/list`, a running chain reaches no
  `mcp_servers` action, and a signed-in person defines and changes servers.
  The actions that operate a saved server keep their admin posture.
  """
  use ExUnit.Case, async: false

  alias Cyfr.Ops.Catalog
  alias Cyfr.Ops.Visibility
  alias Emissary.MCP.McpServersTool

  @defining ~w(create update)
  @operating ~w(delete list get test refresh enable disable restart)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp admin_key(ctx, permissions) do
    %{
      ctx
      | auth_method: :api_key,
        api_key_type: :admin,
        permissions: MapSet.new(permissions)
    }
  end

  defp http_config(entry) do
    %{
      "url" => "https://localhost:99999/mcp",
      "headers" => %{"Authorization" => "Bearer vault:#{entry}"}
    }
  end

  defp stdio_config(entry) do
    %{
      "transport" => "stdio",
      "backends" => [
        %{
          "name" => "relay",
          "command" => "node relay.js",
          "env" => %{"TOKEN" => "vault:#{entry}"}
        }
      ]
    }
  end

  defp shown_actions(ctx) do
    Catalog.list_tools()
    |> Visibility.filter_for_context(ctx)
    |> Enum.find(&(&1["name"] == "mcp_servers"))
    |> get_in(["inputSchema", "properties", "action", "enum"])
    |> Enum.sort()
  end

  test "defining a server is interactive and admin; operating one is admin alone" do
    actions = McpServersTool.definition().annotations.actions

    for action <- @defining do
      assert actions[action].consent == :interactive, "mcp_servers.#{action} is not interactive"
      assert actions[action].permission == :admin
    end

    for action <- @operating do
      refute Map.has_key?(actions[action], :consent),
             "mcp_servers.#{action} declares a consent class"
    end

    for action <- @defining ++ @operating do
      assert actions[action].planes == [:external]
    end
  end

  test "an admin API key cannot define or change a server, whatever its permissions", %{
    ctx: ctx
  } do
    {:ok, _saved} =
      Catalog.call_external("mcp_servers", ctx, %{
        "action" => "create",
        "name" => "saved",
        "config" => http_config("saved-token")
      })

    for permissions <- [[:admin], [:*]] do
      key = admin_key(ctx, permissions)

      calls = [
        %{"action" => "create", "name" => "relay-http", "config" => http_config("prod-db")},
        %{"action" => "create", "name" => "relay-stdio", "config" => stdio_config("prod-db")},
        %{
          "action" => "update",
          "name" => "saved",
          "epoch" => 1,
          "config" => http_config("prod-db")
        }
      ]

      for args <- calls do
        assert {:error, {:consent_class_required, {:surface_not_permitted, :api_key}}} =
                 Catalog.call_external("mcp_servers", key, args),
               "mcp_servers.#{args["action"]} answered an API key"
      end
    end

    assert {:error, :not_found} = Arca.McpServerStorage.get(ctx, "relay-http")
    assert {:error, :not_found} = Arca.McpServerStorage.get(ctx, "relay-stdio")
    assert {:ok, %{epoch: 1} = saved} = Arca.McpServerStorage.get(ctx, "saved")
    refute saved.config_json =~ "prod-db"

    key = admin_key(ctx, [:admin])

    assert {:ok, %{servers: [_]}} =
             Catalog.call_external("mcp_servers", key, %{"action" => "list"})

    assert {:ok, %{name: "saved", enabled: false}} =
             Catalog.call_external("mcp_servers", key, %{"action" => "disable", "name" => "saved"})

    assert {:ok, %{deleted: "saved"}} =
             Catalog.call_external("mcp_servers", key, %{"action" => "delete", "name" => "saved"})
  end

  test "an admin API key is shown the operating actions and not the defining ones", %{ctx: ctx} do
    for permissions <- [[:admin], [:*]] do
      assert shown_actions(admin_key(ctx, permissions)) == Enum.sort(@operating)
    end

    assert shown_actions(ctx) == Enum.sort(@defining ++ @operating)
  end

  test "a tincture session cannot define a server", %{ctx: ctx} do
    session = %{ctx | auth_method: :session}

    assert {:error, {:consent_class_required, {:surface_not_permitted, :session}}} =
             Catalog.call_external("mcp_servers", session, %{
               "action" => "create",
               "name" => "relay",
               "config" => http_config("prod-db")
             })
  end

  test "a signed-in person defines and changes a server", %{ctx: ctx} do
    assert {:ok, %{name: "wired", epoch: 1}} =
             Catalog.call_external("mcp_servers", ctx, %{
               "action" => "create",
               "name" => "wired",
               "config" => http_config("gh-token")
             })

    assert {:ok, %{name: "wired", epoch: 2}} =
             Catalog.call_external("mcp_servers", ctx, %{
               "action" => "update",
               "name" => "wired",
               "epoch" => 1,
               "config" => http_config("gh-token-2")
             })

    assert {:ok, %{config_json: config}} = Arca.McpServerStorage.get(ctx, "wired")
    assert config =~ "vault:gh-token-2"
  end

  test "a running chain reaches no mcp_servers action", %{ctx: ctx} do
    guest = Sanctum.Context.enter_guest(ctx)
    authority = Cyfr.Test.AuthorityFixtures.root!()

    for action <- @defining ++ @operating do
      args = %{"action" => action, "name" => "wired", "config" => http_config("gh-token")}

      assert {:error, "Tool action 'mcp_servers." <> _} =
               Catalog.call_in_chain("mcp_servers", guest, args, authority)

      assert {:error, {:guest_plane_call, "mcp_servers"}} =
               Catalog.call_external("mcp_servers", guest, args)
    end

    assert {:error, :not_found} = Arca.McpServerStorage.get(ctx, "wired")
  end
end
