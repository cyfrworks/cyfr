# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.ReservationsTest do
  @moduledoc """
  A reservation's lifecycle, whole: every event against every state, with
  the state, the held bytes, the pool's uids and the endings after it, and
  then every exit a session can meet, as the events the owner table hears
  for it, asserting the same after each. `Locus.Backends.OwnersTest`
  drives the same exits through the table and its launchers.
  """

  use ExUnit.Case, async: true

  alias Locus.Backends.Reservations

  @bytes 268_435_456
  @key {:owner, "ss_one"}
  @tag_ %{
    ledger: :ledger,
    session: @key,
    athanor: "ath_one",
    memory_bytes: @bytes,
    home_id: nil
  }

  # The states a reservation can be in, by name, and none.
  defp in_state(:absent), do: Reservations.new()
  defp in_state(:reserved), do: Reservations.reserve(Reservations.new(), @tag_)

  defp in_state(state) when state in [:asked, :running],
    do: put(%{tag: @tag_, state: state, fence: nil})

  defp in_state({:ending, fence}), do: put(%{tag: @tag_, state: :ending, fence: fence})

  defp put(reservation), do: %{@key => reservation}

  # What a reservation is, by the same names.
  defp state_of(reservations) do
    case reservations[@key] do
      nil -> :released
      %{state: :ending, fence: fence} -> {:ending, fence}
      %{state: state} -> state
    end
  end

  @states [
    :absent,
    :reserved,
    :asked,
    :running,
    {:ending, :unasked},
    {:ending, :asking},
    {:ending, :pending}
  ]

  @events [
    :started,
    :abandoned,
    :spawned,
    :confirmed,
    :unfollowed,
    :heir,
    :asking,
    {:fence, :none},
    {:fence, :pending},
    {:fence, :failed},
    :adopted
  ]

  # Every cell: the state after the event, `:same` for none moved, and
  # `:released` for a reservation gone. `:absent` never comes back but by
  # an adoption.
  @matrix %{
    absent: [
      started: :same,
      abandoned: :same,
      spawned: :same,
      confirmed: :same,
      unfollowed: :same,
      heir: :same,
      asking: :same,
      fence_none: :same,
      fence_pending: :same,
      fence_failed: :same,
      adopted: {:ending, :unasked}
    ],
    reserved: [
      started: :asked,
      abandoned: :released,
      spawned: :same,
      confirmed: :same,
      unfollowed: :same,
      heir: :same,
      asking: :same,
      fence_none: :same,
      fence_pending: :same,
      fence_failed: :same,
      adopted: :same
    ],
    asked: [
      started: :same,
      abandoned: :same,
      spawned: :running,
      confirmed: :released,
      unfollowed: {:ending, :unasked},
      heir: :released,
      asking: :same,
      fence_none: :same,
      fence_pending: :same,
      fence_failed: :same,
      adopted: :same
    ],
    running: [
      started: :same,
      abandoned: :same,
      spawned: :same,
      confirmed: :released,
      unfollowed: {:ending, :unasked},
      heir: :released,
      asking: :same,
      fence_none: :same,
      fence_pending: :same,
      fence_failed: :same,
      adopted: :same
    ],
    ending_unasked: [
      started: :same,
      abandoned: :same,
      spawned: :same,
      confirmed: :released,
      unfollowed: :same,
      heir: :released,
      asking: {:ending, :asking},
      fence_none: :released,
      fence_pending: :same,
      fence_failed: :same,
      adopted: :same
    ],
    ending_asking: [
      started: :same,
      abandoned: :same,
      spawned: :same,
      confirmed: :released,
      unfollowed: :same,
      heir: :released,
      asking: :same,
      fence_none: :released,
      fence_pending: {:ending, :pending},
      fence_failed: {:ending, :unasked},
      adopted: :same
    ],
    ending_pending: [
      started: :same,
      abandoned: :same,
      spawned: :same,
      confirmed: :released,
      unfollowed: :same,
      heir: :released,
      asking: {:ending, :asking},
      fence_none: :released,
      fence_pending: :same,
      fence_failed: :same,
      adopted: :same
    ]
  }

  defp row({:ending, :unasked}), do: :ending_unasked
  defp row({:ending, :asking}), do: :ending_asking
  defp row({:ending, :pending}), do: :ending_pending
  defp row(state), do: state

  defp column({:fence, :none}), do: :fence_none
  defp column({:fence, :pending}), do: :fence_pending
  defp column({:fence, :failed}), do: :fence_failed
  defp column(event), do: event

  defp event(:adopted), do: {:adopted, @tag_}
  defp event(event), do: event

  # What a reservation in `state` holds: its bound in every state, a
  # scratch session's uid in every state but `reserved`, and an ending
  # only as `ending`.
  defp holds(state) do
    %{
      bytes: if(state in [:absent, :released], do: 0, else: @bytes),
      uids: if(state in [:absent, :released, :reserved], do: 0, else: 1),
      endings: if(match?({:ending, _}, state), do: 1, else: 0)
    }
  end

  defp held(reservations) do
    %{
      bytes: Reservations.held_bytes(reservations),
      uids: Reservations.uids(reservations),
      endings: map_size(Reservations.endings(reservations))
    }
  end

  test "every event against every state moves it as the table says, holding what that state holds" do
    for state <- @states, event <- @events do
      expected =
        case Keyword.fetch!(@matrix[row(state)], column(event)) do
          :same -> if state == :absent, do: :released, else: state
          next -> next
        end

      after_event = Reservations.event(in_state(state), @key, event(event))

      assert state_of(after_event) == expected,
             "#{inspect(state)} on #{inspect(event)}: #{inspect(state_of(after_event))}"

      assert held(after_event) == holds(expected), "#{inspect(state)} on #{inspect(event)}"
    end
  end

  test "the matrix names every event for every state, and nothing else" do
    for state <- @states do
      assert Keyword.keys(@matrix[row(state)]) == Enum.map(@events, &column/1)
    end

    assert map_size(@matrix) == length(@states)
  end

  # Every exit a session meets, as the events the owner table hears for
  # it, and what is held after each: an exit no event marks (a caller
  # gone, a release timeout) moves nothing.
  @exits [
    {"the caller of an open goes away while its home is made", :reserved, [], []},
    {"an open refused before its session process starts", :reserved, [:abandoned], [:released]},
    {"an open that finds its key's session started meanwhile", :reserved, [:abandoned],
     [:released]},
    {"a session refused by its launcher", :reserved, [:started, :confirmed], [:asked, :released]},
    {"a session that runs and ends", :reserved, [:started, :spawned, :confirmed],
     [:asked, :running, :released]},
    {"a release that times out", :running, [], []},
    {"a spawn whose call timed out, then retired", :asked,
     [:unfollowed, :asking, {:fence, :pending}, :heir],
     [{:ending, :unasked}, {:ending, :asking}, {:ending, :pending}, :released]},
    {"a session process that dies before it asks", :asked,
     [:unfollowed, :asking, {:fence, :none}],
     [{:ending, :unasked}, {:ending, :asking}, :released]},
    {"a session process that dies after it asks", :running,
     [:unfollowed, :asking, {:fence, :pending}, :asking, {:fence, :pending}, :heir],
     [
       {:ending, :unasked},
       {:ending, :asking},
       {:ending, :pending},
       {:ending, :asking},
       {:ending, :pending},
       :released
     ]},
    {"an owner retired with its session running", :running, [:unfollowed, :asking, :heir],
     [{:ending, :unasked}, {:ending, :asking}, :released]},
    {"a fence its launcher could not answer, asked again", :asked,
     [:unfollowed, :asking, {:fence, :failed}, :asking, {:fence, :none}],
     [{:ending, :unasked}, {:ending, :asking}, {:ending, :unasked}, {:ending, :asking}, :released]},
    {"a table restarted while the process runs", :absent,
     [{:adopted, @tag_}, :asking, {:fence, :pending}, :heir],
     [{:ending, :unasked}, {:ending, :asking}, {:ending, :pending}, :released]},
    {"a table restarted, the release heard before its adoption", :absent,
     [:heir, {:adopted, @tag_}, :asking, {:fence, :none}],
     [:released, {:ending, :unasked}, {:ending, :asking}, :released]},
    {"an adoption asked again names a process released since", :absent,
     [{:adopted, @tag_}, :heir, {:adopted, @tag_}, :asking, {:fence, :none}],
     [{:ending, :unasked}, :released, {:ending, :unasked}, {:ending, :asking}, :released]},
    {"a fenced session whose request arrives late", :asked,
     [:unfollowed, :asking, {:fence, :none}, :spawned, :confirmed, :heir],
     [{:ending, :unasked}, {:ending, :asking}, :released, :released, :released, :released]}
  ]

  test "every exit holds the session's bound until its launcher or its fence settles it" do
    for {name, start, events, states} <- @exits do
      assert length(events) == length(states), name

      Enum.zip(events, states)
      |> Enum.reduce(in_state(start), fn {event, expected}, reservations ->
        reservations = Reservations.event(reservations, @key, event)
        assert state_of(reservations) == expected, "#{name}: #{inspect(event)}"
        assert held(reservations) == holds(expected), "#{name}: #{inspect(event)}"
        reservations
      end)
      |> then(fn reservations ->
        if events == [], do: assert(state_of(reservations) == start, name)
      end)
    end
  end
end
