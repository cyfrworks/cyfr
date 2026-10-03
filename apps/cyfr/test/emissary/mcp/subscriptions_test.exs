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

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  describe "listen/2 acknowledges the honourable subset" do
    test "tools/list changes are real, so they are acknowledged", %{ctx: ctx} do
      assert {:ok, %{"toolsListChanged" => true}, [_grant]} =
               Subscriptions.listen(ctx, %{"toolsListChanged" => true})
    end

    test "types with no change feed are dropped, not accepted", %{ctx: ctx} do
      assert {:ok, acknowledged, _grants} =
               Subscriptions.listen(ctx, %{
                 "promptsListChanged" => true,
                 "resourcesListChanged" => true,
                 "resourceSubscriptions" => ["arca://files/x"]
               })

      assert acknowledged == %{}
    end

    test "a partial request is honoured in part", %{ctx: ctx} do
      assert {:ok, acknowledged, _grants} =
               Subscriptions.listen(ctx, %{
                 "toolsListChanged" => true,
                 "resourcesListChanged" => true
               })

      assert acknowledged == %{"toolsListChanged" => true}
    end

    test "an empty or absent filter subscribes to nothing", %{ctx: ctx} do
      assert {:ok, %{}, []} = Subscriptions.listen(ctx, %{})
      assert {:ok, %{}, []} = Subscriptions.listen(ctx, nil)
    end

    # Only a JSON `true` is an opt-in. Treating a truthy-looking value as consent
    # would have the server pushing to a client that never asked.
    test "only true opts in", %{ctx: ctx} do
      for value <- [false, nil, "true", 1] do
        assert {:ok, %{}, []} = Subscriptions.listen(ctx, %{"toolsListChanged" => value})
      end
    end
  end

  describe "the stream carries only what was subscribed" do
    test "an external MCP server change becomes tools/list_changed", %{ctx: ctx} do
      {:ok, _, _} = Subscriptions.listen(ctx, %{"toolsListChanged" => true})

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

  describe "admission" do
    import Ecto.Query, only: [from: 2]

    defp decisions(request_id),
      do: Arca.Repo.all(from(d in Arca.Schemas.DecisionLog, where: d.request_id == ^request_id))

    defp changed(actor) do
      :ok =
        Cyfr.Bus.broadcast(
          actor,
          Cyfr.Bus.mcp_servers(actor),
          Cyfr.Bus.McpServers.new(actor, :changed)
        )
    end

    test "each acknowledged type is one gate decision on its declared stream", %{ctx: ctx} do
      ctx = %{ctx | request_id: Prima.UUID7.request_id()}

      assert {:ok, %{"toolsListChanged" => true}, [grant]} =
               Subscriptions.listen(ctx, %{"toolsListChanged" => true})

      assert %Prima.StreamGrant{topic: :mcp_servers, subject: nil, projection: ["kind"]} = grant

      assert Cyfr.Bus.granted_topic(Context.actor(ctx), grant) ==
               Cyfr.Bus.mcp_servers(Context.actor(ctx))

      assert [%{tool: "stream:mcp_servers.changes", admission: "admitted"}] =
               decisions(ctx.request_id)
    end

    test "nothing requested is nothing admitted", %{ctx: ctx} do
      ctx = %{ctx | request_id: Prima.UUID7.request_id()}
      assert {:ok, %{}, []} = Subscriptions.listen(ctx, %{"promptsListChanged" => true})
      assert decisions(ctx.request_id) == []
    end

    test "a refused open refuses the listen and subscribes to nothing", %{ctx: ctx} do
      ctx = %{ctx | request_id: Prima.UUID7.request_id(), authenticated: false}

      assert {:error, %Prima.Refusal{stage: :admission, class: :unauthenticated}} =
               Subscriptions.listen(ctx, %{"toolsListChanged" => true})

      assert [%{admission: "refused"}] = decisions(ctx.request_id)

      changed(Context.actor(ctx))
      refute_receive %Cyfr.Bus.McpServers{}, 200
    end

    test "a guest-planed context is refused", %{ctx: ctx} do
      assert {:error, %Prima.Refusal{class: :forbidden}} =
               Subscriptions.listen(Context.enter_guest(ctx), %{"toolsListChanged" => true})
    end

    test "a credential already ended is refused", %{ctx: ctx} do
      ctx = %{ctx | credential_deadline: DateTime.add(DateTime.utc_now(), -1, :second)}

      assert {:error, %Prima.Refusal{class: :unauthenticated}} =
               Subscriptions.listen(ctx, %{"toolsListChanged" => true})
    end

    test "close ends delivery on the granted topic", %{ctx: ctx} do
      {:ok, _, grants} = Subscriptions.listen(ctx, %{"toolsListChanged" => true})
      :ok = Subscriptions.close(ctx, grants)

      changed(Context.actor(ctx))
      refute_receive %Cyfr.Bus.McpServers{}, 200
    end

    test "a reconnect is a new admission with a new grant", %{ctx: ctx} do
      ctx = %{ctx | request_id: Prima.UUID7.request_id()}
      {:ok, _, [first]} = Subscriptions.listen(ctx, %{"toolsListChanged" => true})
      :ok = Subscriptions.close(ctx, [first])
      {:ok, _, [second]} = Subscriptions.listen(ctx, %{"toolsListChanged" => true})

      refute first.grant_id == second.grant_id
      assert length(decisions(ctx.request_id)) == 2
    end
  end

  describe "the grant is enforced" do
    test "the stream lives until the earliest grant's deadline", %{ctx: ctx} do
      now = DateTime.utc_now()
      credential = DateTime.add(now, 5, :second)

      {:ok, _, [grant]} =
        Subscriptions.listen(%{ctx | credential_deadline: credential}, %{
          "toolsListChanged" => true
        })

      assert grant.deadline == credential
      assert Subscriptions.remaining_ms([grant], now) == 5_000
      assert Subscriptions.remaining_ms([grant], DateTime.add(now, 10, :second)) == 0
      assert Subscriptions.remaining_ms([], now) == :infinity
    end

    test "a listener that falls too far behind is refused with a typed overflow" do
      assert Subscriptions.backlog() == :ok

      listener =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      for _ <- 1..1_001, do: send(listener, :pending)

      assert {:error,
              %Prima.Refusal{class: :rate_limited, reason: :stream_overflow, message: message}} =
               Subscriptions.backlog(listener)

      assert message =~ "listen again"
      send(listener, :stop)
    end
  end

  describe "tenancy" do
    test "a listener does not receive another tenant's events", %{ctx: ctx} do
      {:ok, _, _} = Subscriptions.listen(ctx, %{"toolsListChanged" => true})

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
