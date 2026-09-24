# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.StreamTest do
  @moduledoc """
  A reader that fails over to the other member, and the order it sees.

  `cell-ownership.md` §5 makes one thing about SSE non-optional:
  **`Last-Event-ID` replay must read the durable `execution_events` rows
  when the per-member buffer does not hold the id**, so a reader that
  fails over to another member sees the same order. The per-member buffer
  is a cache of the last events of a stream on the member that produced
  them; a peer has none, and a reader that reconnected there would see a
  gap if the replay came from the buffer alone.

  The live half is the other direction: the stream's topic is on the
  bus (`Cyfr.Bus`, over `Cyfr.PubSub`), which spans the cell's members, so
  a reader attached to one member follows an execution running on the
  other.
  """

  use Cyfr.Cluster.Case, async: false

  describe "a reader that fails over" do
    test "is replayed the same durable order by the member that produced none of it" do
      athanor = Cell.call(:a, Cyfr.Cluster.Fixtures, :athanor!, ["stream"])
      stream = Cell.call(:a, Cyfr.Cluster.Fixtures, :stream!, [athanor.id, 4])

      # `admit/2` writes `execution.started` as seq 1, and the fixture
      # four more, so the whole stream is 1..5.
      rows = Observer.events(stream.id)
      assert Enum.map(rows, & &1["seq"]) == [1, 2, 3, 4, 5]

      # The member that produced the stream replays it from its own
      # buffer and its rows together.
      home = Cell.call(:a, Cyfr.Cluster.Fixtures, :replay, [athanor.id, stream.id, 0])

      # The peer produced none of it and holds no buffer for it. What it
      # replays must be the same durable order, or a reader that failed
      # over would see a different stream.
      away = Cell.call(:b, Cyfr.Cluster.Fixtures, :replay, [athanor.id, stream.id, 0])

      assert away == ["1", "2", "3", "4", "5"],
             "the peer replayed #{inspect(away)} where the rows say 1..5"

      assert durables(home) == durables(away),
             "the two members replay different durable orders: #{inspect(home)} vs #{inspect(away)}"

      # And a cursor is honoured on the peer exactly as on the member that
      # produced the stream: resuming from 3 replays 4 and 5.
      assert Cell.call(:b, Cyfr.Cluster.Fixtures, :replay, [athanor.id, stream.id, 3]) ==
               ["4", "5"]

      assert Cell.call(:b, Cyfr.Cluster.Fixtures, :replay, [athanor.id, stream.id, 5]) == []
    end

    test "follows an execution on the other member while it runs" do
      athanor = Cell.call(:a, Cyfr.Cluster.Fixtures, :athanor!, ["stream-live"])
      stream = Cell.call(:a, Cyfr.Cluster.Fixtures, :stream!, [athanor.id, 1])

      # A reader attached to the peer subscribes to the stream's topic;
      # the topic is the cell's, not a member's.
      assert Cell.call(:b, Cyfr.Cluster.Boot, :watch_stream!, [athanor.id, stream.id]) == :ok

      # The execution goes on producing on the member that holds it.
      more = Cell.call(:a, Cyfr.Cluster.Fixtures, :stream_more!, [athanor.id, stream.id, 2])

      expected = Enum.map(more, &Integer.to_string/1)

      # An event published before the subscription landed may still reach
      # the peer after it — the member forwards to its peer's PubSub
      # asynchronously — so what was heard first is not asserted; what was
      # published after the reader attached must arrive, in order, last.
      heard =
        Wait.until!(
          fn ->
            seen = Cell.call(:b, Cyfr.Cluster.Boot, :stream_heard, [])
            if Enum.all?(expected, &(&1 in seen)), do: seen
          end,
          "the reader on the peer never heard the execution's events",
          15_000
        )

      assert Enum.take(heard, -length(expected)) == expected,
             "the peer heard #{inspect(heard)} where the member published #{inspect(more)}"

      assert Enum.all?(durables(heard), &(String.to_integer(&1) <= List.last(more))),
             "the peer heard #{inspect(heard)} where the member published #{inspect(more)}"
    end
  end

  # A replay is durable rows with the deltas buffered under each; the
  # durable prefix is what the two members must agree on.
  defp durables(ids),
    do: Enum.map(ids, fn id -> id |> String.split(".") |> hd() end)
end
