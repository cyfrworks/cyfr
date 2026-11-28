# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.EventsTest do
  @moduledoc """
  The forwarder of the runners' operator events: one queue for every
  runner, posted in batches of at most `Prima.HostAPI.max_report_events/0`,
  a full one at once and a short one after its first event's wait; one
  batch in flight at a time, none before the service serves; a batch that
  reached no connection sent again whole and first, one whose answer was
  lost never again; and, while CYFR cannot be reached, at most 1,024
  events held, the oldest dropped first and the count said once, when a
  batch reaches CYFR again. Each test's forwarder posts to the test
  itself, which answers each post as the case needs.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Locus.Runtime.Events

  @batch Prima.HostAPI.max_report_events()
  @boot "boot_events_test"

  setup do
    test = self()

    # Each post is told to the test, which answers it: the post waits for
    # that answer, as a post waits for CYFR's.
    post = fn credentials, boot, events ->
      send(test, {:posted, self(), credentials, boot, events})

      receive do
        {:answer, answer} -> answer
      end
    end

    events = start_supervised!({Events, post: post, flush_ms: 50, name: nil})
    {:ok, events: events, credentials: %{service_id: "wrk_events"}}
  end

  defp event(n) do
    %{
      type: :event,
      name: "formula.cancel",
      measurements: %{system_time: n},
      metadata: %{parent_execution_id: "exec_events", task_id: "task_#{n}"}
    }
  end

  defp forward(events, range), do: Enum.each(range, &Events.forward(events, event(&1)))

  defp posted(n) do
    assert_receive {:posted, poster, _credentials, @boot, events}, 5_000
    assert Enum.map(events, & &1.measurements.system_time) == Enum.to_list(n)
    poster
  end

  defp answer(poster, answer), do: send(poster, {:answer, answer})

  test "posts nothing before the service serves, then a short batch after its first event's wait",
       %{events: events, credentials: credentials} do
    forward(events, 1..3)
    refute_receive {:posted, _, _, _, _}, 200
    :ok = Events.serve(events, credentials, @boot)

    assert_receive {:posted, poster, ^credentials, @boot, batch}, 5_000
    assert Enum.map(batch, & &1.measurements.system_time) == [1, 2, 3]
    answer(poster, :ok)
  end

  test "a full batch goes at once, and the next waits for the one in flight",
       %{events: events, credentials: credentials} do
    :ok = Events.serve(events, credentials, @boot)
    forward(events, 1..(@batch * 2 + 1))

    first = posted(1..@batch)
    # One batch in flight at a time: the next goes when this one answers.
    refute_receive {:posted, _, _, _, _}, 200
    answer(first, :ok)

    second = posted((@batch + 1)..(@batch * 2))
    answer(second, :ok)

    last = posted((@batch * 2 + 1)..(@batch * 2 + 1))
    answer(last, :ok)
  end

  test "a batch that reached no connection goes again, whole and first; one whose answer was " <>
         "lost never again",
       %{events: events, credentials: credentials} do
    :ok = Events.serve(events, credentials, @boot)
    forward(events, 1..2)

    unsent = posted(1..2)
    forward(events, 3..4)
    answer(unsent, {:error, :unsent})

    again = posted(1..4)

    log =
      capture_log(fn ->
        answer(
          again,
          {:error, {:uncertain, "The call's answer was lost and its effect is unknown"}}
        )

        refute_receive {:posted, _, _, _, _}, 300
      end)

    assert log =~ "a batch of 4 runner events was not reported"
    assert log =~ "it is not sent again"

    forward(events, 5..5)
    after_lost = posted(5..5)
    answer(after_lost, :ok)
  end

  test "while CYFR cannot be reached it holds 1,024 events, the oldest dropped first, and says " <>
         "once how many it dropped",
       %{events: events, credentials: credentials} do
    :ok = Events.serve(events, credentials, @boot)
    forward(events, 1..1)
    in_flight = posted(1..1)

    # 1,100 more arrive while the first batch is in flight, which then
    # reached no connection and goes back to the queue's head.
    forward(events, 2..1_101)
    answer(in_flight, {:error, :unsent})

    # Of 1,101 held, the oldest 77 are dropped: 1,024 remain, 78 to 1,101.
    first = posted(78..(78 + @batch - 1))

    log =
      capture_log(fn ->
        answer(first, :ok)
        assert_receive {:posted, next, _, _, _}, 5_000
        answer(next, :ok)
      end)

    assert log =~ "77 runner events were dropped while CYFR could not be reached"
    assert length(String.split(log, "were dropped")) == 2
  end

  test "a status or crash report shows no credential and no event", %{
    events: events,
    credentials: credentials
  } do
    :ok = Events.serve(events, credentials, @boot)
    forward(events, 1..3)
    poster = posted(1..3)
    status = :sys.get_status(events)
    {:status, _pid, _module, [_pdict, _sys, _parent, _debug, data]} = status
    refute inspect(data) =~ "wrk_events"
    refute inspect(data) =~ "task_1"
    answer(poster, :ok)
  end
end
