# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.PersonTest do
  @moduledoc """
  A person's work on a cell of two members, entered by the doors a person
  has (`Cyfr.Cluster.Person`): a turn sent through the runner, a card
  decided through the approvals door, a crew member asked by its `@name`,
  a consent walked through plan, preview and commit, and a schedule made
  through the gate. Each case does part of that work on one member and
  asks the other what became of it, since a person's next request can
  land on either.

  The model is the shipped Claude catalyst on each member's scripted
  worker service, so the component is the only stand-in; the turns, the
  crew's delivery, the consent proof and the scheduler are the members'
  own, at their shipped settings.
  """

  use Cyfr.Cluster.Case, async: false

  alias Cyfr.Cluster.Person

  # A member's slot lease and its renewal tick (`cell_test.exs`): a killed
  # member's slot is takeable within their sum.
  @slot_bound_ms 15_000 + 5_000

  setup do
    seed = Person.seed!()
    for member <- [:a, :b], do: Cell.call(member, Person, :use_seed!, [seed])

    on_exit(fn ->
      for member <- [:a, :b] do
        try do
          Cell.call(member, Cyfr.Cluster.Boot, :stop_worker!, [])
        catch
          _kind, _reason -> :ok
        end
      end
    end)

    person = Cell.call(:a, Person, :person!, [], 180_000)
    {:ok, person: person}
  end

  describe "a person's turn" do
    test "completes on the other member after the member running it dies", %{person: person} do
      thread = Cell.call(:a, Person, :thread!, [person.token])

      # The member running the turn holds its model call until it dies;
      # the other answers the call it makes when it carries the turn on.
      worker!(:a, [{:sleep, 600_000}, reply("from the member that died")])
      worker!(:b, [reply("carried on")])

      assert {:ok, %{turn_id: turn_id}} =
               Cell.call(:a, Person, :send, [person.token, thread, "@aqua go"])

      Wait.until!(
        fn -> Cell.call(:a, Cyfr.Test.ScriptedWorker, :calls, []) != [] end,
        "the turn's model call never reached the first member's worker"
      )

      assert Observer.turn(turn_id)["status"] == "running"
      Cell.kill(:a)

      # The person's next request lands on the survivor. It may carry the
      # turn on once the dead member's slot is takeable: until then the
      # rows name a live holder.
      Wait.until!(
        fn -> Observer.takeable?(Cell.member(:a).node) end,
        "the dead member's slot never became takeable",
        @slot_bound_ms * 2
      )

      assert {:ok, _recovered} =
               Cell.call(:b, Person, :call, [
                 person.token,
                 "turn",
                 %{"action" => "recover", "thread" => thread, "turn" => turn_id}
               ])

      Wait.until!(
        fn -> Observer.turn(turn_id)["status"] == "completed" end,
        "the turn never completed on the survivor: #{inspect(Observer.turn(turn_id))}",
        120_000
      )

      messages = Cell.call(:b, Person, :messages, [person.token, thread])
      assert Enum.any?(messages, &(&1.content == "carried on")), inspect(messages)
      refute Enum.any?(messages, &(&1.content == "from the member that died")), inspect(messages)
    end
  end

  describe "a person's card" do
    # Both decisions are a person's, made through the one door a decision
    # has (`Aqua.Approvals.resolve/3`), on a card a real turn paused on;
    # each is one the card would take, so only the decision's own
    # compare-and-set can keep the second from landing.
    test "decided on both members at once, is decided once, and the other reads the winner's decision",
         %{person: person} do
      thread = Cell.call(:a, Person, :thread!, [person.token])
      keep = %{"action" => "keep", "name" => "n", "content" => "x"}
      worker!(:a, [call("c1", "notes", keep), reply("after the card")])

      assert {:ok, %{turn_id: turn_id}} =
               Cell.call(:a, Person, :send, [person.token, thread, "@aqua keep it"])

      [approval] =
        Wait.until!(
          fn ->
            case Cell.call(:b, Person, :pending_approvals, [person.token, turn_id]) do
              [_] = pending -> pending
              _none_yet -> false
            end
          end,
          "the turn never paused on its card"
        )

      results =
        Barrier.race(
          a: {Person, :decide, [person.token, approval, :approved]},
          b: {Person, :decide, [person.token, approval, :declined]}
        )

      decided = for {_member, {:ok, %{replayed: false} = outcome}} <- results, do: outcome
      replayed = for {_member, {:ok, %{replayed: true} = outcome}} <- results, do: outcome

      assert [%{decision: winner}] = decided, inspect(results)
      assert [%{decision: ^winner}] = replayed, inspect(results)
      assert winner in ["approved", "declined"]

      assert %{"status" => ^winner} =
               Observer.row("SELECT status FROM approvals WHERE id = $1", [approval])

      Wait.until!(
        fn -> Observer.turn(turn_id)["status"] == "completed" end,
        "the turn never went on past its decided card: #{inspect(Observer.turn(turn_id))}"
      )
    end
  end

  describe "a person's @name of a crew member" do
    # Both members run the crew's delivery as a shipped member does: woken
    # by the request's commit, at boot and on their tick. Nothing here
    # drains it by hand.
    test "is delivered once across two members, and its one reply lands on the room",
         %{person: person} do
      :ok = Cell.call(:a, Person, :crew_member!, [person.token, "planner"], 120_000)
      room = Cell.call(:a, Person, :thread!, [person.token])

      # Whichever member delivers runs the member's turn, on its own worker.
      for member <- [:a, :b], do: worker!(member, [reply("Plan: read, then write.")])

      assert {:ok, %{admitted: :request, message_id: request}} =
               Cell.call(:a, Person, :send, [person.token, room, "@planner plan the move"])

      Wait.until!(
        fn ->
          Observer.row("SELECT status FROM messages WHERE id = $1", [request])["status"] ==
            "answered"
        end,
        "the request was never answered"
      )

      # One child thread for the member, holding the request once, under
      # one turn; one reply on the room; nothing left to deliver.
      children =
        Observer.rows!(
          "SELECT id FROM threads WHERE parent_id = $1 AND agent = 'planner'",
          [room]
        )

      assert [%{"id" => child}] = children

      delivered =
        Observer.rows!(
          "SELECT turn_id FROM messages WHERE thread_id = $1 AND payload LIKE $2",
          [child, "%#{request}%"]
        )

      assert [%{"turn_id" => child_turn}] = delivered, inspect(delivered)
      assert Observer.turn(child_turn)["status"] == "completed"

      replies =
        Observer.rows!("SELECT content FROM messages WHERE thread_id = $1 AND reply_to = $2", [
          room,
          request
        ])

      assert [%{"content" => "Plan: read, then write."}] = replies

      for kind <- ~w(crew_request crew_reply) do
        assert {:ok, []} =
                 Cell.call(:b, Arca.Outbox, :pending, [
                   Prima.Actor.in_athanor(person.athanor_id),
                   "crew_delivery",
                   kind
                 ])
      end
    end
  end

  describe "a person's consent" do
    test "previewed on one member commits on the other, and its proof is spent cell-wide",
         %{person: person} do
      ref = Person.model()

      decisions = %{
        ref: ref,
        label: "scheduled",
        bindings: [%{need: "api_key", entry_id: person.key_entry_id}],
        origins: [:schedule]
      }

      %{plan: plan, preview: preview} =
        Cell.call(:a, Person, :walk, [person.token, %{ref: ref, label: "scheduled"}, decisions])

      assert {:ok, %{profile_id: profile_id}} =
               Cell.call(:b, Person, :commit, [person.token, decisions, plan, preview])

      assert is_binary(profile_id)

      # The proof is the cell's: spent once on one member, it is spent on
      # the member that made it too.
      assert {:error, _spent} =
               Cell.call(:a, Person, :commit, [person.token, decisions, plan, preview])
    end
  end

  describe "a person's schedule" do
    @tag timeout: 600_000
    test "made through the gate on one member fires once across two, each due time one run",
         %{person: person} do
      # The schedule runs the model catalyst on a profile the person
      # consented for schedules; its input is the catalyst's own question
      # about itself, which the scripted worker answers without a script.
      decisions = %{
        ref: Person.model(),
        label: "scheduled",
        bindings: [%{need: "api_key", entry_id: person.key_entry_id}],
        origins: [:schedule]
      }

      %{plan: plan, preview: preview} =
        Cell.call(:a, Person, :walk, [
          person.token,
          %{ref: Person.model(), label: "scheduled"},
          decisions
        ])

      {:ok, %{profile_id: profile_id}} =
        Cell.call(:a, Person, :commit, [person.token, decisions, plan, preview])

      for member <- [:a, :b], do: worker!(member, [])

      assert {:ok, %{schedule_id: schedule}} =
               Cell.call(:a, Person, :call, [
                 person.token,
                 "schedule",
                 %{
                   "action" => "create",
                   "name" => "every minute",
                   "cron_expression" => "* * * * *",
                   "reference" => Person.model(),
                   "profile_id" => profile_id,
                   "input" => %{"operation" => "models"}
                 }
               ])

      # Both members' schedulers arm it, the one it was made on from its
      # writer and the other from its standing pass.
      Wait.until!(
        fn ->
          Enum.all?([:a, :b], fn member ->
            state = Cell.call(member, :sys, :get_state, [Opus.Schedules.Scheduler])
            Map.has_key?(state.timers, schedule)
          end)
        end,
        "both schedulers to arm the person's schedule",
        180_000
      )

      armed_at = Observer.now()

      Wait.until!(
        fn ->
          Enum.any?(
            Observer.occurrences(schedule),
            &(NaiveDateTime.compare(&1["scheduled_for"], armed_at) == :gt and
                &1["state"] == "completed")
          )
        end,
        "the schedule never fired a run both members had armed: " <>
          inspect(Observer.occurrences(schedule)),
        180_000
      )

      assert {:ok, _paused} =
               Cell.call(:a, Person, :call, [
                 person.token,
                 "schedule",
                 %{"action" => "pause", "schedule_id" => schedule}
               ])

      occurrences = Observer.occurrences(schedule)
      instants = Enum.map(occurrences, & &1["scheduled_for"])
      assert instants == Enum.uniq(instants), inspect(occurrences)

      # Every run the schedule made is one occurrence's, and no
      # occurrence has two.
      ran = for %{"execution_id" => id} <- occurrences, id, do: id
      runs = Observer.rows!("SELECT id FROM executions WHERE schedule_id = $1", [schedule])
      assert Enum.sort(Enum.map(runs, & &1["id"])) == Enum.sort(ran), inspect({runs, occurrences})
      assert ran == Enum.uniq(ran)
    end
  end

  defp worker!(member, script),
    do:
      Cell.call(member, Cyfr.Cluster.Boot, :start_worker!, [[ref: Person.model(), script: script]])

  defp call(id, name, args),
    do: %{
      "content" => [%{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args}],
      "stop_reason" => "tool_call",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
    }

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
    }
end
