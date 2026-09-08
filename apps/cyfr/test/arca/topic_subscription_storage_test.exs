# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TopicSubscriptionStorageTest do
  # Following is about your sidebar, not your access. These are the rules
  # that keep the two apart.
  use ExUnit.Case, async: false

  alias Arca.ConversationStorage, as: Conversations
  alias Arca.TopicSubscriptionStorage, as: Subs

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    alice = Sanctum.TestContext.local()

    bob = %{
      alice
      | user_id: "github|https://github.com|bob-#{System.unique_integer([:positive])}"
    }

    {:ok, alice: alice, bob: bob}
  end

  test "the creator follows their own thread without picking themselves", %{alice: alice} do
    {:ok, conv} = Conversations.create(alice, %{title: "Mine"})

    assert MapSet.member?(Subs.followed(alice, alice.user_id), conv.id)
  end

  test "create follows nobody but the creator — a client cannot pick for others", %{
    alice: alice,
    bob: bob
  } do
    # There is deliberately no subscriber list on create: a follow row is
    # always the person's own act, so a stray attr must not write one.
    {:ok, conv} = Conversations.create(alice, %{title: "Ours", subscribers: [bob.user_id]})

    refute MapSet.member?(Subs.followed(bob, bob.user_id), conv.id)
    assert MapSet.member?(Subs.followed(alice, alice.user_id), conv.id)
  end

  test "someone not picked can still READ it — following is not an ACL", %{
    alice: alice,
    bob: bob
  } do
    {:ok, conv} = Conversations.create(alice, %{title: "Not yours"})

    refute MapSet.member?(Subs.followed(bob, bob.user_id), conv.id)

    # Access is membership in the estate, and Bob's context has it. An
    # unfollowed topic renders collapsed and opens on a click; making this
    # a permission would be a second, weaker gate beside membership.
    assert {:ok, ^conv} = Conversations.get(bob, conv.id)
  end

  test "follow and unfollow are both idempotent", %{alice: alice, bob: bob} do
    {:ok, conv} = Conversations.create(alice, %{title: "T"})

    :ok = Subs.follow(bob, conv.id, bob.user_id)
    :ok = Subs.follow(bob, conv.id, bob.user_id)
    assert Subs.follows?(bob.athanor_id, conv.id, bob.user_id)

    :ok = Subs.unfollow(bob, conv.id, bob.user_id)
    :ok = Subs.unfollow(bob, conv.id, bob.user_id)
    refute MapSet.member?(Subs.followed(bob, bob.user_id), conv.id)
  end

  test "unfollowing one topic leaves the others alone", %{alice: alice} do
    {:ok, a} = Conversations.create(alice, %{title: "A"})
    {:ok, b} = Conversations.create(alice, %{title: "B"})

    :ok = Subs.unfollow(alice, a.id, alice.user_id)

    followed = Subs.followed(alice, alice.user_id)
    refute MapSet.member?(followed, a.id)
    assert MapSet.member?(followed, b.id)
  end

  test "another estate's follows are not this one's", %{alice: alice} do
    {:ok, conv} = Conversations.create(alice, %{title: "Here"})
    elsewhere = %{alice | athanor_id: "ath_elsewhere"}

    refute MapSet.member?(Subs.followed(elsewhere, alice.user_id), conv.id)
  end

  test "unfollow_all/2 drops one person's follows in one estate and nothing else", %{
    alice: alice,
    bob: bob
  } do
    {:ok, a} = Conversations.create(alice, %{title: "A"})
    {:ok, b} = Conversations.create(alice, %{title: "B"})
    :ok = Subs.follow(bob, a.id, bob.user_id)

    # Bob's follow of the same topic id in another estate is that
    # estate's row, not this one's.
    elsewhere = %{bob | athanor_id: "ath_other"}
    :ok = Subs.follow(elsewhere, a.id <> "-other", bob.user_id)

    :ok = Subs.unfollow_all(alice.athanor_id, bob.user_id)

    assert Subs.followed(bob, bob.user_id) == MapSet.new()
    assert MapSet.member?(Subs.followed(elsewhere, bob.user_id), a.id <> "-other")

    followed = Subs.followed(alice, alice.user_id)
    assert MapSet.member?(followed, a.id)
    assert MapSet.member?(followed, b.id)

    # Idempotent, like its siblings.
    assert :ok = Subs.unfollow_all(alice.athanor_id, bob.user_id)
  end

  test "deleting a thread sweeps its follows and its conversation-scope grants", %{
    alice: alice,
    bob: bob
  } do
    test_path = Path.join(System.tmp_dir!(), "subs_sweep_#{:rand.uniform(1_000_000)}")
    original = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:cyfr, :base_path, original),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, conv} = Conversations.create(alice, %{title: "Short-lived"})
    :ok = Subs.follow(bob, conv.id, bob.user_id)

    {:ok, _} =
      Aqua.ToolGrants.put(alice, %{
        scope: "conversation",
        effect: "allow",
        conversation_id: conv.id,
        agent_name: "aqua",
        tool: "component",
        action: "pull"
      })

    # An agent-scope answer belongs to the agent, not the thread — it stays.
    {:ok, _} =
      Aqua.ToolGrants.put(alice, %{
        scope: "agent",
        effect: "allow",
        conversation_id: conv.id,
        agent_name: "aqua",
        tool: "component",
        action: "inspect"
      })

    :ok = Conversations.delete(alice, conv.id)

    # Until the athanor's own destroy, nothing else reclaimed these — a
    # deleted topic left rows naming it forever.
    refute Subs.follows?(alice.athanor_id, conv.id, alice.user_id)
    refute MapSet.member?(Subs.followed(bob, bob.user_id), conv.id)

    remaining = Aqua.ToolGrants.for_conversation(alice, conv.id, "aqua")
    assert {:ok, [%{scope: "agent", action: "inspect"}]} = remaining
  end
end
