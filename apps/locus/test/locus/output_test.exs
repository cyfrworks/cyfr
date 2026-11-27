# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.OutputTest do
  @moduledoc """
  The one count of a role's output, on counts of the suite's own: what a
  holder holds unread and what it was granted to answer, freed only on the
  holder's word or its death.
  """
  use ExUnit.Case, async: true

  import Prima.Test.Wait

  alias Locus.Output

  @kib 1024

  defp start(bounds), do: start_supervised!({Output, bounds: bounds})

  defp later(ms), do: System.monotonic_time(:millisecond) + ms

  # A process standing for a holder: it does what it is told, and tells
  # the test what Output sent it.
  defp holder(output) do
    test = self()

    spawn_link(fn -> holder_loop(output, test) end)
  end

  defp holder_loop(output, test) do
    receive do
      {:hold, bytes} ->
        send(test, {self(), :held, Output.hold(output, bytes)})
        holder_loop(output, test)

      {:reserve, bytes, deadline} ->
        send(test, {self(), :reserved, Output.reserve(output, bytes, deadline)})
        holder_loop(output, test)

      {:reserve, bytes, deadline, opts} ->
        send(test, {self(), :reserved, Output.reserve(output, bytes, deadline, opts)})
        holder_loop(output, test)

      {:return, grant} ->
        Output.return(grant)
        send(test, {self(), :returned})
        holder_loop(output, test)

      {Output, :over} ->
        send(test, {self(), :over})
        holder_loop(output, test)

      :stop ->
        :ok
    end
  end

  defp assert_held(output, expected) do
    held = Output.held(output)

    for {key, value} <- expected,
        do: assert(held[key] == value, "#{key} is #{held[key]}, not #{value}")
  end

  defp hold(pid, bytes) do
    send(pid, {:hold, bytes})
    assert_receive {^pid, :held, answer}
    answer
  end

  test "the roles' bounds are 2.9's numbers" do
    mib = 1_048_576

    assert Output.bounds() == %{
             backends: %{unread: 64 * mib, answering: 26 * mib},
             runtime: %{unread: nil, answering: 16 * mib},
             builds: %{unread: nil, answering: 8 * mib}
           }
  end

  describe "unread" do
    test "within its bound every hold is answered :ok, and the count is the holders' sum" do
      output = start(%{unread: 100 * @kib, answering: @kib})
      [a, b] = [holder(output), holder(output)]

      assert hold(a, 40 * @kib) == :ok
      assert hold(b, 60 * @kib) == :ok
      assert_held(output, unread: 100 * @kib, owed: 0)

      assert hold(a, 10 * @kib) == :ok
      assert_held(output, unread: 70 * @kib, unread_peak: 100 * @kib)
    end

    test "past its bound the caller holding most drops to the bound at once" do
      output = start(%{unread: 100 * @kib, answering: @kib})
      [a, b] = [holder(output), holder(output)]

      assert hold(b, 30 * @kib) == :ok
      assert hold(a, 90 * @kib) == {:drop_to, 70 * @kib}
      assert %{owed: owed} = Output.held(output)
      assert owed == 20 * @kib

      assert hold(a, 70 * @kib) == :ok
      assert_held(output, unread: 100 * @kib, owed: 0)
    end

    test "past its bound another holding most is told, the count is over until it holds again, " <>
           "and no holder told is told again before then" do
      output = start(%{unread: 100 * @kib, answering: @kib})
      [big, small, other] = [holder(output), holder(output), holder(output)]

      assert hold(big, 80 * @kib) == :ok
      assert hold(small, 20 * @kib) == :ok

      # The small one's increment passes the bound: the big one owes it.
      assert hold(small, 25 * @kib) == :ok
      assert_receive {^big, :over}
      assert_held(output, unread: 105 * @kib, owed: 5 * @kib)

      # The next increment is assigned to the one holding most of those
      # owing nothing, here the small one: no holder is told twice.
      assert hold(other, 10 * @kib) == :ok
      assert_receive {^small, :over}
      refute_received {^big, :over}
      assert_held(output, unread: 115 * @kib, owed: 15 * @kib, owing: 2)

      # The count never passes its bound by more than what the holders
      # told owe, one increment each.
      assert %{unread_peak: peak} = Output.held(output)
      assert peak == 100 * @kib + 5 * @kib + 10 * @kib

      # Each holds again once it has dropped what it owes.
      assert hold(small, 15 * @kib) == :ok
      assert hold(big, 75 * @kib) == :ok
      assert_held(output, unread: 100 * @kib, owed: 0, owing: 0)
    end

    test "the count's excess is at most one increment for each holder told and not yet heard from" do
      bound = 72 * @kib
      increment = @kib
      output = start(%{unread: bound, answering: @kib})

      # Eight holders of 2 to 16 KiB, at the bound together, the smallest
      # first; none acts on being told, as a session whose turn has not
      # come, until its own turn.
      holders = for _ <- 1..8, do: holder(output)
      held = holders |> Enum.with_index(1) |> Map.new(fn {pid, i} -> {pid, i * 2 * @kib} end)
      for pid <- holders, do: assert(hold(pid, held[pid]) == :ok)

      # Each in turn takes one more increment. A caller holding most of
      # those owing nothing drops at once; any other is told and owes the
      # increment until it holds again.
      for _round <- 1..3, pid <- holders, reduce: held do
        held ->
          bytes = held[pid] + increment

          held =
            case hold(pid, bytes) do
              :ok ->
                Map.put(held, pid, bytes)

              {:drop_to, to} ->
                assert hold(pid, to) == :ok
                Map.put(held, pid, to)
            end

          %{unread: unread, owed: owed, owing: owing} = Output.held(output)
          assert unread == held |> Map.values() |> Enum.sum()
          assert unread - owed <= bound
          assert owed <= owing * increment
          assert unread <= bound + owing * increment
          held
      end

      assert_receive {_told, :over}, 1_000, "some holder was told and did not act"
      assert %{unread_peak: peak} = Output.held(output)
      assert peak <= bound + length(holders) * increment
    end

    test "a holder told to drop that holds again without dropping still owes, " <>
           "and is told in its own call: its debt passes to no one" do
      output = start(%{unread: 100 * @kib, answering: @kib})
      [a, b, c, d] = for _ <- 1..4, do: holder(output)

      assert hold(a, 41 * @kib) == :ok
      assert hold(b, 39 * @kib) == :ok
      assert hold(c, 20 * @kib) == :ok

      # C's increment passes the bound: A holds most and is told.
      assert hold(c, 25 * @kib) == :ok
      assert_receive {^a, :over}
      assert_held(output, owed: 5 * @kib, owing: 1)

      # The others' readers take theirs; D grows past what A holds, within
      # the bound.
      assert hold(b, 0) == :ok
      assert hold(c, 0) == :ok
      assert hold(d, 64 * @kib) == :ok

      # A holds more before it read that it was told: it still owes, now
      # its own increment too, and drops in its own call; D is told nothing.
      assert hold(a, 42 * @kib) == {:drop_to, 36 * @kib}
      refute_received {^d, :over}
      assert_held(output, owed: 6 * @kib, owing: 1)

      assert hold(a, 36 * @kib) == :ok
      assert_held(output, unread: 100 * @kib, owed: 0, owing: 0)
    end

    test "a holder that dies holds nothing more, and owes nothing" do
      output = start(%{unread: 100 * @kib, answering: @kib})
      [a, b] = [holder(output), holder(output)]

      assert hold(a, 90 * @kib) == :ok
      assert hold(b, 20 * @kib) == :ok
      assert_receive {^a, :over}

      ref = Process.monitor(a)
      Process.unlink(a)
      Process.exit(a, :kill)
      assert_receive {:DOWN, ^ref, :process, ^a, :killed}

      assert_held(output, unread: 20 * @kib, owed: 0)
    end
  end

  describe "answering" do
    test "a grant is counted until its holder returns it, and asks are granted in arrival order" do
      output = start(%{answering: 100 * @kib})
      [a, b, c] = [holder(output), holder(output), holder(output)]

      send(a, {:reserve, 70 * @kib, later(5_000)})
      assert_receive {^a, :reserved, {:ok, grant_a}}

      # 50 does not fit beside 70; 10 would, but, asked after it, waits
      # behind it.
      send(b, {:reserve, 50 * @kib, later(5_000)})
      wait_until(fn -> Output.held(output).waiting == 1 end, 5_000, "the first ask queued")
      send(c, {:reserve, 10 * @kib, later(5_000)})
      wait_until(fn -> Output.held(output).waiting == 2 end, 5_000, "the second ask queued")
      refute_received {_, :reserved, _}
      assert_held(output, answering: 70 * @kib, waiting: 2)

      send(a, {:return, grant_a})
      assert_receive {^b, :reserved, {:ok, _grant_b}}
      assert_receive {^c, :reserved, {:ok, _grant_c}}
      assert_held(output, answering: 60 * @kib, waiting: 0, answering_peak: 70 * @kib)
    end

    test "an ask with no room by its deadline is :full, and one past the bound is :full at once" do
      output = start(%{answering: 100 * @kib})
      [a, b] = [holder(output), holder(output)]

      send(a, {:reserve, 100 * @kib, later(5_000)})
      assert_receive {^a, :reserved, {:ok, _grant}}

      send(b, {:reserve, @kib, later(300)})
      assert_receive {^b, :reserved, :full}, 2_000

      assert Output.reserve(output, 100 * @kib + 1, later(5_000)) == :full
      assert_held(output, answering: 100 * @kib, waiting: 0)
    end

    test "a holder's death frees its grants, and a given grant is its new holder's" do
      output = start(%{answering: 100 * @kib})
      [a, b] = [holder(output), holder(output)]

      send(a, {:reserve, 60 * @kib, later(5_000)})
      assert_receive {^a, :reserved, {:ok, grant}}

      # Given to the test: the giver's death no longer frees it.
      :ok = Output.give(grant, self())
      ref = Process.monitor(a)
      Process.unlink(a)
      Process.exit(a, :kill)
      assert_receive {:DOWN, ^ref, :process, ^a, :killed}
      assert_held(output, answering: 60 * @kib)

      send(b, {:reserve, 60 * @kib, later(5_000)})
      refute_receive {^b, :reserved, _}, 200

      # Given to a process that dies, it goes with it.
      dying = spawn(fn -> receive do: (:go -> :ok) end)
      :ok = Output.give(grant, dying)
      send(dying, :go)
      assert_receive {^b, :reserved, {:ok, _grant}}
      assert_held(output, answering: 60 * @kib)
    end

    test "a waiter that dies is no longer waited for" do
      output = start(%{answering: 100 * @kib})
      [a, b, c] = [holder(output), holder(output), holder(output)]

      send(a, {:reserve, 100 * @kib, later(5_000)})
      assert_receive {^a, :reserved, {:ok, grant}}
      send(b, {:reserve, 80 * @kib, later(5_000)})
      send(c, {:reserve, 10 * @kib, later(5_000)})
      refute_receive {_, :reserved, _}, 200

      ref = Process.monitor(b)
      Process.unlink(b)
      Process.exit(b, :kill)
      assert_receive {:DOWN, ^ref, :process, ^b, :killed}

      send(a, {:return, grant})
      assert_receive {^c, :reserved, {:ok, _grant}}
      assert_held(output, answering: 10 * @kib, waiting: 0)
    end

    test "an ask that leaves room is granted only while that much stays free beside it, " <>
           "behind every ask that leaves none, and one past the bound with what it leaves is :full at once" do
      output = start(%{answering: 100 * @kib})
      [a, b, c, d, e] = for _n <- 1..5, do: holder(output)

      # On an empty count: it could never be granted, so it is not waited for.
      assert Output.reserve(output, 60 * @kib + 1, later(60_000), leave: 40 * @kib) == :full

      send(a, {:reserve, 50 * @kib, later(5_000)})
      assert_receive {^a, :reserved, {:ok, grant_a}}

      # 30 fits beside 50, but not with 40 left free beside it.
      send(b, {:reserve, 30 * @kib, later(300), [leave: 40 * @kib]})
      assert_receive {^b, :reserved, :full}, 2_000

      # One that leaves none waits for room; one that leaves room, and
      # would fit, waits behind it.
      send(c, {:reserve, 60 * @kib, later(5_000)})
      wait_until(fn -> Output.held(output).waiting == 1 end, 5_000, "the ask queued")
      send(b, {:reserve, 10 * @kib, later(5_000), [leave: 30 * @kib]})
      wait_until(fn -> Output.held(output).waiting == 2 end, 5_000, "the ask leaving room queued")
      refute_received {_, :reserved, _}

      send(a, {:return, grant_a})
      assert_receive {^c, :reserved, {:ok, _grant_c}}
      assert_receive {^b, :reserved, {:ok, grant_b}}
      assert_held(output, answering: 70 * @kib, waiting: 0)

      # One that leaves room and waits never stands ahead of one that
      # leaves none and fits.
      send(d, {:reserve, 20 * @kib, later(5_000), [leave: 20 * @kib]})
      wait_until(fn -> Output.held(output).waiting == 1 end, 5_000, "the ask leaving room queued")
      send(e, {:reserve, 30 * @kib, later(5_000)})
      assert_receive {^e, :reserved, {:ok, grant_e}}
      assert_held(output, answering: 100 * @kib, waiting: 1)

      send(e, {:return, grant_e})
      refute_receive {^d, :reserved, _}, 200
      send(b, {:return, grant_b})
      assert_receive {^d, :reserved, {:ok, _grant_d}}
      assert_held(output, answering: 80 * @kib, waiting: 0)
    end
  end
end
