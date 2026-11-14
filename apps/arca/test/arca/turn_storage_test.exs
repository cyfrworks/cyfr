# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TurnStorageTest do
  @moduledoc """
  The turn store owns persistence and the transactional guards, not
  policy: its vocabulary is `Prima.TurnState`'s, it keeps no recovery cap
  of its own, and the limit a turn is held to is the one its row stores,
  written from the caller's policy when the turn starts.
  """

  use ExUnit.Case, async: false

  alias Arca.Schemas.Turn
  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage

  describe "the vocabulary and the policy" do
    test "every transaction takes the write lock through the locking helper" do
      source = File.read!(Path.expand("../../lib/arca/turn_storage.ex", __DIR__))

      refute source =~ "Arca.Repo.transaction(",
             "a turn transition opens its transaction with Arca.Repo.locking_transaction/2"
    end
  end

  describe "the stored limit" do
    setup tags do
      Arca.Test.Sandbox.setup!(tags)
      Arca.Test.Actor.athanor!()
      actor = Arca.Test.Actor.local()
      {:ok, thread} = Threads.create(actor)
      {:ok, actor: actor, thread: thread}
    end

    test "an accepted turn stores none; its start stores the caller's",
         %{actor: actor, thread: thread} do
      turn = accept!(actor, thread)
      assert turn.recovery_limit == nil

      {:ok, started} = TurnStorage.start(actor, turn.id, %{fence: turn.fence, recovery_limit: 5})
      assert started.recovery_limit == 5
    end
  end

  describe "the origin" do
    setup tags do
      Arca.Test.Sandbox.setup!(tags)
      Arca.Test.Actor.athanor!()
      actor = Arca.Test.Actor.local()
      {:ok, thread} = Threads.create(actor)
      {:ok, actor: actor, thread: thread}
    end

    test "an accepted turn keeps the origin it was admitted under, read back as a restart reads it",
         %{actor: actor, thread: thread} do
      assert {:ok, %{turn: turn}} =
               TurnStorage.accept_message(actor, thread.id, %{
                 message: %{
                   author: actor.user_id,
                   sent_by: "person",
                   content: "@aqua go",
                   client_id: "cli_origin"
                 },
                 turn: %{agent: "aqua", requested_by: actor.user_id, origin: :programmatic}
               })

      assert turn.origin == "programmatic"
      assert Arca.Repo.get!(Turn, turn.id).origin == "programmatic"

      assert {:ok, %{turn: %{origin: "programmatic"}}} =
               TurnStorage.accepted(actor, thread.id, "cli_origin")
    end

    test "a turn naming none is refused with nothing written; one outside the enum is refused",
         %{actor: actor, thread: thread} do
      before = length(Threads.messages(actor, thread.id))

      for named <- [%{}, %{origin: nil}] do
        assert {:error, :no_origin} =
                 TurnStorage.accept_message(actor, thread.id, %{
                   message: %{author: actor.user_id, sent_by: "person", content: "@aqua go"},
                   turn: Map.merge(%{agent: "aqua", requested_by: actor.user_id}, named)
                 })
      end

      # The message and the turn are one acceptance: neither was written.
      assert length(Threads.messages(actor, thread.id)) == before
      assert {:ok, []} = TurnStorage.open_turns(actor, thread.id)

      assert {:error, {:invalid, %{origin: _}}} =
               TurnStorage.accept_message(actor, thread.id, %{
                 message: %{author: actor.user_id, sent_by: "person", content: "@aqua go"},
                 turn: %{agent: "aqua", requested_by: actor.user_id, origin: "batch"}
               })
    end
  end

  defp accept!(actor, thread) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: actor.user_id, sent_by: "person", content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
      })

    turn
  end
end
