# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.RatesTest do
  use ExUnit.Case, async: false

  import Cyfr.Test.Wait

  alias Cyfr.Execution.Rates

  @table :cyfr_execution_rates

  # Rate limits are keyed by {athanor_id, component_ref}; members of an
  # athanor share its budget. Tests randomize the athanor so cases never
  # collide.
  defp athanor, do: "ath_rl_#{:rand.uniform(100_000)}"

  defp policy(requests, window), do: %{rate_limit: %{requests: requests, window: window}}

  # Rows the table holds for a bucket, read directly (the table is
  # protected, so reads are open and writes are the owner's alone).
  defp rows(athanor_id, component_ref) do
    :ets.select_count(@table, [{{{{athanor_id, component_ref}, :_, :_}, :_}, [], [true]}])
  end

  defp stamps(athanor_id, component_ref) do
    :ets.select(@table, [{{{{athanor_id, component_ref}, :"$1", :_}, :_}, [], [:"$1"]}])
  end

  # The owner's count for a bucket: the invariant is that it equals the
  # bucket's rows, and absent means zero.
  defp owner_count(athanor_id, component_ref) do
    Map.get(:sys.get_state(Rates).counts, {athanor_id, component_ref}, 0)
  end

  # Run `fun` in `n` processes released together: every caller reports
  # ready and spins on one shared flag, so a single write releases them all
  # in the same instant and the claims really race the owner rather than
  # trickling in as the tasks spawn or as messages are delivered.
  defp race(n, fun) do
    parent = self()
    gate = :atomics.new(1, [])

    tasks =
      for i <- 1..n do
        Task.async(fn ->
          send(parent, {:ready, self()})
          spin_until_open(gate)
          fun.(i)
        end)
      end

    for _ <- 1..n do
      receive do
        {:ready, _pid} -> :ok
      after
        5_000 -> flunk("a racing caller never became ready")
      end
    end

    :atomics.put(gate, 1, 1)
    Task.await_many(tasks, 10_000)
  end

  defp spin_until_open(gate) do
    if :atomics.get(gate, 1) == 0, do: spin_until_open(gate)
  end

  setup do
    Arca.Cache.init()

    # Start the rate limiter for this test.
    case GenServer.whereis(Cyfr.Execution.Rates) do
      nil -> {:ok, _} = Cyfr.Execution.Rates.start_link([])
      _pid -> :ok
    end

    :ok
  end

  describe "check/3" do
    test "allows requests under the limit" do
      athanor_id = athanor()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 10, window: "1m"}}

      # First request should succeed with 9 remaining
      assert {:ok, 9} = Rates.check(athanor_id, component_ref, policy)

      # Second request should succeed with 8 remaining
      assert {:ok, 8} = Rates.check(athanor_id, component_ref, policy)

      # Reset for cleanup
      Rates.reset(athanor_id, component_ref)
    end

    test "blocks requests over the limit" do
      athanor_id = athanor()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 3, window: "1m"}}

      # Use up all 3 requests
      assert {:ok, 2} = Rates.check(athanor_id, component_ref, policy)
      assert {:ok, 1} = Rates.check(athanor_id, component_ref, policy)
      assert {:ok, 0} = Rates.check(athanor_id, component_ref, policy)

      # Fourth request should be rate limited
      assert {:error, :rate_limited, retry_after} =
               Rates.check(athanor_id, component_ref, policy)

      assert is_integer(retry_after)
      assert retry_after >= 0

      # Reset for cleanup
      Rates.reset(athanor_id, component_ref)
    end

    test "returns unlimited when no rate limit configured" do
      athanor_id = athanor()
      component_ref = "local.test-component:1.0.0"

      # No rate limit in policy
      assert {:ok, :unlimited} = Rates.check(athanor_id, component_ref, nil)
      assert {:ok, :unlimited} = Rates.check(athanor_id, component_ref, %{})

      assert {:ok, :unlimited} =
               Rates.check(athanor_id, component_ref, %{rate_limit: nil})
    end

    test "different athanors have separate limits" do
      athanor_1 = athanor()
      athanor_2 = athanor()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 2, window: "1m"}}

      # Athanor 1 uses its limit
      assert {:ok, 1} = Rates.check(athanor_1, component_ref, policy)
      assert {:ok, 0} = Rates.check(athanor_1, component_ref, policy)

      assert {:error, :rate_limited, _} =
               Rates.check(athanor_1, component_ref, policy)

      # Athanor 2 still has its full limit
      assert {:ok, 1} = Rates.check(athanor_2, component_ref, policy)
      assert {:ok, 0} = Rates.check(athanor_2, component_ref, policy)

      # Cleanup
      Rates.reset(athanor_1, component_ref)
      Rates.reset(athanor_2, component_ref)
    end

    test "the same component in different athanors has separate limits" do
      # Tenant isolation: two athanors sharing a component must not share a
      # rate-limit budget. Exhausting one must not touch the other.
      athanor_a = athanor()
      athanor_b = athanor()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 2, window: "1m"}}

      # athanor_a exhausts its budget
      assert {:ok, 1} = Rates.check(athanor_a, component_ref, policy)
      assert {:ok, 0} = Rates.check(athanor_a, component_ref, policy)

      assert {:error, :rate_limited, _} =
               Rates.check(athanor_a, component_ref, policy)

      # athanor_b is untouched
      assert {:ok, 1} = Rates.check(athanor_b, component_ref, policy)
      assert {:ok, 0} = Rates.check(athanor_b, component_ref, policy)

      # Cleanup
      Rates.reset(athanor_a, component_ref)
      Rates.reset(athanor_b, component_ref)
    end

    test "different components have separate limits" do
      athanor_id = athanor()
      component1 = "local.component-1:1.0.0"
      component2 = "local.component-2:1.0.0"
      policy = %{rate_limit: %{requests: 2, window: "1m"}}

      # Use up component 1's limit
      assert {:ok, 1} = Rates.check(athanor_id, component1, policy)
      assert {:ok, 0} = Rates.check(athanor_id, component1, policy)
      assert {:error, :rate_limited, _} = Rates.check(athanor_id, component1, policy)

      # Component 2 still has its limit
      assert {:ok, 1} = Rates.check(athanor_id, component2, policy)

      # Cleanup
      Rates.reset(athanor_id, component1)
      Rates.reset(athanor_id, component2)
    end
  end

  describe "reset/3" do
    test "resets the rate limit counter" do
      athanor_id = athanor()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 2, window: "1m"}}

      # Use up the limit
      assert {:ok, 1} = Rates.check(athanor_id, component_ref, policy)
      assert {:ok, 0} = Rates.check(athanor_id, component_ref, policy)

      assert {:error, :rate_limited, _} =
               Rates.check(athanor_id, component_ref, policy)

      # Reset
      :ok = Rates.reset(athanor_id, component_ref)

      # Should have full limit again
      assert {:ok, 1} = Rates.check(athanor_id, component_ref, policy)

      # Cleanup
      Rates.reset(athanor_id, component_ref)
    end

    test "a reset clears the bucket's rows and the owner's count together" do
      athanor_id = athanor()
      component_ref = "local.reset-count:1.0.0"
      policy = policy(5, "1m")

      for _ <- 1..3, do: assert({:ok, _} = Rates.check(athanor_id, component_ref, policy))
      assert rows(athanor_id, component_ref) == 3
      assert owner_count(athanor_id, component_ref) == 3

      assert :ok = Rates.reset(athanor_id, component_ref)

      assert rows(athanor_id, component_ref) == 0
      assert owner_count(athanor_id, component_ref) == 0
      refute Map.has_key?(:sys.get_state(Rates).counts, {athanor_id, component_ref})
    end
  end

  describe "status/3" do
    test "returns current rate limit status" do
      athanor_id = athanor()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 5, window: "1m"}}

      # Check status before any requests
      assert {:ok, 0, 5, _window} = Rates.status(athanor_id, component_ref, policy)

      # Make some requests
      {:ok, _} = Rates.check(athanor_id, component_ref, policy)
      {:ok, _} = Rates.check(athanor_id, component_ref, policy)

      # Status should reflect 2 requests made
      assert {:ok, 2, 3, _window} = Rates.status(athanor_id, component_ref, policy)

      # Cleanup
      Rates.reset(athanor_id, component_ref)
    end

    test "returns unlimited when no rate limit configured" do
      athanor_id = athanor()
      component_ref = "local.test-component:1.0.0"

      assert {:ok, :unlimited} = Rates.status(athanor_id, component_ref, nil)
    end
  end

  describe "window parsing" do
    test "parses different window formats" do
      athanor_id = athanor()
      component_ref = "local.test-component:1.0.0"

      # Test milliseconds
      policy_ms = %{rate_limit: %{requests: 10, window: "100ms"}}
      assert {:ok, _} = Rates.check(athanor_id, component_ref <> "_ms", policy_ms)

      # Test seconds
      policy_s = %{rate_limit: %{requests: 10, window: "30s"}}
      assert {:ok, _} = Rates.check(athanor_id, component_ref <> "_s", policy_s)

      # Test minutes
      policy_m = %{rate_limit: %{requests: 10, window: "5m"}}
      assert {:ok, _} = Rates.check(athanor_id, component_ref <> "_m", policy_m)

      # Test hours
      policy_h = %{rate_limit: %{requests: 10, window: "1h"}}
      assert {:ok, _} = Rates.check(athanor_id, component_ref <> "_h", policy_h)

      # Cleanup
      Rates.reset(athanor_id, component_ref <> "_ms")
      Rates.reset(athanor_id, component_ref <> "_s")
      Rates.reset(athanor_id, component_ref <> "_m")
      Rates.reset(athanor_id, component_ref <> "_h")
    end
  end

  describe "tenant (athanor_id) enforcement" do
    test "check rejects an empty athanor_id" do
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 10, window: "1m"}}

      assert {:error, :missing_tenant} = Rates.check("", component_ref, policy)
    end

    test "check rejects a nil athanor_id" do
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 10, window: "1m"}}

      assert {:error, :missing_tenant} = Rates.check(nil, component_ref, policy)
    end

    test "reset rejects an empty athanor_id" do
      component_ref = "local.test-component:1.0.0"

      assert {:error, :missing_tenant} = Rates.reset("", component_ref)
    end

    test "status rejects an empty athanor_id" do
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 10, window: "1m"}}

      assert {:error, :missing_tenant} = Rates.status("", component_ref, policy)
    end

    test "check allows a resolved athanor_id" do
      athanor_id = athanor()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 10, window: "1m"}}

      assert {:ok, 9} = Rates.check(athanor_id, component_ref, policy)

      # Cleanup
      Rates.reset(athanor_id, component_ref)
    end
  end

  describe "Cyfr.Limits struct" do
    test "works with a Cyfr.Limits struct as the limit source" do
      athanor_id = athanor()
      component_ref = "local.test-component:1.0.0"

      limits = %Cyfr.Limits{
        timeout: "30s",
        max_memory_bytes: 64 * 1024 * 1024,
        max_request_size: 1_048_576,
        max_response_size: 5_242_880,
        rate_limit: %{requests: 5, window: "1m"},
        max_concurrent_tasks: 10,
        batch_timeout: "5m"
      }

      assert {:ok, 4} = Rates.check(athanor_id, component_ref, limits)

      # Cleanup
      Rates.reset(athanor_id, component_ref)
    end
  end

  describe "atomic claims" do
    test "N callers racing a cap of N-1 admit exactly N-1" do
      athanor_id = athanor()

      for n <- [2, 3, 8, 16, 32], round <- 1..3 do
        component_ref = "local.race-#{n}-#{round}:1.0.0"
        policy = policy(n - 1, "1m")

        results = race(n, fn _i -> Rates.check(athanor_id, component_ref, policy) end)

        admitted = for {:ok, remaining} <- results, do: remaining
        refused = for {:error, :rate_limited, retry_after} <- results, do: retry_after

        assert length(admitted) == n - 1,
               "N=#{n} round #{round}: #{length(admitted)} admitted against a cap of #{n - 1}"

        # Serialized claims hand out each remaining count once: no two
        # callers saw the same count.
        assert Enum.sort(admitted) == Enum.to_list(0..(n - 2))

        # The refusal keeps its shape, and there is exactly one.
        assert [retry_after] = refused
        assert is_integer(retry_after) and retry_after >= 0 and retry_after <= 60_000
        assert length(results) == n

        assert {:ok, count, 0, _window} = Rates.status(athanor_id, component_ref, policy)
        assert count == n - 1
        assert rows(athanor_id, component_ref) == n - 1
        assert owner_count(athanor_id, component_ref) == n - 1

        Rates.reset(athanor_id, component_ref)
      end
    end

    test "concurrent claims beyond the cap admit exactly the cap" do
      athanor_id = athanor()
      component_ref = "local.concurrent-#{:rand.uniform(100_000)}:1.0.0"
      policy = policy(50, "1m")

      results =
        race(20, fn _i ->
          for _ <- 1..10, do: Rates.check(athanor_id, component_ref, policy)
        end)
        |> List.flatten()

      assert Enum.count(results, &match?({:ok, _}, &1)) == 50
      assert Enum.count(results, &match?({:error, :rate_limited, _}, &1)) == 150

      # The window is saturated: a subsequent check denies.
      assert {:error, :rate_limited, _} =
               Rates.check(athanor_id, component_ref, policy)

      Rates.reset(athanor_id, component_ref)
    end

    test "two buckets racing at once keep their own allowance" do
      # Two consents (component refs) in one athanor, each raced by N
      # callers against a cap of N-1, in the same instant: each admits its
      # own N-1 and neither borrows from the other.
      athanor_id = athanor()
      n = 16
      ref_a = "local.isolated-a:1.0.0"
      ref_b = "local.isolated-b:1.0.0"
      policy = policy(n - 1, "1m")

      results =
        race(2 * n, fn i ->
          ref = if rem(i, 2) == 0, do: ref_a, else: ref_b
          {ref, Rates.check(athanor_id, ref, policy)}
        end)

      for ref <- [ref_a, ref_b] do
        own = for {^ref, result} <- results, do: result
        assert length(own) == n
        assert Enum.count(own, &match?({:ok, _}, &1)) == n - 1
        assert Enum.count(own, &match?({:error, :rate_limited, _}, &1)) == 1
        assert rows(athanor_id, ref) == n - 1
      end

      Rates.reset(athanor_id, ref_a)
      Rates.reset(athanor_id, ref_b)
    end

    test "the owner's count tracks the bucket's rows through claims, refusals and retire" do
      athanor_id = athanor()
      component_ref = "local.invariant:1.0.0"
      policy = policy(2, "300ms")
      t0 = System.system_time(:millisecond)

      assert {:ok, 1} = Rates.claim_at(athanor_id, component_ref, policy, t0)
      assert {:ok, 0} = Rates.claim_at(athanor_id, component_ref, policy, t0 + 1)

      assert {:error, :rate_limited, _} =
               Rates.claim_at(athanor_id, component_ref, policy, t0 + 2)

      assert rows(athanor_id, component_ref) == 2
      assert owner_count(athanor_id, component_ref) == 2

      # The first row leaves the window: the claim retires it and takes
      # its place.
      assert {:ok, 0} = Rates.claim_at(athanor_id, component_ref, policy, t0 + 301)
      assert rows(athanor_id, component_ref) == 2
      assert owner_count(athanor_id, component_ref) == 2
      assert Enum.sort(stamps(athanor_id, component_ref)) == [t0 + 1, t0 + 301]

      Rates.reset(athanor_id, component_ref)
      assert rows(athanor_id, component_ref) == 0
      assert owner_count(athanor_id, component_ref) == 0
    end
  end

  describe "sliding window" do
    test "a claim exactly at the window edge still counts, one millisecond later it does not" do
      athanor_id = athanor()
      component_ref = "local.edge:1.0.0"
      policy = policy(1, "300ms")
      t0 = System.system_time(:millisecond)

      assert {:ok, 0} = Rates.claim_at(athanor_id, component_ref, policy, t0)

      # Inside the window, and at its last millisecond: refused, with the
      # wait counting down to zero.
      assert {:error, :rate_limited, 1} =
               Rates.claim_at(athanor_id, component_ref, policy, t0 + 299)

      assert {:error, :rate_limited, 0} =
               Rates.claim_at(athanor_id, component_ref, policy, t0 + 300)

      assert rows(athanor_id, component_ref) == 1

      # One millisecond past the edge the claim is admitted and the row it
      # retired is gone before any sweep.
      assert {:ok, 0} = Rates.claim_at(athanor_id, component_ref, policy, t0 + 301)
      assert stamps(athanor_id, component_ref) == [t0 + 301]
      assert owner_count(athanor_id, component_ref) == 1

      Rates.reset(athanor_id, component_ref)
    end

    test "retry_after counts from the oldest claim still in the window" do
      athanor_id = athanor()
      component_ref = "local.retry-after:1.0.0"
      policy = policy(2, "1s")
      t0 = System.system_time(:millisecond)

      assert {:ok, 1} = Rates.claim_at(athanor_id, component_ref, policy, t0)
      assert {:ok, 0} = Rates.claim_at(athanor_id, component_ref, policy, t0 + 400)

      assert {:error, :rate_limited, 500} =
               Rates.claim_at(athanor_id, component_ref, policy, t0 + 500)

      # The first claim leaves the window; the second is now the oldest.
      assert {:ok, 0} = Rates.claim_at(athanor_id, component_ref, policy, t0 + 1001)

      assert {:error, :rate_limited, 398} =
               Rates.claim_at(athanor_id, component_ref, policy, t0 + 1002)

      Rates.reset(athanor_id, component_ref)
    end

    test "claims are admitted again once the window has passed" do
      athanor_id = athanor()
      component_ref = "local.window-passes:1.0.0"
      policy = policy(2, "100ms")

      assert {:ok, 1} = Rates.check(athanor_id, component_ref, policy)
      assert {:ok, 0} = Rates.check(athanor_id, component_ref, policy)
      assert {:error, :rate_limited, retry_after} = Rates.check(athanor_id, component_ref, policy)
      assert retry_after in 0..100

      wait_until(
        fn -> match?({:ok, 0, 2, _}, Rates.status(athanor_id, component_ref, policy)) end,
        2_000,
        "the window to pass"
      )

      assert {:ok, 1} = Rates.check(athanor_id, component_ref, policy)
      assert rows(athanor_id, component_ref) == 1

      Rates.reset(athanor_id, component_ref)
    end
  end

  describe "sweep" do
    test "the sweep drops rows past twice their window and forgets their bucket" do
      athanor_id = athanor()
      stale_ref = "local.stale:1.0.0"
      live_ref = "local.live:1.0.0"
      t0 = System.system_time(:millisecond)

      # Two claims whose rows expired long ago, and one still in its window.
      stale = policy(3, "100ms")
      assert {:ok, 2} = Rates.claim_at(athanor_id, stale_ref, stale, t0 - 5_000)
      assert {:ok, 1} = Rates.claim_at(athanor_id, stale_ref, stale, t0 - 5_000)
      assert {:ok, 4} = Rates.check(athanor_id, live_ref, policy(5, "1m"))
      assert rows(athanor_id, stale_ref) == 2

      owner = Process.whereis(Rates)
      before = :sys.get_state(owner).sweep
      send(owner, :sweep)
      after_sweep = :sys.get_state(owner)

      assert rows(athanor_id, stale_ref) == 0
      refute Map.has_key?(after_sweep.counts, {athanor_id, stale_ref})

      assert rows(athanor_id, live_ref) == 1
      assert after_sweep.counts[{athanor_id, live_ref}] == 1
      assert {:ok, 1, 4, _} = Rates.status(athanor_id, live_ref, policy(5, "1m"))

      # A sweep sent by hand replaces the pending timer instead of starting
      # a second chain beside it.
      assert Process.read_timer(before) == false
      assert is_integer(Process.read_timer(after_sweep.sweep))

      Rates.reset(athanor_id, live_ref)
    end
  end

  describe "callers" do
    test "the table survives a caller's death and keeps the claim it made" do
      athanor_id = athanor()
      component_ref = "local.dead-caller:1.0.0"
      policy = policy(3, "1m")
      parent = self()

      # One caller claims and ends; another claims and is killed.
      ended =
        spawn(fn ->
          send(parent, {:claimed, Rates.check(athanor_id, component_ref, policy)})
        end)

      assert_receive {:claimed, {:ok, 2}}
      wait_until(fn -> not Process.alive?(ended) end)

      killed =
        spawn(fn ->
          send(parent, {:claimed, Rates.check(athanor_id, component_ref, policy)})
          Process.sleep(:infinity)
        end)

      assert_receive {:claimed, {:ok, 1}}
      Process.exit(killed, :kill)
      wait_until(fn -> not Process.alive?(killed) end)

      assert :ets.whereis(@table) != :undefined
      assert Process.alive?(Process.whereis(Rates))
      assert {:ok, 2, 1, _} = Rates.status(athanor_id, component_ref, policy)
      assert {:ok, 0} = Rates.check(athanor_id, component_ref, policy)

      Rates.reset(athanor_id, component_ref)
    end

    test "a claim whose caller dies while it waits is still recorded" do
      athanor_id = athanor()
      component_ref = "local.dies-waiting:1.0.0"
      policy = policy(3, "1m")
      owner = Process.whereis(Rates)

      # Hold the owner so the claim queues, kill the caller while it waits,
      # then let the owner run: the claim lands and spends a slot, and the
      # answer to nobody is dropped.
      :ok = :sys.suspend(owner)

      try do
        caller = spawn(fn -> Rates.check(athanor_id, component_ref, policy) end)

        # A sweep tick may share the mailbox; the claim is what must queue.
        wait_until(
          fn ->
            {:message_queue_len, queued} = Process.info(owner, :message_queue_len)
            queued >= 1
          end,
          2_000,
          "the claim to queue on the held owner"
        )

        Process.exit(caller, :kill)
        wait_until(fn -> not Process.alive?(caller) end)
      after
        :ok = :sys.resume(owner)
      end

      _ = :sys.get_state(owner)

      assert Process.alive?(owner)
      assert rows(athanor_id, component_ref) == 1
      assert {:ok, 1, 2, _} = Rates.status(athanor_id, component_ref, policy)

      Rates.reset(athanor_id, component_ref)
    end
  end

  describe "fail-closed on dead limiter" do
    test "a dead limiter exits like a dead GenServer so Policy denies" do
      athanor_id = athanor()
      policy = %{rate_limit: %{requests: 5, window: "1m"}}

      # In an umbrella run the limiter is supervised, and a plain
      # GenServer.stop races the supervisor's automatic restart. Park the
      # child via terminate_child (no auto-restart) so the dead-table window
      # is deterministic; fall back to stop/start when unsupervised.
      supervised? =
        Process.whereis(Cyfr.InfraSupervisor) != nil and
          match?(:ok, Supervisor.terminate_child(Cyfr.InfraSupervisor, Rates))

      unless supervised?, do: GenServer.stop(Rates)

      assert {:noproc, {Rates, :check}} =
               catch_exit(Rates.check(athanor_id, "local.dead:1.0.0", policy))

      assert {:noproc, {Rates, :reset}} =
               catch_exit(Rates.reset(athanor_id, "local.dead:1.0.0"))

      assert {:noproc, {Rates, :status}} =
               catch_exit(Rates.status(athanor_id, "local.dead:1.0.0", policy))

      # Restore the limiter (and its table) for the rest of the suite.
      if supervised? do
        {:ok, _pid} = Supervisor.restart_child(Cyfr.InfraSupervisor, Rates)
      else
        {:ok, _pid} = Rates.start_link([])
      end

      wait_until(fn -> :ets.whereis(:cyfr_execution_rates) != :undefined end)
    end
  end
end
