# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.SubscriptionsTest do
  @moduledoc """
  `subscriptions/listen` acknowledges only what it can deliver.

  The temptation with this RPC is to accept every notification type a client
  asks for and quietly never send some of them. That is worse than refusing:
  a client waiting on `resourcesListChanged` cannot tell "nothing changed" from
  "nobody is watching", so it waits forever and reports nothing wrong.
  """
  use ExUnit.Case, async: false

  alias Emissary.MCP.Subscriptions
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  describe "listen/2 acknowledges the honourable subset" do
    test "tools/list changes are real, so they are acknowledged", %{ctx: ctx} do
      assert {:ok, %{"toolsListChanged" => true}} =
               Subscriptions.listen(ctx, %{"toolsListChanged" => true})
    end

    test "types with no change feed are dropped, not accepted", %{ctx: ctx} do
      assert {:ok, acknowledged} =
               Subscriptions.listen(ctx, %{
                 "promptsListChanged" => true,
                 "resourcesListChanged" => true,
                 "resourceSubscriptions" => ["arca://files/x"]
               })

      assert acknowledged == %{}
    end

    test "a partial request is honoured in part", %{ctx: ctx} do
      assert {:ok, acknowledged} =
               Subscriptions.listen(ctx, %{
                 "toolsListChanged" => true,
                 "resourcesListChanged" => true
               })

      assert acknowledged == %{"toolsListChanged" => true}
    end

    test "an empty or absent filter subscribes to nothing", %{ctx: ctx} do
      assert {:ok, %{}} = Subscriptions.listen(ctx, %{})
      assert {:ok, %{}} = Subscriptions.listen(ctx, nil)
    end

    # Only a JSON `true` is an opt-in. Treating a truthy-looking value as consent
    # would have the server pushing to a client that never asked.
    test "only true opts in", %{ctx: ctx} do
      for value <- [false, nil, "true", 1] do
        assert {:ok, %{}} = Subscriptions.listen(ctx, %{"toolsListChanged" => value})
      end
    end
  end

  describe "the stream carries only what was subscribed" do
    test "an external MCP server change becomes tools/list_changed", %{ctx: ctx} do
      {:ok, _} = Subscriptions.listen(ctx, %{"toolsListChanged" => true})

      Phoenix.PubSub.broadcast(
        Emissary.PubSub,
        Sanctum.PubSub.topic("mcp_servers", ctx),
        :mcp_servers_changed
      )

      assert_receive :mcp_servers_changed, 500

      assert {:ok, "notifications/tools/list_changed", %{}} =
               Subscriptions.notification_for(:mcp_servers_changed)
    end

    # Filtering at translation rather than at subscribe time: a topic that grows
    # a second message type cannot start leaking it to a subscriber who asked
    # for something else.
    test "an unrecognised message is ignored rather than forwarded" do
      assert Subscriptions.notification_for(:something_else) == :ignore
      assert Subscriptions.notification_for({:progress, %{}}) == :ignore
    end
  end

  describe "tenancy" do
    test "a listener does not receive another tenant's events", %{ctx: ctx} do
      {:ok, _} = Subscriptions.listen(ctx, %{"toolsListChanged" => true})

      other = %Context{ctx | athanor_id: "ath_other"}

      Phoenix.PubSub.broadcast(
        Emissary.PubSub,
        Sanctum.PubSub.topic("mcp_servers", other),
        :mcp_servers_changed
      )

      refute_receive :mcp_servers_changed, 200
    end
  end
end
