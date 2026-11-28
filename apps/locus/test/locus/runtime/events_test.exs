# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.EventsTest do
  @moduledoc """
  The forwarder of the runners' operator events: one queue for every
  runner, posted in batches of at most `Prima.HostAPI.max_report_events/0`,
  a full one at once and a short one after its first event's wait; one
  batch in flight at a time, none before the service serves; a batch that
  reached no connection, or that a member not holding the control plane
  refused `unavailable`, sent again whole and first a wait after its
  answer, the first so kept logged once and the one sent at last once,
  one whose answer was lost or that CYFR refused never again and logged
  once; and, while CYFR cannot be reached, at most 1,024 events held, the
  oldest dropped first, the first drop for room logged and the count said
  once, when a batch reaches CYFR again. Each test's forwarder posts to
  the test itself, which answers each post as the case needs, or through
  the host client to a scripted host.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Prima.Test.Wait

  alias Locus.Runtime.Events
  alias Locus.Runtime.Test.ScriptedHost

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

  # Each batch the scripted host was posted, by its events' times.
  defp batches(host) do
    for %{args: %{"events" => events}} <- ScriptedHost.requests(host, "report_events"),
        do: Enum.map(events, & &1["measurements"]["system_time"])
  end

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
    assert length(String.split(log, "runner events were dropped")) == 2
  end

  test "a member that answers every batch unavailable is said once as a batch is first kept and " <>
         "once as the queue drops for room, never a batch; the batch sent at last says how many " <>
         "were dropped",
       %{events: events, credentials: credentials} do
    :ok = Events.serve(events, credentials, @boot)
    forward(events, 1..2)

    {kept, log} =
      with_log(fn ->
        for _try <- 1..5 do
          answer(posted(1..2), {:error, :unavailable})
        end

        # 1,100 more arrive while the kept batch is in flight again: the
        # queue drops the oldest 76 of them for room, then the kept two
        # as it comes back.
        in_flight = posted(1..2)
        forward(events, 3..1_102)
        answer(in_flight, {:error, :unavailable})
        answer(posted(79..(79 + @batch - 1)), {:error, :unavailable})
        answer(posted(79..(79 + @batch - 1)), {:error, :unavailable})
        posted(79..(79 + @batch - 1))
      end)

    assert log =~
             "[Locus.Runtime.Events] a batch of 2 runner events was not emitted (the member " <>
               "that answered does not hold the control plane); it is kept and sent again"

    assert log =~
             "[Locus.Runtime.Events] the runner events kept for CYFR fill the queue's 1024: " <>
               "the oldest are dropped for room"

    # Once each, though eight batches were kept.
    assert length(String.split(log, "was not emitted")) == 2
    assert length(String.split(log, "dropped for room")) == 2
    refute log =~ "was sent at last"

    log =
      capture_log(fn ->
        # CYFR takes the kept batch at last, and the next.
        answer(kept, :ok)
        answer(posted((79 + @batch)..(79 + 2 * @batch - 1)), :ok)
      end)

    assert log =~
             "[Locus.Runtime.Events] a kept batch of runner events was sent at last; 78 runner " <>
               "events were dropped while CYFR could not be reached"

    assert length(String.split(log, "was sent at last")) == 2
    refute log =~ "was not emitted"
  end

  test "a batch that reached no connection goes again a whole wait after its answer, on one timer",
       %{credentials: credentials} do
    test = self()

    post = fn _credentials, _boot, events ->
      send(test, {:posted_at, self(), events})
      receive do: ({:answer, answer} -> answer)
    end

    events =
      start_supervised!(
        Supervisor.child_spec({Events, post: post, flush_ms: 400, name: nil}, id: :one_timer)
      )

    :ok = Events.serve(events, credentials, @boot)
    forward(events, 1..1)
    assert_receive {:posted_at, first, _batch}, 5_000

    # An event arriving while the batch is in flight arms the wait of its
    # own batch, which has run most of its course when the batch in flight
    # is answered unsent.
    forward(events, 2..2)
    refute_receive {:posted_at, _, _}, 300
    answer(first, {:error, :unsent})

    # The unsent batch goes again a whole wait after its answer, with the
    # event that arrived meanwhile, and once.
    refute_receive {:posted_at, _, _}, 250
    assert_receive {:posted_at, again, batch}, 5_000
    assert Enum.map(batch, & &1.measurements.system_time) == [1, 2]
    answer(again, :ok)
    refute_receive {:posted_at, _, _}, 600
  end

  describe "through the host client" do
    setup %{credentials: _} do
      host = ScriptedHost.start!()
      {:ok, worker_key} = Prima.WorkerAuth.worker_key(host.root, host.service)

      credentials = %Locus.Runtime.Credentials{
        service_id: host.service,
        worker_key: worker_key,
        dispatch_key: Prima.WorkerAuth.dispatch_key(worker_key),
        dispatch_seal_key: Prima.WorkerAuth.dispatch_seal_key(worker_key),
        host_url: host.url,
        bind: {127, 0, 0, 1},
        port: 0
      }

      events =
        start_supervised!(
          Supervisor.child_spec({Events, flush_ms: 50, name: nil}, id: :through_the_client)
        )

      :ok = Events.serve(events, credentials, @boot)
      {:ok, host: host, events: events}
    end

    test "a batch a member that does not hold the control plane refuses, 503 unavailable, is " <>
           "sent again, whole and first, logged once as it is kept and once as it is sent",
         %{host: host, events: events} do
      test = self()

      ScriptedHost.script(host, "report_events", [
        fn _args, _caller ->
          send(test, {:refusing, self()})
          receive do: (:refuse -> {:raw, 503, ~s({"v":3,"error":"unavailable"})})
        end,
        {:ok, true},
        {:ok, true}
      ])

      forward(events, 1..2)
      assert_receive {:refusing, refusing}, 5_000
      forward(events, 3..3)

      log =
        capture_log(fn ->
          send(refusing, :refuse)
          wait_until(fn -> length(batches(host)) == 2 end, 5_000)
          # The next batch goes only once the kept one's answer is read.
          forward(events, 4..4)
          wait_until(fn -> length(batches(host)) == 3 end, 5_000)
        end)

      assert batches(host) == [[1, 2], [1, 2, 3], [4]]

      assert log =~
               "[Locus.Runtime.Events] a batch of 2 runner events was not emitted (the member " <>
                 "that answered does not hold the control plane); it is kept and sent again " <>
                 "until CYFR takes one"

      assert log =~ "[Locus.Runtime.Events] a kept batch of runner events was sent at last"
      assert length(String.split(log, "was not emitted")) == 2
      assert length(String.split(log, "was sent at last")) == 2
      refute log =~ "runner events were dropped"
      refute log =~ "report_events"
    end

    test "a batch the listener refuses is not sent again, and is logged once", %{
      host: host,
      events: events
    } do
      ScriptedHost.script(host, "report_events", {:raw, 400, ~s({"v":3,"error":"malformed"})})

      log =
        capture_log(fn ->
          forward(events, 1..2)
          wait_until(fn -> batches(host) != [] end, 5_000)
          refute_receive :never, 300
        end)

      assert batches(host) == [[1, 2]]
      assert length(String.split(log, "a batch of 2 runner events was not reported")) == 2
      refute log =~ "report_events's answer"
    end
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
