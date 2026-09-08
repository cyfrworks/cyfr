# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ConversationRunnerTest do
  # The runner owns the turn: rows and broadcasts come from it, not from a
  # browser session. Driven here with the fake engine — the turn's events
  # are sent to the runner the way Opus would deliver them.
  use ExUnit.Case, async: false

  alias Arca.ConversationStorage, as: Conversations
  alias Aqua.ConversationRunner
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

    # `ath_a` is a seeded group with two members, so a message has to name
    # the agent to be a turn — `start_turn/3` mentions it. Addressing is
    # derived from how many people are here, not configured: a one-person
    # estate answers a bare line because nobody else could have meant it.
    alice = user_ctx("local|idp|alice")
    bob = user_ctx("local|idp|bob")
    {:ok, group} = Sanctum.Tenancy.Athanors.get("ath_a")

    {:ok, _} =
      Sanctum.Tenancy.Members.ensure(alice.user_id, scope: "athanor", athanor_id: group.id)

    {:ok, _} = Sanctum.Tenancy.Members.ensure(bob.user_id, scope: "athanor", athanor_id: group.id)

    # The seeded agent names a catalyst this sandbox does not hold, and a
    # named ref that does not resolve now refuses the turn (deliberately).
    # These tests drive the fake engine, not a model — so the agent pins
    # none, which is the engine-default path.
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

  # Attributed like production events: the runner drops an event that names
  # no execution (the guarded clause is the contract, not a convenience).
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

  # Two people are in `ath_a`, so a turn is addressed explicitly. The
  # mention is stripped from the task, which is why callers assert on the
  # bare text.
  defp start_turn(ctx, conv, text) do
    addressed = "@aqua " <> text
    :ok = ConversationRunner.send_message(ctx, conv.id, addressed)

    assert_receive {:conversation, _, {:message, %{author: author, content: ^addressed}}}, 5_000
    assert author == ctx.user_id
    assert_receive {:fake_start, eid, _ctx, input, _profile}, 10_000
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
    assert input["system"] =~ "Several people are talking here"
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
    :ok = ConversationRunner.send_message(bob, conv.id, "@aqua me too")

    assert_receive {:conversation, _, {:message, %{author: bob_id, content: "@aqua me too"}}},
                   5_000

    assert bob_id == bob.user_id
    assert_receive {:conversation, _, {:queued, 1}}, 5_000
    refute_receive {:fake_start, _, _, _, _}, 200
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
    refute_receive {:fake_start, _, _, _, _}, 300

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

    :ok = ConversationRunner.send_message(bob, conv.id, "@aqua second question")
    assert_receive {:conversation, _, {:queued, 1}}, 5_000
    :ok = ConversationRunner.send_message(alice, conv.id, "@aqua and a third")
    assert_receive {:conversation, _, {:queued, 2}}, 5_000

    emit(runner, "conversation_complete", %{"messages" => [%{"role" => "user", "content" => "x"}]})

    complete(runner)
    assert_receive {:conversation, _, {:turn_finished}}, 5_000

    # The next turn's task carries the second question only: the third is
    # a later turn of its own (each queued message is a turn).
    assert_receive {:conversation, _, {:queued, 1}}, 5_000
    assert_receive {:fake_start, eid2, ctx2, input2, _profile}, 10_000
    assert ctx2.user_id == bob.user_id
    assert input2["task"] =~ "second question"
    refute input2["task"] =~ "and a third"
    assert_receive {:fake_subscribe, ^eid2, runner2}, 5_000

    complete(runner2)
    assert_receive {:conversation, _, {:queued, 0}}, 5_000
    assert_receive {:fake_start, _eid3, ctx3, input3, _profile}, 10_000
    assert ctx3.user_id == alice.user_id
    assert input3["task"] =~ "and a third"
  end

  test "the queue is bounded — beyond it a sender is told busy and nothing is written",
       %{alice: alice, bob: bob, conv: conv} do
    {_eid, _runner, _} = start_turn(alice, conv, "go")

    for n <- 1..8 do
      :ok = ConversationRunner.send_message(bob, conv.id, "@aqua q#{n}")
      assert_receive {:conversation, _, {:queued, ^n}}, 5_000
    end

    assert {:error, :busy} = ConversationRunner.send_message(bob, conv.id, "@aqua one too many")
    refute Enum.any?(Conversations.messages(alice, conv.id), &(&1.content == "one too many"))
  end

  test "with several people here, they talk freely and the next @turn hears it all",
       %{alice: alice, bob: bob, conv: conv} do
    refute ConversationRunner.state(conv.id, conv.athanor_id).solo_human

    :ok = ConversationRunner.send_message(alice, conv.id, "shall we go out tonight?")
    :ok = ConversationRunner.send_message(bob, conv.id, "sure, where?")
    assert_receive {:conversation, _, {:message, %{content: "shall we go out tonight?"}}}, 5_000
    assert_receive {:conversation, _, {:message, %{content: "sure, where?"}}}, 5_000
    refute_receive {:fake_start, _, _, _, _}, 300
    refute ConversationRunner.state(conv.id, conv.athanor_id).running

    :ok = ConversationRunner.send_message(alice, conv.id, "@aqua suggest a place")
    assert_receive {:conversation, _, {:message, %{content: "@aqua suggest a place"}}}, 5_000
    assert_receive {:fake_start, _eid, ctx, input, _profile}, 10_000
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

  test "a bare line in a shared estate is talk, not a turn — there is no setting to change that",
       %{alice: alice, bob: bob, conv: conv} do
    # Addressing follows the roster: two people are here, so a message has
    # to say who it is for. This replaced a stored `answer_mode` whose
    # `"all"` could not answer "whose agent?" once an agent could belong to
    # a person rather than an estate.
    refute ConversationRunner.state(conv.id, conv.athanor_id).solo_human

    :ok = ConversationRunner.send_message(alice, conv.id, "just chatting")
    refute_receive {:fake_start, _, _, _, _}, 300

    # And it follows the roster as the roster CHANGES: with Bob gone,
    # Alice is talking to nobody but the agent.
    {:ok, group} = Sanctum.Tenancy.Athanors.get(conv.athanor_id)
    :ok = Sanctum.Tenancy.Members.remove_member(group, user_id: bob.user_id)

    assert ConversationRunner.state(conv.id, conv.athanor_id).solo_human
    :ok = ConversationRunner.send_message(alice, conv.id, "still there?")
    assert_receive {:fake_start, _, _, _, _}, 10_000
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

    # Same as the shared setup: unpin the seed catalyst this sandbox lacks.
    {:ok, _} =
      Aqua.AgentConfig.call_aqua(ctx, %{
        "action" => "update",
        "name" => "aqua",
        "catalyst_ref" => ""
      })

    {:ok, conv} = Conversations.create(ctx)
    ConversationRunner.subscribe(conv.id, conv.athanor_id)

    :ok = ConversationRunner.send_message(ctx, conv.id, "hello me")
    assert_receive {:fake_start, _eid, _ctx, input, _profile}, 10_000
    assert input["task"] == "hello me"
    refute input["system"] =~ "group conversation"
  end

  test "a sender who left the athanor is refused, and a queued turn of theirs is dropped",
       %{alice: alice, bob: bob, conv: conv, group: group} do
    {_eid, runner, _} = start_turn(alice, conv, "go")
    :ok = ConversationRunner.send_message(bob, conv.id, "@aqua me next")
    assert_receive {:conversation, _, {:queued, 1}}, 5_000

    :ok = Sanctum.Tenancy.Members.remove_member(group, user_id: bob.user_id)
    assert {:error, :not_member} = ConversationRunner.send_message(bob, conv.id, "still here?")

    complete(runner)
    assert_receive {:conversation, _, {:message, %{kind: "system", content: dropped}}}, 5_000
    assert dropped =~ "no longer a member"
    refute_receive {:fake_start, _, _, _, _}, 300
  end

  test "an approval is a row any member decides — once", %{alice: alice, bob: bob, conv: conv} do
    {_eid, runner, _} = start_turn(alice, conv, "pull a component")

    block = """
    Here is the plan.

    ```aqua-actions
    [{"kind":"ui.request_approval","title":"Pull component","summary":"Pulls catalyst X","action_description":"component.pull","risk":"low","proposal":{"tool":"component","action":"pull","args":{"reference":"catalyst:local.x"}}}]
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
    assert Conversations.payload(apr)["intent"]["proposal"]["tool"] == "component"
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
                    %{
                      tool: "component",
                      action: "pull",
                      args: %{"reference" => "catalyst:local.x"}
                    }, run_ctx, approved_profile},
                   5_000

    assert run_ctx.user_id == bob.user_id

    # The approved call roots the profile the TURN pinned, not one selected
    # afresh at approval time. A human decision unblocks a call; it never
    # chooses the authority the call runs under — and a fresh selection is
    # only unambiguous while the agent formula has a single owner profile.
    assert approved_profile == Aqua.FakeTurn.fake_profile_id()

    assert_receive {:conversation, _, {:message_updated, %{status: "approved"} = done}}, 5_000
    assert Conversations.resolution(done)["summary"] =~ "wh_fake"
    assert Conversations.resolution(done)["scope"] == "conversation"

    # "for this chat" is remembered and shown to everyone.
    assert_receive {:conversation, _, {:grants, grants}}, 5_000
    assert MapSet.member?(grants, {"aqua", "component", "pull"})

    # And it is a ROW, not this process's memory. A `:conversation` grant
    # used to live in a `MapSet` that a deploy, a crash or an idle timeout
    # discarded — reverting an explicit human decision with nothing said.
    assert {:ok, [%{scope: "conversation", effect: "allow", tool: "component", action: "pull"}]} =
             Aqua.ToolGrants.for_conversation(alice, conv.id, "aqua")

    # The outcome is in the history the next turn will carry.
    {:ok, row} = Conversations.get(alice, conv.id)

    assert Enum.any?(
             Conversations.history(row),
             &(&1["content"] =~ "user approved 'Pull component'")
           )
  end

  test "standing scopes on a destructive or external card are refused server-side", %{
    alice: alice,
    bob: bob,
    conv: conv
  } do
    # The card hides the buttons; the rule lives in the runner. A crafted
    # scope=always must not write "auto" into the athanor's shared
    # allowlist — and scope=conversation is a standing grant too (the
    # complete-turn fast path auto-runs later matching proposals for the
    # rest of a multi-member chat), so it is refused the same way. Only
    # :once may approve a destructive/external action.
    {_eid, _runner, _} = start_turn(alice, conv, "plant")

    for kind <- ["destructive", "external"] do
      {:ok, apr} =
        Conversations.append(alice, conv.id, %{
          author: "aqua",
          kind: "approval",
          status: "pending",
          content: "Wipe things",
          payload: %{
            "orchestrator" => "aqua",
            "intent" => %{
              "kind" => "request_approval",
              "title" => "Wipe things",
              "action_kind" => kind,
              "proposal" => %{"tool" => "component", "action" => "delete", "args" => %{}}
            }
          }
        })

      assert {:error, {:scope_not_permitted, ^kind}} =
               ConversationRunner.approve(bob, conv.id, apr.id, :always)

      assert {:error, {:scope_not_permitted, ^kind}} =
               ConversationRunner.approve(bob, conv.id, apr.id, :conversation)

      # The card is still pending — a refused scope decides nothing.
      {:ok, still} = Conversations.get_message(bob, apr.id)
      assert still.status == "pending"

      # This one action, this one time, remains every member's to give.
      :ok = ConversationRunner.approve(bob, conv.id, apr.id, :once)
    end

    # And no standing row was written by either refusal.
    assert {:ok, []} = Aqua.ToolGrants.for_conversation(alice, conv.id, "aqua")
  end

  test "a standing rule on the intent is the runner's rule too", %{
    alice: alice,
    bob: bob,
    conv: conv
  } do
    {_eid, _runner, _} = start_turn(alice, conv, "plant")

    card = fn title, standing, action ->
      {:ok, apr} =
        Conversations.append(alice, conv.id, %{
          author: "aqua",
          kind: "approval",
          status: "pending",
          content: title,
          payload: %{
            "orchestrator" => "aqua",
            "intent" => %{
              "kind" => "request_approval",
              "title" => title,
              "action_kind" => "write",
              "standing" => standing,
              "proposal" => %{
                "tool" => "notes",
                "action" => action,
                "args" => %{"name" => "about-us", "content" => "x"}
              }
            }
          }
        })

      apr
    end

    # `false` — read back from the row's JSON as `false` — takes no
    # standing answer at any scope; the one click is still every member's.
    pin = card.("Pin", false, "pin")

    for scope <- [:conversation, :always] do
      assert {:error, {:scope_not_permitted, :never_standing}} =
               ConversationRunner.approve(bob, conv.id, pin.id, scope)
    end

    :ok = ConversationRunner.approve(bob, conv.id, pin.id, :once)

    # `"conversation"` takes the thread's standing answer and refuses the
    # agent's.
    keep = card.("Keep", "conversation", "keep")

    assert {:error, {:scope_not_permitted, :conversation_only}} =
             ConversationRunner.approve(bob, conv.id, keep.id, :always)

    :ok = ConversationRunner.approve(bob, conv.id, keep.id, :conversation)

    {:ok, rows} = Aqua.ToolGrants.for_conversation(alice, conv.id, "aqua")
    assert [{"notes", "keep"}] = rows |> Aqua.ToolGrants.allowed_keys() |> MapSet.to_list()
  end

  test "a card runs under the profile its OWN turn pinned, not the runner's current one", %{
    alice: alice,
    conv: conv
  } do
    # The first turn's execution, pinned to a profile of its own.
    first = "exec_first_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Arca.Execution.record_start(%{
        id: first,
        reference: "formula:local.aqua",
        user_id: alice.user_id,
        athanor_id: conv.athanor_id,
        started_at: DateTime.utc_now(),
        status: "running",
        component_type: "formula",
        profile_id: "prof_first"
      })

    # A card that turn raised, stamped with it as the runner stamps every card.
    {:ok, apr} =
      Conversations.append(alice, conv.id, %{
        author: "aqua",
        kind: "approval",
        status: "pending",
        content: "Pull component",
        execution_id: first,
        payload: %{
          "orchestrator" => "aqua",
          "intent" => %{
            "kind" => "request_approval",
            "title" => "Pull component",
            "action_kind" => "write",
            "proposal" => %{"tool" => "component", "action" => "pull", "args" => %{}}
          }
        }
      })

    # The NEXT turn starts before the person decides; the runner's pin is
    # now the fake's profile, not the first turn's.
    {_eid, _runner, _} = start_turn(alice, conv, "and another thing")

    :ok = ConversationRunner.approve(alice, conv.id, apr.id, :once)

    assert_receive {:fake_run_approved, _proposal, _ctx, profile}, 5_000
    assert profile == "prof_first"
    refute profile == Aqua.FakeTurn.fake_profile_id()
  end

  test "a card whose execution cannot be read is refused, never rooted afresh", %{
    alice: alice,
    conv: conv
  } do
    {_eid, _runner, _} = start_turn(alice, conv, "plant")

    {:ok, apr} =
      Conversations.append(alice, conv.id, %{
        author: "aqua",
        kind: "approval",
        status: "pending",
        content: "Pull component",
        execution_id: "exec_gone_#{System.unique_integer([:positive])}",
        payload: %{
          "orchestrator" => "aqua",
          "intent" => %{
            "kind" => "request_approval",
            "title" => "Pull component",
            "action_kind" => "write",
            "proposal" => %{"tool" => "component", "action" => "pull", "args" => %{}}
          }
        }
      })

    :ok = ConversationRunner.approve(alice, conv.id, apr.id, :once)

    refute_receive {:fake_run_approved, _, _, _}, 500
    assert_receive {:conversation, _, {:message_updated, %{id: id, status: "error"}}}, 5_000
    assert id == apr.id
  end

  test "an approved note names the turn it was kept from, and lands on the tape as a line", %{
    alice: alice,
    conv: conv
  } do
    {eid, _runner, _} = start_turn(alice, conv, "remember this")

    {:ok, apr} =
      Conversations.append(alice, conv.id, %{
        author: "aqua",
        kind: "approval",
        status: "pending",
        content: "Keep a note",
        execution_id: eid,
        payload: %{
          "orchestrator" => "aqua",
          "intent" => %{
            "kind" => "request_approval",
            "title" => "Keep a note",
            "action_kind" => "write",
            "standing" => "conversation",
            "proposal" => %{
              "tool" => "notes",
              "action" => "keep",
              # Whatever the model wrote here is the runner's to overwrite.
              "args" => %{"name" => "decided", "content" => "Lisbon", "conversation" => "forged"}
            }
          }
        }
      })

    :ok = ConversationRunner.approve(alice, conv.id, apr.id, :once)

    assert_receive {:fake_run_approved, proposal, _ctx, _profile}, 5_000
    assert proposal.args["name"] == "decided"
    # The card's own execution and this conversation ride the proposal as
    # host lineage — what the registry stamps onto the call and the tool
    # reads; the model's `conversation` is left where it is, for the tool
    # to ignore.
    assert proposal.lineage == %{execution_id: eid, conversation_id: conv.id}
    assert proposal.args["conversation"] == "forged"

    # The room sees what was kept, in the runner's voice — never the
    # agent's, which the tape would read as speech.
    assert_receive {:conversation, _,
                    {:message,
                     %{author: "system", kind: "system", content: "📝 Kept a note: decided"}}},
                   5_000
  end

  test "a standing answer the write path refuses is said on the tape, not only logged", %{
    alice: alice,
    conv: conv
  } do
    {_eid, _runner, _} = start_turn(alice, conv, "clean up")

    # The card's intent says `write`, so the runner's own check lets the
    # standing scope through; the grant write re-derives the kind from the
    # registry — `notes.forget` is destructive, and the soul holds it at
    # ask — and refuses. The click still runs this one call; the person
    # must hear that "always for this conversation" did NOT stick.
    {:ok, apr} =
      Conversations.append(alice, conv.id, %{
        author: "aqua",
        kind: "approval",
        status: "pending",
        content: "Forget it",
        payload: %{
          "orchestrator" => "aqua",
          "intent" => %{
            "kind" => "request_approval",
            "title" => "Forget it",
            "action_kind" => "write",
            "proposal" => %{"tool" => "notes", "action" => "forget", "args" => %{"name" => "x"}}
          }
        }
      })

    :ok = ConversationRunner.approve(alice, conv.id, apr.id, :conversation)

    assert_receive {:conversation, _,
                    {:message, %{author: "system", kind: "system", content: content}}},
                   5_000

    assert content =~ "\"Always for this conversation\" was not recorded for notes.forget"
    assert content =~ Aqua.ToolGrants.refusal_message({:scope_not_permitted, :destructive})
    refute content =~ "scope_not_permitted"

    assert_receive {:fake_run_approved, %{tool: "notes", action: "forget"}, _, _}, 5_000
    assert {:ok, []} = Aqua.ToolGrants.for_conversation(alice, conv.id, "aqua")
  end

  test "a standing decline denies the pair and outranks a declared auto", %{
    alice: alice,
    bob: bob,
    conv: conv
  } do
    {_eid, _runner, _} = start_turn(alice, conv, "do things")

    {:ok, apr} =
      Conversations.append(alice, conv.id, %{
        author: "aqua",
        kind: "approval",
        status: "pending",
        content: "Pull it",
        payload: %{
          "orchestrator" => "aqua",
          "intent" => %{
            "kind" => "request_approval",
            "title" => "Pull it",
            "action_kind" => "write",
            "proposal" => %{"tool" => "component", "action" => "pull", "args" => %{}}
          }
        }
      })

    :ok = ConversationRunner.decline(bob, conv.id, apr.id, "never", :never)

    # "Never" is a deny ROW now. It used to delete the key from the agent's
    # authored markdown — the same file the agents page edits — so a
    # decline in one chat quietly rewrote the agent for everyone.
    assert {:ok, [%{scope: "agent", effect: "deny", tool: "component", action: "pull"}]} =
             Aqua.ToolGrants.for_conversation(alice, conv.id, "aqua")

    # And it beats a declared "auto": the pair is pinned as denied — kept
    # as an exact key so no glob can answer for it — so the agent cannot
    # call it and is not asked about it again.
    {:ok, denied} = Aqua.ToolGrants.for_conversation(alice, conv.id, "aqua")

    assert Aqua.ToolGrants.resolve(%{"component.pull" => "auto"}, denied) == %{
             "component.pull" => "deny"
           }
  end

  test "decline records the reason; a proposal outside policy is a tripwire", %{
    alice: alice,
    conv: conv
  } do
    {_eid, runner, _} = start_turn(alice, conv, "do things")

    # `component.pull` rather than `component.register`: register dropped
    # `:in_chain`, and an approved proposal executes in-chain, so it is no
    # longer proposable at all (see `Aqua.ActionsTest`).
    block = """
    ```aqua-actions
    [{"kind":"ui.request_approval","title":"Pull it","summary":"s","action_description":"component.pull","risk":"low","proposal":{"tool":"component","action":"pull","args":{}}},
     {"kind":"ui.request_approval","title":"Wipe","summary":"s","action_description":"x","risk":"high","proposal":{"tool":"nonexistent","action":"wipe","args":{}}}]
    ```
    """

    emit(runner, "text_delta", %{"content" => block})
    complete(runner)

    assert_receive {:conversation, _, {:message, %{kind: "approval", content: "Pull it"} = apr}},
                   5_000

    assert_receive {:conversation, _, {:message, %{kind: "error", content: tripwire}}}, 5_000
    assert tripwire =~ "nonexistent.wipe"
    assert_receive {:conversation, _, {:turn_finished}}, 5_000

    :ok = ConversationRunner.decline(alice, conv.id, apr.id, "not now")
    assert_receive {:conversation, _, {:message_updated, %{status: "declined"} = declined}}, 5_000
    assert Conversations.resolution(declined)["reason"] == "not now"
    refute_receive {:fake_run_approved, _, _, _}, 200
  end

  test "an engine that will not start the turn leaves an error row", %{alice: alice, conv: conv} do
    defmodule RefusingTurn do
      def pin_profile(_ctx), do: {:ok, %{profile_id: "prof_stub"}}
      def start(_ctx, _input, _profile), do: {:error, :no_catalyst}
      def engine_available?, do: true
      def subscribe(_, _), do: :ok
      def unsubscribe(_, _), do: :ok
      def cancel(_, _), do: :ok
      def cancel_for_restart(_, _, _), do: :ok
      def events_since(_, _), do: []
      def running?(_, _), do: false
      def run_approved(_, _, _), do: {:error, :nope}
    end

    Application.put_env(:cyfr, :aqua_turn, RefusingTurn)
    :ok = ConversationRunner.send_message(alice, conv.id, "@aqua hi")
    assert_receive {:conversation, _, {:message, %{kind: "error", content: err}}}, 10_000
    assert err =~ "no_catalyst"
    assert_receive {:conversation, _, {:turn_finished}}, 5_000
    refute ConversationRunner.state(conv.id, conv.athanor_id).running
  end

  test "an ambiguous profile refuses the turn rather than picking one", %{
    alice: alice,
    conv: conv
  } do
    # Two active owner labels on the agent formula. `RootSelect.select/2`
    # answers `{:ambiguous, ids}` for `:default`, and a turn must surface
    # that instead of running under whichever one a re-selection lands on:
    # the profile decides the vault, the egress and the tool surface.
    defmodule AmbiguousTurn do
      def pin_profile(_ctx), do: {:error, {:ambiguous, ["prof_a", "prof_b"]}}
      def start(_ctx, _input, _profile), do: raise("must not start an unpinned turn")
      def engine_available?, do: true
      def subscribe(_, _), do: :ok
      def unsubscribe(_, _), do: :ok
      def cancel(_, _), do: :ok
      def cancel_for_restart(_, _, _), do: :ok
      def events_since(_, _), do: []
      def running?(_, _), do: false
      def run_approved(_, _, _), do: {:error, :nope}
    end

    Application.put_env(:cyfr, :aqua_turn, AmbiguousTurn)
    :ok = ConversationRunner.send_message(alice, conv.id, "@aqua hi")

    assert_receive {:conversation, _, {:message, %{kind: "error", content: err}}}, 10_000
    assert err =~ "ambiguous"
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
      def pin_profile(_ctx), do: {:ok, %{profile_id: "prof_stub"}}
      def start(_ctx, _input, _profile), do: {:error, :unused}
      def engine_available?, do: true

      def subscribe(execution_id, _ctx),
        do: send(:recover_probe, {:subscribed, execution_id, self()})

      def unsubscribe(_, _), do: :ok
      def cancel(_, _), do: :ok
      def cancel_for_restart(_, _, _), do: :ok
      def events_since(_, _), do: []
      def running?(_, _), do: true
      def run_approved(_, _, _), do: {:ok, %{}}
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
    [{"kind":"ui.request_approval","title":"Pull component","summary":"s","action_description":"component.pull","risk":"low","proposal":{"tool":"component","action":"pull","args":{}}}]
    ```
    """

    emit(runner, "text_delta", %{"content" => block})
    complete(runner)
    assert_receive {:conversation, _, {:message, %{kind: "approval", status: "pending"}}}, 5_000
    refute_receive {:conversation, _, {:message, %{kind: "error"}}}, 300
  end

  test "a message over the byte bound is refused whole — nothing written, the draft kept",
       %{alice: alice, conv: conv} do
    long = String.duplicate("a", 32 * 1024 + 1)

    assert {:error, :message_too_long} =
             ConversationRunner.send_message(alice, conv.id, long)

    assert Conversations.messages(alice, conv.id) == []
  end

  test "recovery resolves the stored orchestrator from the estate's tree as it is now",
       %{alice: alice, conv: conv} do
    defmodule StillRunningStoredTurn do
      def pin_profile(_ctx), do: {:ok, %{profile_id: "prof_stub"}}
      def start(_ctx, _input, _profile), do: {:error, :unused}
      def engine_available?, do: true

      def subscribe(execution_id, _ctx),
        do: send(:stored_recover_probe, {:stored_subscribed, execution_id, self()})

      def unsubscribe(_, _), do: :ok
      def cancel(_, _), do: :ok
      def cancel_for_restart(_, _, _), do: :ok
      def events_since(_, _), do: []
      def running?(_, _), do: true
      def run_approved(_, _, _), do: {:ok, %{}}
    end

    Process.register(self(), :stored_recover_probe)
    Application.put_env(:cyfr, :aqua_turn, StillRunningStoredTurn)

    # The row remembers the agent's NAME; the restart reads its definition
    # back from the estate's tree — the roster of the moment, not a copy.
    {:ok, _} =
      Conversations.update(alice, conv.id, %{
        execution_id: "exec_stored",
        orchestrator: "aqua_planner"
      })

    {:ok, _pid} = ConversationRunner.ensure(conv.id, conv.athanor_id)
    assert_receive {:stored_subscribed, "exec_stored", _}, 10_000

    live = ConversationRunner.state(conv.id, conv.athanor_id)
    assert live.running
    assert live.orchestrator["name"] == "aqua_planner"
    refute Map.has_key?(live.orchestrator, "owner")
  end

  test "an approval on a turn with no pinned profile is refused, never re-rooted", %{
    alice: alice,
    conv: conv
  } do
    defmodule StillRunningUnpinnedTurn do
      def pin_profile(_ctx), do: {:ok, %{profile_id: "prof_stub"}}
      def start(_ctx, _input, _profile), do: {:error, :unused}
      def engine_available?, do: true

      def subscribe(execution_id, _ctx),
        do: send(:unpinned_probe, {:unpinned_subscribed, execution_id, self()})

      def unsubscribe(_, _), do: :ok
      def cancel(_, _), do: :ok
      def cancel_for_restart(_, _, _), do: :ok
      def events_since(_, _), do: []
      def running?(_, _), do: true
      def run_approved(_, _, _), do: raise("an unpinned approval must not run")
    end

    Process.register(self(), :unpinned_probe)
    Application.put_env(:cyfr, :aqua_turn, StillRunningUnpinnedTurn)

    # The execution row predates the pin column (no row to read back), so
    # the recovered turn holds no profile. Deciding a card must refuse —
    # rooting a fresh selection here is the substitution the pin exists
    # to prevent.
    {:ok, _} =
      Conversations.update(alice, conv.id, %{execution_id: "exec_unpinned", orchestrator: "aqua"})

    {:ok, _pid} = ConversationRunner.ensure(conv.id, conv.athanor_id)
    assert_receive {:unpinned_subscribed, "exec_unpinned", _}, 10_000

    {:ok, apr} =
      Conversations.append(alice, conv.id, %{
        author: "aqua",
        kind: "approval",
        status: "pending",
        content: "Do it",
        payload: %{
          "orchestrator" => "aqua",
          "intent" => %{
            "kind" => "request_approval",
            "title" => "Do it",
            "action_kind" => "write",
            "proposal" => %{"tool" => "component", "action" => "pull", "args" => %{}}
          }
        }
      })

    :ok = ConversationRunner.approve(alice, conv.id, apr.id, :once)

    assert_receive {:conversation, _, {:message_updated, %{status: "error"} = updated}}, 5_000
    assert Conversations.resolution(updated)["reason"] =~ "profile is unknown"
  end

  test "recovery composes standing denies into the recovered policy", %{
    alice: alice,
    conv: conv
  } do
    defmodule StillRunningDeniedTurn do
      def pin_profile(_ctx), do: {:ok, %{profile_id: "prof_stub"}}
      def start(_ctx, _input, _profile), do: {:error, :unused}
      def engine_available?, do: true

      def subscribe(execution_id, _ctx),
        do: send(:deny_recover_probe, {:deny_subscribed, execution_id, self()})

      def unsubscribe(_, _), do: :ok
      def cancel(_, _), do: :ok
      def cancel_for_restart(_, _, _), do: :ok
      def events_since(_, _), do: []
      def running?(_, _), do: true
      def run_approved(_, _, _), do: {:ok, %{}}
    end

    # "Never" for the estate's own agent, recorded before the restart. The
    # recovered policy must be the same COMPOSITION a fresh start builds —
    # restoring the raw declared markdown would put the denied pair back
    # on the surface until the next turn.
    {:ok, _} =
      Aqua.ToolGrants.put(alice, %{
        scope: "agent",
        effect: "deny",
        agent_name: "aqua",
        tool: "component",
        action: "pull"
      })

    Process.register(self(), :deny_recover_probe)
    Application.put_env(:cyfr, :aqua_turn, StillRunningDeniedTurn)

    {:ok, _} =
      Conversations.update(alice, conv.id, %{execution_id: "exec_denied", orchestrator: "aqua"})

    {:ok, _pid} = ConversationRunner.ensure(conv.id, conv.athanor_id)
    assert_receive {:deny_subscribed, "exec_denied", runner}, 10_000

    # The denied pair is pinned as denied; the rest of the declared policy
    # was read and survives — the composition ran, not a raw restore.
    state = :sys.get_state(runner)
    assert state.tool_policy["component.pull"] == "deny"
    assert Map.has_key?(state.tool_policy, "component.list")
  end

  test "a shutdown mid-turn writes the interruption and clears the running turn; a crash keeps it",
       %{alice: alice, conv: conv} do
    {eid, runner, _} = start_turn(alice, conv, "long question")

    :ok = DynamicSupervisor.terminate_child(Aqua.ConversationSupervisor, runner)
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

  test "archiving the athanor ends the runner: the turn is interrupted, the queue dropped, later sends refused",
       %{alice: alice, bob: bob, conv: conv, group: group} do
    {eid, runner, _} = start_turn(alice, conv, "long question")
    :ok = ConversationRunner.send_message(bob, conv.id, "@aqua me next")
    assert_receive {:conversation, _, {:queued, 1}}, 5_000

    ref = Process.monitor(runner)
    {:ok, _} = Sanctum.Tenancy.Athanors.archive(group)

    assert_receive {:conversation, _, {:message, %{kind: "system", content: text}}}, 5_000
    assert text =~ "archived"
    assert_receive {:fake_cancel, ^eid}, 5_000
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
    {:ok, row} = Conversations.get(alice, conv.id)
    assert row.execution_id == nil

    # Nothing queued runs, and no member can start a turn in a closed furnace.
    refute_receive {:fake_start, _, _, _, _}, 300
    assert {:error, :archived} = ConversationRunner.send_message(alice, conv.id, "hello?")
  end

  test "deciding a card asks the same standing a send does", %{
    alice: alice,
    bob: bob,
    conv: conv,
    group: group
  } do
    {_eid, runner, _} = start_turn(alice, conv, "pull a component")

    block = approval_block()

    emit(runner, "text_delta", %{"content" => block})
    complete(runner)
    assert_receive {:conversation, _, {:message, %{kind: "approval"} = apr}}, 5_000
    assert_receive {:conversation, _, {:turn_finished}}, 5_000

    # Bob loses his seat with the card still on screen: approving would run a
    # tool in a furnace he is no longer in, and "always" would write its
    # shared allowlist.
    :ok = Sanctum.Tenancy.Members.remove_member(group, user_id: bob.user_id)

    assert {:error, :not_member} = ConversationRunner.approve(bob, conv.id, apr.id, :always)
    assert {:error, :not_member} = ConversationRunner.decline(bob, conv.id, apr.id, "no")
    assert {:error, :not_member} = ConversationRunner.stop_turn(bob, conv.id)
    refute_receive {:fake_run_approved, _, _, _}, 200

    # Alice is still a member, so the card is still hers to decide.
    :ok = ConversationRunner.approve(alice, conv.id, apr.id, :once)
    assert_receive {:fake_run_approved, _, _, _}, 5_000
  end

  defp approval_block do
    """
    ```aqua-actions
    [{"kind":"ui.request_approval","title":"Pull component","summary":"s","action_description":"component.pull","risk":"low","proposal":{"tool":"component","action":"pull","args":{}}}]
    ```
    """
  end

  test "a note written while a turn runs survives the turn's own history snapshot",
       %{alice: alice, bob: bob, conv: conv} do
    # First turn leaves an approval pending.
    {_eid, runner, _} = start_turn(alice, conv, "pull a component")

    block = """
    ```aqua-actions
    [{"kind":"ui.request_approval","title":"Pull component","summary":"s","action_description":"component.pull","risk":"low","proposal":{"tool":"component","action":"pull","args":{}}}]
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
    {_eid, runner, _} = start_turn(alice, conv, "pull a component")

    block = """
    ```aqua-actions
    [{"kind":"ui.request_approval","title":"Pull component","summary":"s","action_description":"component.pull","risk":"low","proposal":{"tool":"component","action":"pull","args":{}}}]
    ```
    """

    emit(runner, "text_delta", %{"content" => block})
    complete(runner)
    assert_receive {:conversation, _, {:message, %{kind: "approval"} = apr}}, 5_000
    assert_receive {:notify, _, :approval_pending, _}, 5_000

    :ok = ConversationRunner.decline(alice, conv.id, apr.id, "no")
    assert_receive {:notify, _, :approval_resolved, %{status: "declined"}}, 5_000
  end

  # A turn module whose start exits (a GenServer timeout, a dead engine).
  # Exits are not exceptions: uncaught, the start task died silently and
  # the runner held `running: true` forever.
  defmodule ExitingStartTurn do
    def pin_profile(_ctx), do: {:ok, %{profile_id: "prof_stub"}}
    def start(_ctx, _input, _profile), do: exit({:timeout, {GenServer, :call, [:engine, :start]}})
    defdelegate engine_available?, to: Aqua.FakeTurn
    defdelegate subscribe(eid, ctx), to: Aqua.FakeTurn
    defdelegate unsubscribe(eid, ctx), to: Aqua.FakeTurn
    defdelegate events_since(eid, athanor_id), to: Aqua.FakeTurn
    defdelegate running?(ctx, eid), to: Aqua.FakeTurn
    defdelegate cancel(ctx, eid), to: Aqua.FakeTurn
    defdelegate cancel_for_restart(ctx, eid, payload), to: Aqua.FakeTurn
    defdelegate run_approved(proposal, ctx, profile_id), to: Aqua.FakeTurn
  end

  # A turn whose execution failed so fast its terminal event broadcast
  # before the runner could subscribe — the event lives only in the buffer.
  # The payload key is `:error`, the shape every producer writes
  # (`Opus.ExecutionEventBuffer.push_terminal/5` callers).
  defmodule FastFailTurn do
    defdelegate pin_profile(ctx), to: Aqua.FakeTurn
    defdelegate start(ctx, input, profile_id), to: Aqua.FakeTurn
    defdelegate engine_available?, to: Aqua.FakeTurn
    defdelegate subscribe(eid, ctx), to: Aqua.FakeTurn
    defdelegate unsubscribe(eid, ctx), to: Aqua.FakeTurn
    defdelegate running?(ctx, eid), to: Aqua.FakeTurn
    defdelegate cancel(ctx, eid), to: Aqua.FakeTurn
    defdelegate cancel_for_restart(ctx, eid, payload), to: Aqua.FakeTurn
    defdelegate run_approved(proposal, ctx, profile_id), to: Aqua.FakeTurn

    def events_since(eid, _athanor_id) do
      [
        %{
          execution_id: eid,
          type: "error",
          sequence: 1,
          data: %{error: "Execution failed: the profile is missing a consent"}
        }
      ]
    end
  end

  test "a failed turn keeps its task in history and drops the queue with a note", %{
    alice: alice,
    bob: bob,
    conv: conv
  } do
    # fail_turn used to strand the queue (stale badge; a later send jumped
    # it; the delayed launch regressed the cursor and fed consumed messages
    # twice) and drop the consumed task from the agent's memory.
    {eid, runner, _input} = start_turn(alice, conv, "remember this ask")

    :ok = ConversationRunner.send_message(bob, conv.id, "@aqua me too")
    assert_receive {:conversation, _, {:queued, 1}}, 5_000

    send(runner, {:execution_event, %{execution_id: eid, type: "error", data: %{error: "boom"}}})

    assert_receive {:conversation, _, {:message, %{kind: "error", content: err}}}, 5_000
    assert err =~ "boom"

    assert_receive {:conversation, _, {:message, %{kind: "system", content: note}}}, 5_000
    assert note =~ "waiting turn was dropped"
    assert_receive {:conversation, _, {:queued, 0}}, 5_000
    assert_receive {:conversation, _, {:turn_finished}}, 5_000

    state = ConversationRunner.state(conv.id, conv.athanor_id)
    refute state.running
    assert state.queued == 0

    # The failed turn's task stays in the agent's memory, like a cancel.
    {:ok, row} = Conversations.get(alice, conv.id)

    assert Enum.any?(Conversations.history(row), fn turn ->
             turn["role"] == "user" and turn["content"] =~ "remember this ask"
           end)

    # And the next turn consumes only what came after — nothing re-fed.
    {_eid2, _runner2, input2} = start_turn(alice, conv, "a fresh ask")
    assert input2["task"] =~ "a fresh ask"
    refute input2["task"] =~ "remember this ask"
  end

  test "a turn that completed its conversation then failed keeps one copy of the task", %{
    alice: alice,
    conv: conv
  } do
    # `conversation_complete` REPLACES history with the model's own list,
    # which already contains this turn's user message. `fail_turn` then
    # folded the task in again, so the person's message was read twice by
    # every later turn. The task is consumed once the turn is over.
    {eid, runner, _input} = start_turn(alice, conv, "only once please")

    emit(runner, "conversation_complete", %{
      "messages" => [
        %{"role" => "user", "content" => "only once please"},
        %{"role" => "assistant", "content" => "on it"}
      ]
    })

    send(runner, {:execution_event, %{execution_id: eid, type: "error", data: %{error: "boom"}}})

    assert_receive {:conversation, _, {:turn_finished}}, 5_000

    {:ok, row} = Conversations.get(alice, conv.id)

    user_turns =
      row
      |> Conversations.history()
      |> Enum.filter(&(&1["role"] == "user" and &1["content"] =~ "only once please"))

    assert length(user_turns) == 1,
           "the failed turn re-folded a task the model had already recorded"
  end

  test "an exit inside turn start fails the turn instead of wedging the runner", %{
    alice: alice,
    conv: conv
  } do
    Application.put_env(:cyfr, :aqua_turn, ExitingStartTurn)

    :ok = ConversationRunner.send_message(alice, conv.id, "@aqua boom")

    assert_receive {:conversation, _, {:message, %{kind: "error", content: content}}}, 5_000
    assert content =~ "Execution failed to start"
    assert_receive {:conversation, _, {:turn_finished}}, 5_000

    # Not wedged: the next send is accepted rather than answered :busy.
    :ok = ConversationRunner.send_message(alice, conv.id, "@aqua again")
    assert_receive {:conversation, _, {:message, %{kind: "error"}}}, 5_000
  end

  test "a terminal event broadcast before subscribe is replayed from the buffer", %{
    alice: alice,
    conv: conv
  } do
    Application.put_env(:cyfr, :aqua_turn, FastFailTurn)

    :ok = ConversationRunner.send_message(alice, conv.id, "@aqua fail fast")
    assert_receive {:fake_start, eid, _ctx, _input, _profile}, 10_000
    assert_receive {:fake_subscribe, ^eid, _runner}, 5_000

    # No live event is ever sent; the buffered terminal error must land —
    # and as its `:error` text, never an inspected term.
    assert_receive {:conversation, _, {:message, %{kind: "error", content: content}}}, 5_000
    assert content == "Execution failed: the profile is missing a consent"
    assert_receive {:conversation, _, {:turn_finished}}, 5_000
  end

  test "an event delivered by both the buffer and the live feed applies once", %{
    alice: alice,
    conv: conv
  } do
    {eid, runner, _} = start_turn(alice, conv, "stream")

    live = fn seq, text ->
      send(
        runner,
        {:execution_event,
         %{
           execution_id: eid,
           type: "emit",
           sequence: seq,
           data: %{"kind" => "text_delta", "content" => text}
         }}
      )
    end

    live.(1, "Hi ")
    assert_receive {:conversation, _, {:delta, "Hi "}}, 5_000

    # The same sequence again — a buffered duplicate — must not double.
    live.(1, "Hi ")
    live.(2, "there")
    assert_receive {:conversation, _, {:delta, "there"}}, 5_000
    refute_received {:conversation, _, {:delta, "Hi "}}
  end

  test "a live error event reads the producers' :error key", %{alice: alice, conv: conv} do
    {eid, runner, _} = start_turn(alice, conv, "hello")

    send(
      runner,
      {:execution_event,
       %{execution_id: eid, type: "error", sequence: 5, data: %{error: "It broke cleanly"}}}
    )

    assert_receive {:conversation, _, {:message, %{kind: "error", content: "It broke cleanly"}}},
                   5_000
  end

  test "a `:context` rides the turn's prompt only — never the task, a row, or what the turn remembers",
       %{alice: alice, conv: conv} do
    excerpt = ~s(Read from the room "Team · Plans" — for context only:\nBob: ship friday)

    :ok =
      ConversationRunner.send_message(alice, conv.id, "@aqua what do they mean?",
        context: excerpt
      )

    assert_receive {:conversation, _, {:message, row}}, 5_000
    refute row.content =~ "ship friday"
    assert_receive {:fake_start, eid, _ctx, input, _profile}, 10_000
    assert_receive {:fake_subscribe, ^eid, runner}, 5_000

    assert input["transient"] =~ "## Read from the room"
    assert input["transient"] =~ "Bob: ship friday"
    refute input["system"] =~ "ship friday"
    refute input["task"] =~ "ship friday"
    refute :sys.get_state(runner).last_task =~ "ship friday"

    refute Enum.any?(
             Conversations.latest_messages(alice, conv.id, 10),
             &(&1.content =~ "ship friday")
           )
  end

  test "a `:context` past the message cap is refused, and nothing is written",
       %{alice: alice, conv: conv} do
    before = length(Conversations.latest_messages(alice, conv.id, 100))
    too_long = String.duplicate("x", 32 * 1024 + 1)

    assert {:error, :context_too_long} =
             ConversationRunner.send_message(alice, conv.id, "@aqua hi", context: too_long)

    assert length(Conversations.latest_messages(alice, conv.id, 100)) == before
    refute_receive {:fake_start, _, _, _, _}, 200
  end
end
