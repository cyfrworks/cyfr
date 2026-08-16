# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.ConversationRunnerTest do
  # The runner owns the turn: rows and broadcasts come from it, not from a
  # browser session. Driven here with the fake engine — the turn's events
  # are sent to the runner the way Opus would deliver them.
  use ExUnit.Case, async: false

  alias Arca.ConversationStorage, as: Conversations
  alias Prism.ConversationRunner
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "conv_runner_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :aqua_turn, Prism.FakeAquaTurn)
    Prism.FakeAquaTurn.listen()

    on_exit(fn ->
      for {_id, pid, _, _} <- DynamicSupervisor.which_children(Prism.ConversationSupervisor) do
        DynamicSupervisor.terminate_child(Prism.ConversationSupervisor, pid)
      end

      Application.delete_env(:cyfr, :aqua_turn)
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    alice = user_ctx("local|idp|alice")
    bob = user_ctx("local|idp|bob")
    {:ok, conv} = Conversations.create(alice)
    ConversationRunner.subscribe(conv.id)
    {:ok, alice: alice, bob: bob, conv: conv}
  end

  defp user_ctx(user_id) do
    Context.build(
      user_id: user_id,
      provider: "oidc",
      athanor_id: "ath_a",
      permissions: [:*],
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  defp emit(runner, kind, data) do
    send(runner, {:execution_event, %{type: "emit", data: Map.put(data, "kind", kind)}})
  end

  defp complete(runner), do: send(runner, {:execution_event, %{type: "complete", data: %{}}})

  defp start_turn(ctx, conv, text) do
    :ok = ConversationRunner.send_message(ctx, conv.id, text)
    assert_receive {:conversation, _, {:message, %{author: author, content: ^text}}}, 5_000
    assert author == ctx.user_id
    assert_receive {:fake_start, eid, _ctx, input}, 10_000
    assert_receive {:fake_subscribe, ^eid, runner}, 5_000
    assert_receive {:conversation, _, {:turn_started, ^eid}}, 5_000
    {eid, runner, input}
  end

  test "a turn is the runner's: rows and broadcasts survive the sender leaving", ctx do
    %{alice: alice, conv: conv} = ctx
    {eid, runner, input} = start_turn(alice, conv, "hello there")

    # The turn runs as the person who sent the message, tagged as its author.
    assert input["task"] == "hello there"
    assert input["author"]["id"] == alice.user_id
    assert is_map(input["tool_policy"])

    {:ok, row} = Conversations.get(alice, conv.id)
    assert row.execution_id == eid

    emit(runner, "text_delta", %{"content" => "Hi "})
    emit(runner, "text_delta", %{"content" => "Alice"})
    assert_receive {:conversation, _, {:delta, "Hi "}}, 5_000
    assert_receive {:conversation, _, {:delta, "Alice"}}, 5_000

    emit(runner, "tool_use", %{"tool" => "component"})

    assert_receive {:conversation, _, {:tool_activity, [%{tool: "component", status: :running}]}},
                   5_000

    emit(runner, "usage", %{"input_tokens" => 10, "output_tokens" => 5})
    assert_receive {:conversation, _, {:usage, %{input: 10, output: 5}}}, 5_000

    emit(runner, "conversation_complete", %{
      "messages" => [
        %{"role" => "user", "content" => "hello there"},
        %{"role" => "assistant", "content" => "Hi Alice"}
      ]
    })

    complete(runner)

    assert_receive {:conversation, _,
                    {:message, %{author: "aqua", content: "Hi Alice", execution_id: ^eid}}},
                   5_000

    assert_receive {:conversation, _, {:turn_finished}}, 5_000
    assert_receive {:fake_unsubscribe, ^eid}, 5_000

    {:ok, row} = Conversations.get(alice, conv.id)
    assert row.execution_id == nil
    assert [%{"role" => "user"}, %{"role" => "assistant"}] = Conversations.history(row)

    # A member joining now sees the same thread from the rows and the
    # runner's live state.
    live = ConversationRunner.state(conv.id, conv.athanor_id)
    refute live.running
    assert live.usage == %{input: 10, output: 5}

    assert Enum.map(Conversations.messages(alice, conv.id), & &1.author) == [
             alice.user_id,
             "aqua"
           ]
  end

  test "one turn at a time; stop keeps the partial reply", %{alice: alice, bob: bob, conv: conv} do
    {eid, runner, _} = start_turn(alice, conv, "start")
    assert {:error, :running} = ConversationRunner.send_message(bob, conv.id, "me too")

    emit(runner, "text_delta", %{"content" => "partial"})
    assert_receive {:conversation, _, {:delta, "partial"}}, 5_000

    # Any member may stop it.
    :ok = ConversationRunner.stop_turn(bob, conv.id)
    assert_receive {:fake_cancel, ^eid}, 5_000
    assert_receive {:conversation, _, {:message, %{author: "aqua", content: content}}}, 5_000
    assert content =~ "partial"
    assert content =~ "cancelled"
    assert_receive {:conversation, _, {:turn_finished}}, 5_000

    {:ok, row} = Conversations.get(alice, conv.id)
    assert row.execution_id == nil

    assert [%{"role" => "user", "content" => "start"}, %{"role" => "assistant"}] =
             Conversations.history(row)
  end

  test "an approval is a row any member decides — once", %{alice: alice, bob: bob, conv: conv} do
    {_eid, runner, _} = start_turn(alice, conv, "make a webhook")

    block = """
    Here is the plan.

    ```aqua-actions
    [{"kind":"ui.request_approval","title":"Create webhook","summary":"Creates hook X","action_description":"webhook.create","risk":"low","proposal":{"tool":"webhook","action":"create","args":{"name":"x"}}}]
    ```
    """

    emit(runner, "text_delta", %{"content" => block})
    complete(runner)

    assert_receive {:conversation, _,
                    {:message, %{author: "aqua", kind: "text", content: "Here is the plan."}}},
                   5_000

    assert_receive {:conversation, _, {:message, %{kind: "approval", status: "pending"} = apr}},
                   5_000

    assert_receive {:conversation, _, {:turn_finished}}, 5_000
    assert Conversations.payload(apr)["intent"]["proposal"]["tool"] == "webhook"
    assert Conversations.payload(apr)["orchestrator"] == "aqua"

    # Bob decides it; Alice's later click finds it already taken.
    :ok = ConversationRunner.approve(bob, conv.id, apr.id, :conversation)

    assert_receive {:conversation, _,
                    {:message_updated, %{status: "running", resolved_by: resolved_by}}},
                   5_000

    assert resolved_by == bob.user_id
    assert {:error, :already_resolved} = ConversationRunner.approve(alice, conv.id, apr.id, :once)
    assert {:error, :already_resolved} = ConversationRunner.decline(alice, conv.id, apr.id, "no")

    assert_receive {:fake_run_approved,
                    %{tool: "webhook", action: "create", args: %{"name" => "x"}}, run_ctx},
                   5_000

    assert run_ctx.user_id == bob.user_id

    assert_receive {:conversation, _, {:message_updated, %{status: "approved"} = done}}, 5_000
    assert Conversations.resolution(done)["summary"] =~ "wh_fake"
    assert Conversations.resolution(done)["scope"] == "conversation"

    # "for this chat" is remembered by the runner and shown to everyone.
    assert_receive {:conversation, _, {:grants, grants}}, 5_000
    assert MapSet.member?(grants, {"webhook", "create"})

    # The outcome is in the history the next turn will carry.
    {:ok, row} = Conversations.get(alice, conv.id)

    assert Enum.any?(
             Conversations.history(row),
             &(&1["content"] =~ "user approved 'Create webhook'")
           )
  end

  test "decline records the reason; a proposal outside policy is a tripwire", %{
    alice: alice,
    conv: conv
  } do
    {_eid, runner, _} = start_turn(alice, conv, "do things")

    block = """
    ```aqua-actions
    [{"kind":"ui.request_approval","title":"Rotate key","summary":"s","action_description":"key.rotate","risk":"low","proposal":{"tool":"key","action":"rotate","args":{}}},
     {"kind":"ui.request_approval","title":"Wipe","summary":"s","action_description":"x","risk":"high","proposal":{"tool":"nonexistent","action":"wipe","args":{}}}]
    ```
    """

    emit(runner, "text_delta", %{"content" => block})
    complete(runner)

    assert_receive {:conversation, _,
                    {:message, %{kind: "approval", content: "Rotate key"} = apr}},
                   5_000

    assert_receive {:conversation, _, {:message, %{kind: "error", content: tripwire}}}, 5_000
    assert tripwire =~ "nonexistent.wipe"
    assert_receive {:conversation, _, {:turn_finished}}, 5_000

    :ok = ConversationRunner.decline(alice, conv.id, apr.id, "not now")
    assert_receive {:conversation, _, {:message_updated, %{status: "declined"} = declined}}, 5_000
    assert Conversations.resolution(declined)["reason"] == "not now"
    refute_receive {:fake_run_approved, _, _}, 200
  end

  test "an engine that will not start the turn leaves an error row", %{alice: alice, conv: conv} do
    defmodule RefusingTurn do
      def start(_ctx, _input), do: {:error, :no_catalyst}
      def engine_available?, do: true
      def subscribe(_, _), do: :ok
      def unsubscribe(_, _), do: :ok
      def cancel(_, _), do: :ok
      def cancel_for_restart(_, _, _), do: :ok
      def events_since(_, _), do: []
      def running?(_, _), do: false
      def run_approved(_, _), do: {:error, :nope}
    end

    Application.put_env(:cyfr, :aqua_turn, RefusingTurn)
    :ok = ConversationRunner.send_message(alice, conv.id, "hi")
    assert_receive {:conversation, _, {:message, %{kind: "error", content: err}}}, 10_000
    assert err =~ "no_catalyst"
    assert_receive {:conversation, _, {:turn_finished}}, 5_000
    refute ConversationRunner.state(conv.id, conv.athanor_id).running
  end

  test "another athanor's member cannot drive the conversation", %{conv: conv} do
    stranger = %{user_ctx("local|idp|carol") | athanor_id: "ath_b"}
    assert {:error, :not_found} = ConversationRunner.send_message(stranger, conv.id, "hi")
    assert {:error, :not_found} = ConversationRunner.stop_turn(stranger, conv.id)
    assert {:error, :not_found} = ConversationRunner.approve(stranger, conv.id, "msg_x")
  end

  test "a turn left running by a restart is closed off when the engine no longer runs it", %{
    alice: alice,
    conv: conv
  } do
    {:ok, _} = Conversations.update(alice, conv.id, %{execution_id: "exec_gone"})
    {:ok, _pid} = ConversationRunner.ensure(conv.id, conv.athanor_id)

    assert_receive {:conversation, _, {:message, %{kind: "system", content: text}}}, 10_000
    assert text =~ "interrupted"
    assert_receive {:conversation, _, {:turn_finished}}, 5_000
    {:ok, row} = Conversations.get(alice, conv.id)
    assert row.execution_id == nil
  end
end
