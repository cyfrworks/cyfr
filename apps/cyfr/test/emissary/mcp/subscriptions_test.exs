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

      actor = Context.actor(ctx)

      :ok =
        Cyfr.Bus.broadcast(
          actor,
          Cyfr.Bus.mcp_servers(actor),
          Cyfr.Bus.McpServers.new(actor, :changed)
        )

      assert_receive %Cyfr.Bus.McpServers{kind: :changed} = changed, 500

      assert {:ok, "notifications/tools/list_changed", %{}} =
               Subscriptions.notification_for(changed)
    end

    # Filtering at translation rather than at subscribe time: a topic that grows
    # a second message type cannot start leaking it to a subscriber who asked
    # for something else.
    test "an unrecognised message is ignored rather than forwarded" do
      assert Subscriptions.notification_for(:something_else) == :ignore
      assert Subscriptions.notification_for({:progress, %{}}) == :ignore

      progress =
        Cyfr.Bus.Progress.new(Prima.Actor.in_athanor("ath_1"), {:pull, "p1"}, phase: :pulling)

      assert Subscriptions.notification_for(progress) == :ignore
    end
  end

  describe "tenancy" do
    test "a listener does not receive another tenant's events", %{ctx: ctx} do
      {:ok, _} = Subscriptions.listen(ctx, %{"toolsListChanged" => true})

      other = Context.actor(%{ctx | athanor_id: "ath_other"})

      :ok =
        Cyfr.Bus.broadcast(
          other,
          Cyfr.Bus.mcp_servers(other),
          Cyfr.Bus.McpServers.new(other, :changed)
        )

      refute_receive %Cyfr.Bus.McpServers{}, 200
    end

    test "a listener cannot subscribe to another tenant's topic", %{ctx: ctx} do
      other = Context.actor(%{ctx | athanor_id: "ath_other"})
      mine = Context.actor(ctx)

      assert {:error, :cross_tenant} = Cyfr.Bus.subscribe(mine, Cyfr.Bus.mcp_servers(other))
    end
  end
end
