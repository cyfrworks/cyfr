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

  alias Grimoire.Visibility
  alias Emissary.External.Provider

  @defining ~w(create update)
  @operating ~w(delete list get test refresh enable disable restart)

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local(:api)}
  end

  defp admin_key(ctx, permissions) do
    %{
      ctx
      | auth_method: :api_key,
        api_key_type: :admin,
        permissions: MapSet.new(permissions)
    }
  end

  defp http_config(entry, url \\ "https://127.0.0.1:9/mcp") do
    %{"url" => url, "headers" => %{"Authorization" => "Bearer vault:#{entry}"}}
  end

  # An entry a definition at `http_config/1`'s URL may name: its
  # destination covers that URL.
  defp entry!(ctx, name) do
    {:ok, _} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: name,
        kind: "api_key",
        fields: %{"token" => "t-" <> name},
        destination: %{"hosts" => ["127.0.0.1"], "port" => 9}
      })
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
    Grimoire.list_tools()
    |> Visibility.filter_for_context(ctx)
    |> Enum.find(&(&1["name"] == "mcp_servers"))
    |> get_in(["inputSchema", "properties", "action", "enum"])
    |> Enum.sort()
  end

  test "defining a server is interactive and admin; operating one is admin alone" do
    actions = Provider.definition().annotations.actions

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
    entry!(ctx, "saved-token")

    {:ok, _saved} =
      Grimoire.call_external("mcp_servers", ctx, %{
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
        assert {:error,
                %Prima.Refusal{
                  stage: :admission,
                  reason: {:consent_class_required, {:surface_not_permitted, :api_key}}
                }} = Grimoire.call_external("mcp_servers", key, args),
               "mcp_servers.#{args["action"]} answered an API key"
      end
    end

    assert {:error, :not_found} =
             Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "relay-http")

    assert {:error, :not_found} =
             Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "relay-stdio")

    assert {:ok, %{epoch: 1} = saved} =
             Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "saved")

    refute saved.config_json =~ "prod-db"

    key = admin_key(ctx, [:admin])

    assert {:ok, %{servers: [_]}} =
             Grimoire.call_external("mcp_servers", key, %{"action" => "list"})

    assert {:ok, %{name: "saved", enabled: false}} =
             Grimoire.call_external("mcp_servers", key, %{
               "action" => "disable",
               "name" => "saved"
             })

    assert {:ok, %{deleted: "saved"}} =
             Grimoire.call_external("mcp_servers", key, %{"action" => "delete", "name" => "saved"})
  end

  test "an admin API key is shown the operating actions and not the defining ones", %{ctx: ctx} do
    for permissions <- [[:admin], [:*]] do
      assert shown_actions(admin_key(ctx, permissions)) == Enum.sort(@operating)
    end

    assert shown_actions(ctx) == Enum.sort(@defining ++ @operating)
  end

  test "a tincture session cannot define a server", %{ctx: ctx} do
    session = %{ctx | auth_method: :session}

    assert {:error,
            %Prima.Refusal{
              stage: :admission,
              reason: {:consent_class_required, {:surface_not_permitted, :session}}
            }} =
             Grimoire.call_external("mcp_servers", session, %{
               "action" => "create",
               "name" => "relay",
               "config" => http_config("prod-db")
             })
  end

  test "a signed-in person defines and changes a server", %{ctx: ctx} do
    entry!(ctx, "gh-token")
    entry!(ctx, "gh-token-2")

    assert {:ok, %{name: "wired", epoch: 1}} =
             Grimoire.call_external("mcp_servers", ctx, %{
               "action" => "create",
               "name" => "wired",
               "config" => http_config("gh-token")
             })

    assert {:ok, %{name: "wired", epoch: 2}} =
             Grimoire.call_external("mcp_servers", ctx, %{
               "action" => "update",
               "name" => "wired",
               "epoch" => 1,
               "config" => http_config("gh-token-2")
             })

    assert {:ok, %{config_json: config}} =
             Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "wired")

    assert config =~ "vault:gh-token-2"
  end

  test "a signed-in person's definition is refused where its header's entry may not go, " <>
         "naming the header and never the entry",
       %{ctx: ctx} do
    entry!(ctx, "gh-token")

    for config <- [
          http_config("gh-token", "https://evil.example/mcp"),
          http_config("absent-token")
        ] do
      assert {:error, {:invalid_argument, message}} =
               Grimoire.call_external("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "wired",
                 "config" => config
               })

      assert message ==
               "Header 'Authorization' names no active vault entry whose destination covers " <>
                 "this server's URL"
    end

    assert {:error, :not_found} = Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "wired")
  end

  test "a running chain reaches no mcp_servers action", %{ctx: ctx} do
    guest = Sanctum.Context.enter_guest(ctx)
    authority = Prima.Test.AuthorityFixtures.root!()

    for action <- @defining ++ @operating do
      args = %{"action" => action, "name" => "wired", "config" => http_config("gh-token")}

      assert {:error, %Prima.Refusal{stage: :admission, reason: "Tool action 'mcp_servers." <> _}} =
               Grimoire.call_in_chain("mcp_servers", guest, args, authority,
                 lineage: Cyfr.Test.AttemptFixtures.lineage!(guest)
               )

      assert {:error,
              %Prima.Refusal{stage: :admission, reason: {:guest_plane_call, "mcp_servers"}}} =
               Grimoire.call_external("mcp_servers", guest, args)
    end

    assert {:error, :not_found} = Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "wired")
  end
end
