# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ConversationRunnerStateTest do
  # The runner's state between turns and across cards: what it keeps is an
  # identity, what it decides is decided fresh, and what a completion
  # emits is addressed from the turn it came from. Driven with the fake
  # engine like `Aqua.ConversationRunnerTest`.
  use ExUnit.Case, async: false

  alias Arca.ConversationStorage, as: Conversations
  alias Aqua.ConversationRunner
  alias Sanctum.Context

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Arca.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    test_path = Path.join(System.tmp_dir!(), "conv_runner_state_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :aqua_turn, Aqua.FakeTurn)
    Aqua.FakeTurn.listen()

    on_exit(fn ->
      for {_id, pid, _, _} <- DynamicSupervisor.which_children(Aqua.ConversationSupervisor),
          is_pid(pid) do
        DynamicSupervisor.terminate_child(Aqua.ConversationSupervisor, pid)
      end

      Application.delete_env(:cyfr, :aqua_turn)
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    alice = user_ctx("local|idp|alice")
    bob = user_ctx("local|idp|bob")
    {:ok, group} = Sanctum.Tenancy.Athanors.get("ath_a")
    _ = Sanctum.TestContext.provisioned!(group.id)

    {:ok, _} =
      Sanctum.Tenancy.Members.ensure(alice.user_id, scope: "athanor", athanor_id: group.id)

    {:ok, _} = Sanctum.Tenancy.Members.ensure(bob.user_id, scope: "athanor", athanor_id: group.id)

    {:ok, _} =
      Aqua.AgentConfig.call_aqua(alice, %{
        "action" => "update",
        "name" => "aqua",
        "catalyst_ref" => ""
      })

    {:ok, conv} = Conversations.create(alice)
    ConversationRunner.subscribe(conv.id, conv.athanor_id)
    {:ok, alice: alice, bob: bob, conv: conv, group: group}
  end

  defp user_ctx(user_id, extra \\ []) do
    Context.build(
      [
        user_id: user_id,
        provider: "oidc",
        athanor_id: "ath_a",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      ] ++ extra
    )
  end

  defp emit(runner, kind, data) do
    %{execution_id: eid} = :sys.get_state(runner)

    send(
      runner,
      {:execution_event, %{execution_id: eid, type: "emit", data: Map.put(data, "kind", kind)}}
    )
  end

  defp complete(runner) do
    %{execution_id: eid} = :sys.get_state(runner)
    send(runner, {:execution_event, %{execution_id: eid, type: "complete", data: %{}}})
  end

  defp start_turn(ctx, conv, text) do
    :ok = ConversationRunner.send_message(ctx, conv.id, text)
    assert_receive {:fake_start, eid, _ctx, input, _profile}, 10_000
    assert_receive {:fake_subscribe, ^eid, runner}, 5_000
    assert_receive {:conversation, _, {:turn_started, ^eid}}, 5_000
    {eid, runner, input}
  end

  # A reply that ends in one approval card for `tool.action`.
  defp card_block(tool, action) do
    ~s(```aqua-actions
[{"kind":"ui.request_approval","title":"Do #{action}","summary":"s","risk":"low","action_description":"d","proposal":{"tool":"#{tool}","action":"#{action}","args":{"name":"x"}}}]
```)
  end

  defp finish_with(runner, text) do
    emit(runner, "text_delta", %{"content" => text})
    emit(runner, "conversation_complete", %{"messages" => []})
    complete(runner)
  end

  defp finish_with_card(runner, tool, action) do
    finish_with(runner, "Sure.\n\n" <> card_block(tool, action))

    assert_receive {:conversation, _, {:message, %{kind: "approval", status: "pending"} = card}},
                   5_000

    assert_receive {:conversation, _, {:turn_finished}}, 5_000
    card
  end

  test "a revoked standing answer recovers the ask on the next turn", %{alice: alice, conv: conv} do
    {_eid, runner, input} = start_turn(alice, conv, "@aqua make one")
    assert input["tool_policy"]["component.create"] == "ask"
    card = finish_with_card(runner, "component", "create")

    :ok = ConversationRunner.approve(alice, conv.id, card.id, :conversation)
    assert_receive {:fake_run_approved, %{tool: "component", action: "create"}, _, _}, 5_000
    assert_receive {:conversation, _, {:grants, grants}}, 5_000
    assert MapSet.member?(grants, {"aqua", "component", "create"})

    {_eid2, runner2, input2} = start_turn(alice, conv, "@aqua again")
    assert input2["tool_policy"]["component.create"] == "auto"
    finish_with(runner2, "Done.")
    assert_receive {:conversation, _, {:turn_finished}}, 5_000

    # Withdrawn — and the next composition starts from the AUTHORED policy,
    # so the ask is back. A composition that started from the previous
    # one could never recover it.
    :ok = ConversationRunner.revoke_grant(alice, conv.id, "aqua", "component", "create")

    {_eid3, _runner3, input3} = start_turn(alice, conv, "@aqua once more")
    assert input3["tool_policy"]["component.create"] == "ask"
  end

  test "a late approval for one agent never runs another agent's card", %{
    alice: alice,
    bob: bob,
    conv: conv
  } do
    # A role written past the door — a hand-edited file — that holds a
    # write at ask, so a turn of its own can raise a card.
    cleaner =
      Compendium.AquaAgent.serialize(%{
        name: "cleaner",
        title: "Cleaner",
        description: "",
        disabled: false,
        catalyst_ref: nil,
        model: nil,
        tool_policy: %{"component.create" => "ask"},
        prompt: "# Cleaner"
      })

    :ok = Arca.put(alice, Compendium.AquaPath.agent_file("cleaner"), cleaner)

    {_eid, runner, _} = start_turn(alice, conv, "@aqua make one")
    soul_card = finish_with_card(runner, "component", "create")

    # Answered "for this conversation" — for the SOUL.
    :ok = ConversationRunner.approve(alice, conv.id, soul_card.id, :conversation)
    assert_receive {:fake_run_approved, %{tool: "component", action: "create"}, _, _}, 5_000
    assert_receive {:conversation, _, {:grants, grants}}, 5_000
    assert MapSet.member?(grants, {"aqua", "component", "create"})
    refute MapSet.member?(grants, {"cleaner", "component", "create"})

    # The cleaner's own card for the same pair stays pending: the answer
    # was the soul's, and the fast path checks the card's agent.
    {_eid2, runner2, input2} = start_turn(bob, conv, "@cleaner tidy up")
    assert input2["tool_policy"]["component.create"] == "ask"
    cleaner_card = finish_with_card(runner2, "component", "create")
    refute_receive {:fake_run_approved, _, _, _}, 300

    {:ok, row} = Conversations.get_message(alice, cleaner_card.id)
    assert row.status == "pending"
  end

  test "the fast path consumes a grant without rewriting who gave it", %{
    alice: alice,
    bob: bob,
    conv: conv
  } do
    {_eid, runner, _} = start_turn(alice, conv, "@aqua make one")
    card = finish_with_card(runner, "component", "create")

    # Bob's turn is composed BEFORE the answer lands, so it still asks…
    {_eid2, runner2, input2} = start_turn(bob, conv, "@aqua make another")
    assert input2["tool_policy"]["component.create"] == "ask"

    # …then Alice answers "for this conversation" while Bob's turn runs.
    :ok = ConversationRunner.approve(alice, conv.id, card.id, :conversation)
    assert_receive {:fake_run_approved, %{tool: "component", action: "create"}, _, _}, 5_000
    assert_receive {:conversation, _, {:grants, _}}, 5_000

    {:ok, [%{id: grant_id, granted_by: granted_by, granted_at: granted_at}]} =
      Aqua.ToolGrants.for_conversation(alice, conv.id, "aqua")

    assert granted_by == alice.user_id

    # Bob's card meets the standing answer and runs at once — as `:once`:
    # the row that admitted it is untouched, Alice still gave it.
    finish_with(runner2, "Sure.\n\n" <> card_block("component", "create"))
    assert_receive {:fake_run_approved, %{tool: "component", action: "create"}, _, _}, 5_000
    assert_receive {:conversation, _, {:turn_finished}}, 5_000

    assert {:ok, [%{id: ^grant_id, granted_by: ^granted_by, granted_at: ^granted_at}]} =
             Aqua.ToolGrants.for_conversation(alice, conv.id, "aqua")
  end

  test "a card is decided against the policy as it stands, not as it stood", %{
    alice: alice,
    conv: conv
  } do
    {_eid, runner, _} = start_turn(alice, conv, "@aqua make one")
    card = finish_with_card(runner, "component", "create")

    # "Never", answered after the card was raised.
    {:ok, _} =
      Aqua.ToolGrants.put(alice, %{
        scope: "agent",
        effect: "deny",
        conversation_id: conv.id,
        agent_name: "aqua",
        tool: "component",
        action: "create"
      })

    :ok = ConversationRunner.approve(alice, conv.id, card.id, :once)
    assert_receive {:conversation, _, {:message_updated, %{status: "error"} = refused}}, 5_000
    assert Conversations.resolution(refused)["reason"] =~ "declined"
    refute_receive {:fake_run_approved, _, _, _}, 300
  end

  test "a completion's intents reach the person whose turn it was", %{alice: alice, conv: conv} do
    {_eid, runner, _} = start_turn(alice, conv, "@aqua show me")

    finish_with(runner, ~s(Here.\n\n```aqua-actions
[{"kind":"ui.execution.focus","id":"exec_abc"}]
```))

    assert_receive {:conversation, _, {:intents, [%{kind: "navigate", to: to}], user_id}}, 5_000
    assert to =~ "exec_abc"
    assert user_id == alice.user_id
  end

  test "an operator who is not seated reads the room but cannot act in it", %{conv: conv} do
    operator = user_ctx("local|idp|operator", platform_admin: true)
    refute Sanctum.Tenancy.Members.member?(operator.user_id, conv.athanor_id)

    assert {:error, :not_member} = ConversationRunner.send_message(operator, conv.id, "@aqua hi")
    assert {:error, :not_member} = ConversationRunner.approve(operator, conv.id, "apr_x", :once)
    assert {:error, :not_member} = ConversationRunner.stop_turn(operator, conv.id)
  end

  test "granted?/3 is keyed by the agent the card names" do
    grants = MapSet.new([{"aqua", "component", "create"}])
    intent = %{proposal: %{tool: "component", action: "create", args: %{}}}
    assert Aqua.Turn.granted?("aqua", intent, grants)
    refute Aqua.Turn.granted?("aqua_planner", intent, grants)
    refute Aqua.Turn.granted?(nil, intent, grants)
  end

  test "a stored pick that was disabled since does not run — the turn fails, loudly", %{
    alice: alice
  } do
    n = System.unique_integer([:positive])

    {:ok, mine} =
      Sanctum.Tenancy.Athanors.create(%{
        kind: "person",
        name: "Me",
        slug: "me-s#{n}",
        owner_user_id: alice.user_id,
        created_by: alice.user_id
      })

    # A turn pins the baseline consent, so the estate this one runs in is
    # set up like any estate a person actually chats in.
    {:ok, _} = Sanctum.Tenancy.Athanors.mark_provisioned(mine)

    {:ok, _} =
      Sanctum.Tenancy.Members.ensure(alice.user_id, scope: "athanor", athanor_id: mine.id)

    {:ok, me} = Context.focus(alice, mine.id)

    for name <- ["aqua", "aqua_planner"] do
      {:ok, _} =
        Aqua.AgentConfig.call_aqua(me, %{
          "action" => "update",
          "name" => name,
          "catalyst_ref" => ""
        })
    end

    {:ok, conv} = Conversations.create(me)
    ConversationRunner.subscribe(conv.id, conv.athanor_id)

    # A solo estate: the previous turn's agent answers a bare line.
    {_eid, runner, _} = start_turn(me, conv, "@aqua_planner look around")
    finish_with(runner, "Looked.")
    assert_receive {:conversation, _, {:turn_finished}}, 5_000

    {:ok, _} =
      Aqua.AgentConfig.call_aqua(me, %{
        "action" => "update",
        "name" => "aqua_planner",
        "disabled" => true
      })

    :ok = ConversationRunner.send_message(me, conv.id, "and now?")
    assert_receive {:conversation, _, {:message, %{kind: "error", content: content}}}, 10_000
    assert content =~ "failed to start"
    refute_receive {:fake_start, _, _, _, _}, 300
  end
end
