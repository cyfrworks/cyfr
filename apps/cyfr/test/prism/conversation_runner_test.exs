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
    # The runners outlive the test body and are stopped from `on_exit`; the
    # sandbox owner is a separate process so they still have their
    # connection then (callbacks run last-registered first).
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Arca.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    test_path = Path.join(System.tmp_dir!(), "conv_runner_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :aqua_turn, Prism.FakeAquaTurn)
    Prism.FakeAquaTurn.listen()

    on_exit(fn ->
      for {_id, pid, _, _} <- DynamicSupervisor.which_children(Prism.ConversationSupervisor),
          is_pid(pid) do
        DynamicSupervisor.terminate_child(Prism.ConversationSupervisor, pid)
      end

      Application.delete_env(:cyfr, :aqua_turn)
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    # `ath_a` is a seeded group; alice and bob are its members, and — for the
    # bulk of these tests — the group answers everything, so a plain message
    # is a turn. The addressing tests set the mode themselves.
    alice = user_ctx("local|idp|alice")
    bob = user_ctx("local|idp|bob")
    {:ok, group} = Sanctum.Tenancy.Athanors.get("ath_a")

    {:ok, _} =
      Sanctum.Tenancy.Members.ensure(alice.user_id, scope: "athanor", athanor_id: group.id)

    {:ok, _} = Sanctum.Tenancy.Members.ensure(bob.user_id, scope: "athanor", athanor_id: group.id)

    {:ok, group} =
      Sanctum.Tenancy.Athanors.put_settings(group, %{"aqua" => %{"answer_mode" => "all"}})

    {:ok, conv} = Conversations.create(alice)
    ConversationRunner.subscribe(conv.id)
    {:ok, alice: alice, bob: bob, conv: conv, group: group}
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

    # The turn runs as the person who sent the message. In a group the task
    # names who said it; the runner writes no separate author key.
    assert input["task"] =~ ~r/: hello there$/
    refute Map.has_key?(input, "author")
    assert input["system"] =~ "group conversation"
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

  test "one turn at a time: a message sent meanwhile is shown at once and its turn waits; stop drops the wait",
       %{alice: alice, bob: bob, conv: conv} do
    {eid, runner, _} = start_turn(alice, conv, "start")

    # Bob's message lands in the thread immediately; AQUA answers it after
    # the running turn — the queue says one is waiting.
    :ok = ConversationRunner.send_message(bob, conv.id, "me too")
    assert_receive {:conversation, _, {:message, %{author: bob_id, content: "me too"}}}, 5_000
    assert bob_id == bob.user_id
    assert_receive {:conversation, _, {:queued, 1}}, 5_000
    refute_receive {:fake_start, _, _, _}, 200
    assert ConversationRunner.state(conv.id, conv.athanor_id).queued == 1

    emit(runner, "text_delta", %{"content" => "partial"})
    assert_receive {:conversation, _, {:delta, "partial"}}, 5_000

    # Any member may stop it — and stop means the conversation: what was
    # queued does not fire.
    :ok = ConversationRunner.stop_turn(bob, conv.id)
    assert_receive {:conversation, _, {:queued, 0}}, 5_000
    assert_receive {:fake_cancel, ^eid}, 5_000
    assert_receive {:conversation, _, {:message, %{author: "aqua", content: content}}}, 5_000
    assert content =~ "partial"
    assert content =~ "cancelled"
    assert_receive {:conversation, _, {:turn_finished}}, 5_000
    refute_receive {:fake_start, _, _, _}, 300

    {:ok, row} = Conversations.get(alice, conv.id)
    assert row.execution_id == nil

    # The cancelled turn's task — the window it took up — is what the history keeps.
    assert [%{"role" => "user", "content" => task}, %{"role" => "assistant"}] =
             Conversations.history(row)

    assert task =~ "start"
  end

  test "a queued turn starts when the running one completes, with everything said meanwhile",
       %{alice: alice, bob: bob, conv: conv} do
    {_eid, runner, _} = start_turn(alice, conv, "first question")

    :ok = ConversationRunner.send_message(bob, conv.id, "second question")
    assert_receive {:conversation, _, {:queued, 1}}, 5_000
    :ok = ConversationRunner.send_message(alice, conv.id, "and a third")
    assert_receive {:conversation, _, {:queued, 2}}, 5_000

    emit(runner, "conversation_complete", %{"messages" => [%{"role" => "user", "content" => "x"}]})

    complete(runner)
    assert_receive {:conversation, _, {:turn_finished}}, 5_000

    # The next turn's task carries the second question only: the third is
    # a later turn of its own (each queued message is a turn).
    assert_receive {:conversation, _, {:queued, 1}}, 5_000
    assert_receive {:fake_start, eid2, ctx2, input2}, 10_000
    assert ctx2.user_id == bob.user_id
    assert input2["task"] =~ "second question"
    refute input2["task"] =~ "and a third"
    assert_receive {:fake_subscribe, ^eid2, runner2}, 5_000

    complete(runner2)
    assert_receive {:conversation, _, {:queued, 0}}, 5_000
    assert_receive {:fake_start, _eid3, ctx3, input3}, 10_000
    assert ctx3.user_id == alice.user_id
    assert input3["task"] =~ "and a third"
  end

  test "the queue is bounded — beyond it a sender is told busy and nothing is written",
       %{alice: alice, bob: bob, conv: conv} do
    {_eid, _runner, _} = start_turn(alice, conv, "go")

    for n <- 1..8 do
      :ok = ConversationRunner.send_message(bob, conv.id, "q#{n}")
      assert_receive {:conversation, _, {:queued, ^n}}, 5_000
    end

    assert {:error, :busy} = ConversationRunner.send_message(bob, conv.id, "one too many")
    refute Enum.any?(Conversations.messages(alice, conv.id), &(&1.content == "one too many"))
  end

  test "in a group that answers when mentioned, people talk freely and the next @turn hears it all",
       %{alice: alice, bob: bob, conv: conv, group: group} do
    {:ok, _} =
      Sanctum.Tenancy.Athanors.put_settings(group, %{"aqua" => %{"answer_mode" => "mentioned"}})

    assert ConversationRunner.state(conv.id, conv.athanor_id).answer_mode == "mentioned"

    :ok = ConversationRunner.send_message(alice, conv.id, "shall we go out tonight?")
    :ok = ConversationRunner.send_message(bob, conv.id, "sure, where?")
    assert_receive {:conversation, _, {:message, %{content: "shall we go out tonight?"}}}, 5_000
    assert_receive {:conversation, _, {:message, %{content: "sure, where?"}}}, 5_000
    refute_receive {:fake_start, _, _, _}, 300
    refute ConversationRunner.state(conv.id, conv.athanor_id).running

    :ok = ConversationRunner.send_message(alice, conv.id, "@aqua suggest a place")
    assert_receive {:conversation, _, {:message, %{content: "@aqua suggest a place"}}}, 5_000
    assert_receive {:fake_start, _eid, ctx, input}, 10_000
    assert ctx.user_id == alice.user_id

    # every human line since the last turn, each attributed, the mention stripped
    lines = String.split(input["task"], "\n")
    assert length(lines) == 3
    assert Enum.at(lines, 0) =~ ~r/: shall we go out tonight\?$/
    assert Enum.at(lines, 1) =~ ~r/: sure, where\?$/
    assert Enum.at(lines, 2) =~ ~r/: suggest a place$/
    refute input["task"] =~ "@aqua"

    {:ok, row} = Conversations.get(alice, conv.id)
    assert row.turn_seq == 3
    assert row.orchestrator == "aqua"
  end

  test "flipping the group's answer mode reaches the running runner",
       %{alice: alice, conv: conv, group: group} do
    _ = ConversationRunner.state(conv.id, conv.athanor_id)
    assert ConversationRunner.state(conv.id, conv.athanor_id).answer_mode == "all"

    {:ok, _} =
      Sanctum.Tenancy.Athanors.put_settings(group, %{"aqua" => %{"answer_mode" => "mentioned"}})

    # the settings write is broadcast on the athanor's notify topic
    Process.sleep(50)
    assert ConversationRunner.state(conv.id, conv.athanor_id).answer_mode == "mentioned"

    :ok = ConversationRunner.send_message(alice, conv.id, "just chatting")
    refute_receive {:fake_start, _, _, _}, 300
  end

  test "a person's own athanor addresses AQUA with every message, unprefixed" do
    n = System.unique_integer([:positive])
    owner = "local|idp|solo-#{n}"

    {:ok, personal} =
      Sanctum.Tenancy.Athanors.create(%{
        kind: "person",
        name: "Solo",
        slug: "solo#{n}",
        owner_user_id: owner,
        created_by: owner
      })

    {:ok, _} = Sanctum.Tenancy.Members.ensure(owner, scope: "athanor", athanor_id: personal.id)
    ctx = %{user_ctx(owner) | athanor_id: personal.id}
    {:ok, conv} = Conversations.create(ctx)
    ConversationRunner.subscribe(conv.id)

    :ok = ConversationRunner.send_message(ctx, conv.id, "hello me")
    assert_receive {:fake_start, _eid, _ctx, input}, 10_000
    assert input["task"] == "hello me"
    refute input["system"] =~ "group conversation"
  end

  test "a sender who left the athanor is refused, and a queued turn of theirs is dropped",
       %{alice: alice, bob: bob, conv: conv, group: group} do
    {_eid, runner, _} = start_turn(alice, conv, "go")
    :ok = ConversationRunner.send_message(bob, conv.id, "me next")
    assert_receive {:conversation, _, {:queued, 1}}, 5_000

    :ok = Sanctum.Tenancy.Members.remove_member(group, user_id: bob.user_id)
    assert {:error, :not_member} = ConversationRunner.send_message(bob, conv.id, "still here?")

    complete(runner)
    assert_receive {:conversation, _, {:message, %{kind: "system", content: dropped}}}, 5_000
    assert dropped =~ "no longer a member"
    refute_receive {:fake_start, _, _, _}, 300
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

  test "a recovered turn keeps its orchestrator's policy, so its approvals are not dropped",
       %{alice: alice, conv: conv} do
    defmodule StillRunningTurn do
      def start(_ctx, _input), do: {:error, :unused}
      def engine_available?, do: true

      def subscribe(execution_id, _ctx),
        do: send(:recover_probe, {:subscribed, execution_id, self()})

      def unsubscribe(_, _), do: :ok
      def cancel(_, _), do: :ok
      def cancel_for_restart(_, _, _), do: :ok
      def events_since(_, _), do: []
      def running?(_, _), do: true
      def run_approved(_, _), do: {:ok, %{}}
    end

    Process.register(self(), :recover_probe)
    Application.put_env(:cyfr, :aqua_turn, StillRunningTurn)

    {:ok, _} =
      Conversations.update(alice, conv.id, %{execution_id: "exec_live", orchestrator: "aqua"})

    {:ok, _pid} = ConversationRunner.ensure(conv.id, conv.athanor_id)

    assert_receive {:subscribed, "exec_live", runner}, 10_000
    live = ConversationRunner.state(conv.id, conv.athanor_id)
    assert live.running
    assert live.orchestrator["name"] == "aqua"

    block = """
    ```aqua-actions
    [{"kind":"ui.request_approval","title":"Create webhook","summary":"s","action_description":"webhook.create","risk":"low","proposal":{"tool":"webhook","action":"create","args":{}}}]
    ```
    """

    emit(runner, "text_delta", %{"content" => block})
    complete(runner)
    assert_receive {:conversation, _, {:message, %{kind: "approval", status: "pending"}}}, 5_000
    refute_receive {:conversation, _, {:message, %{kind: "error"}}}, 300
  end

  test "a shutdown mid-turn writes the interruption and clears the running turn; a crash keeps it",
       %{alice: alice, conv: conv} do
    {eid, runner, _} = start_turn(alice, conv, "long question")

    :ok = DynamicSupervisor.terminate_child(Prism.ConversationSupervisor, runner)
    assert_receive {:conversation, _, {:message, %{kind: "system", content: text}}}, 5_000
    assert text =~ "the server stopped"
    assert_receive {:fake_cancel, ^eid}, 5_000
    {:ok, row} = Conversations.get(alice, conv.id)
    assert row.execution_id == nil

    # a crash writes nothing and cancels nothing: the row still names the
    # execution, and the restarted runner recovers it — here the fake says
    # the engine no longer runs it, so recovery closes it off as a restart.
    {eid2, runner2, _} = start_turn(alice, conv, "again")
    ref = Process.monitor(runner2)
    Process.exit(runner2, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}, 5_000
    refute_receive {:fake_cancel, ^eid2}, 200
    assert_receive {:conversation, _, {:message, %{kind: "system", content: recovered}}}, 10_000
    assert recovered =~ "restarted"
    refute recovered =~ "the server stopped"
  end

  test "a note written while a turn runs survives the turn's own history snapshot",
       %{alice: alice, bob: bob, conv: conv} do
    # First turn leaves an approval pending.
    {_eid, runner, _} = start_turn(alice, conv, "make a webhook")

    block = """
    ```aqua-actions
    [{"kind":"ui.request_approval","title":"Create webhook","summary":"s","action_description":"webhook.create","risk":"low","proposal":{"tool":"webhook","action":"create","args":{}}}]
    ```
    """

    emit(runner, "text_delta", %{"content" => block})
    complete(runner)
    assert_receive {:conversation, _, {:message, %{kind: "approval"} = apr}}, 5_000
    assert_receive {:conversation, _, {:turn_finished}}, 5_000

    # A second turn is running while Bob decides the card.
    {_eid2, runner2, _} = start_turn(bob, conv, "meanwhile")
    :ok = ConversationRunner.decline(bob, conv.id, apr.id, "no thanks")
    assert_receive {:conversation, _, {:message_updated, %{status: "declined"}}}, 5_000

    emit(runner2, "conversation_complete", %{
      "messages" => [%{"role" => "user", "content" => "meanwhile"}]
    })

    complete(runner2)
    assert_receive {:conversation, _, {:turn_finished}}, 5_000

    {:ok, row} = Conversations.get(alice, conv.id)
    history = Conversations.history(row)
    assert Enum.any?(history, &(&1["content"] =~ "meanwhile"))
    assert Enum.any?(history, &(&1["content"] =~ "declined"))
  end

  test "deciding a card tells the tray", %{alice: alice, conv: conv} do
    Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Notify.topic(conv.athanor_id))
    {_eid, runner, _} = start_turn(alice, conv, "make a webhook")

    block = """
    ```aqua-actions
    [{"kind":"ui.request_approval","title":"Create webhook","summary":"s","action_description":"webhook.create","risk":"low","proposal":{"tool":"webhook","action":"create","args":{}}}]
    ```
    """

    emit(runner, "text_delta", %{"content" => block})
    complete(runner)
    assert_receive {:conversation, _, {:message, %{kind: "approval"} = apr}}, 5_000
    assert_receive {:notify, _, :approval_pending, _}, 5_000

    :ok = ConversationRunner.decline(alice, conv.id, apr.id, "no")
    assert_receive {:notify, _, :approval_resolved, %{status: "declined"}}, 5_000
  end
end
