# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.PersonalNamespaceCacheTest do
  use ExUnit.Case, async: false

  alias EmissaryWeb.Plugs.PersonalNamespaceCache

  # The cache is started in Cyfr.Application's supervision tree so the ETS
  # table already exists at test time. Each test uses unique keys to avoid
  # cross-test interference (the cache is process-global).

  defp unique_user, do: "test-user-#{System.unique_integer([:positive])}"
  defp unique_registry, do: "test-reg-#{System.unique_integer([:positive])}.example"

  describe "claimed?/2" do
    test "returns :miss when no entry exists" do
      assert PersonalNamespaceCache.claimed?(unique_user(), unique_registry()) == :miss
    end

    test "returns :hit after put_claimed within TTL" do
      user = unique_user()
      reg = unique_registry()

      :ok = PersonalNamespaceCache.put_claimed(user, reg)
      assert PersonalNamespaceCache.claimed?(user, reg) == :hit
    end

    test "returns :miss for a different (user, registry) pair" do
      user = unique_user()
      reg = unique_registry()

      :ok = PersonalNamespaceCache.put_claimed(user, reg)
      assert PersonalNamespaceCache.claimed?(user, "other-reg") == :miss
      assert PersonalNamespaceCache.claimed?("other-user", reg) == :miss
    end
  end

  describe "invalidate/2" do
    test "removes an existing entry" do
      user = unique_user()
      reg = unique_registry()

      :ok = PersonalNamespaceCache.put_claimed(user, reg)
      assert PersonalNamespaceCache.claimed?(user, reg) == :hit

      :ok = PersonalNamespaceCache.invalidate(user, reg)
      assert PersonalNamespaceCache.claimed?(user, reg) == :miss
    end

    test "is a no-op when entry does not exist" do
      assert PersonalNamespaceCache.invalidate(unique_user(), unique_registry()) == :ok
    end
  end

  describe "concurrency" do
    test "concurrent writers and readers do not corrupt state" do
      user = unique_user()
      reg = unique_registry()

      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              PersonalNamespaceCache.put_claimed(user, reg)
            else
              PersonalNamespaceCache.claimed?(user, reg)
            end
          end)
        end

      results = Task.await_many(tasks, 2_000)
      # All tasks complete without raising; readers return :hit or :miss,
      # writers return :ok.
      assert Enum.all?(results, fn r -> r in [:ok, :hit, :miss] end)

      # Final state: at least one write happened, so :hit.
      assert PersonalNamespaceCache.claimed?(user, reg) == :hit
    end
  end

  # The 30s TTL is too long to exercise via `Process.sleep/1` in unit tests.
  # Instead, we overwrite the stored monotonic timestamp with a value far in
  # the past — equivalent to "the cache entry was written > 30s ago". This is
  # a white-box test (knows the ETS table name + stored tuple shape) but it's
  # the only way to verify the TTL branch in `claimed?/2` without a real
  # 30-second sleep. Exercises claim-gate self-heal via TTL expiry.
  describe "TTL expiry" do
    @table :personal_namespace_cache
    # Matches the value of `@ttl_ms` in the module — any number larger is an
    # expired entry. 40s is comfortably past the 30s window.
    @past_offset_ms 40_000

    test "returns :miss when entry is older than 30s (even though it exists)" do
      user = unique_user()
      reg = unique_registry()

      :ok = PersonalNamespaceCache.put_claimed(user, reg)
      assert PersonalNamespaceCache.claimed?(user, reg) == :hit

      # Simulate 40s of elapsed time by overwriting the stored timestamp.
      expired = System.monotonic_time(:millisecond) - @past_offset_ms
      :ets.insert(@table, {{user, reg}, expired})

      assert PersonalNamespaceCache.claimed?(user, reg) == :miss
    end

    test "self-heal: a stale entry can be replaced by a fresh put_claimed" do
      # This is the multi-session scenario: device A's put_claimed happens
      # after device B's expired read, so device B's next request re-queries
      # CredentialStore, gets a positive, and refreshes the cache.
      user = unique_user()
      reg = unique_registry()

      expired = System.monotonic_time(:millisecond) - @past_offset_ms
      :ets.insert(@table, {{user, reg}, expired})
      assert PersonalNamespaceCache.claimed?(user, reg) == :miss

      :ok = PersonalNamespaceCache.put_claimed(user, reg)
      assert PersonalNamespaceCache.claimed?(user, reg) == :hit
    end

    test "an aged entry still within the TTL window returns :hit" do
      # An entry written well within the 30s TTL must still hit — guards against
      # a grossly-wrong TTL (zero, or a flipped comparison) that would make valid
      # entries miss. We use a 15s offset rather than ttl-1s: `claimed?/2` reads
      # the real monotonic clock, so a razor-thin margin is timing-flaky on a
      # loaded CI runner (a >1s scheduling delay would flip ttl-1s to a miss).
      user = unique_user()
      reg = unique_registry()

      # 15s ago — comfortably within the 30s TTL (15s margin absorbs CI jitter).
      fresh = System.monotonic_time(:millisecond) - 15_000
      :ets.insert(@table, {{user, reg}, fresh})

      assert PersonalNamespaceCache.claimed?(user, reg) == :hit
    end
  end

  # The GenServer is defensively coded so that an ETS table vanishing at
  # runtime doesn't crash subsequent callers — `ensure_table/0` recreates
  # the named table on demand. These tests cover that defensive branch and
  # the supervisor-restart path (which is the common-case recovery).
  describe "crash recovery" do
    @table :personal_namespace_cache

    setup do
      # These tests deliberately tear down the ETS table / owning GenServer.
      # Guarantee a live table for whatever test runs next in this file —
      # other describes `:ets.insert/2` into the table directly. We restart
      # the supervised GenServer so the new instance owns the fresh table
      # (ensure_table called from the test process would be owned by a
      # short-lived PID and destroyed when the test exits).
      on_exit(fn ->
        case Process.whereis(EmissaryWeb.Plugs.PersonalNamespaceCache) do
          nil ->
            :ok

          pid ->
            ref = Process.monitor(pid)
            Process.exit(pid, :kill)
            receive do
              {:DOWN, ^ref, :process, ^pid, _} -> :ok
            after
              500 -> :ok
            end
        end

        # Wait for supervisor restart — new GenServer's init creates a
        # supervised ETS table owned by the GenServer, not the test process.
        Enum.each(1..50, fn _ ->
          if Process.whereis(EmissaryWeb.Plugs.PersonalNamespaceCache),
            do: :ok,
            else: Process.sleep(20)
        end)
      end)

      :ok
    end

    test "ETS table deletion: claimed?/2 rebuilds via ensure_table" do
      user = unique_user()
      reg = unique_registry()

      :ok = PersonalNamespaceCache.put_claimed(user, reg)
      assert PersonalNamespaceCache.claimed?(user, reg) == :hit

      # Directly drop the ETS table out from under the GenServer. The next
      # call into claimed?/2 must not raise — ensure_table/0 rebuilds.
      :ets.delete(@table)

      assert PersonalNamespaceCache.claimed?(user, reg) == :miss
      assert PersonalNamespaceCache.put_claimed(user, reg) == :ok
      assert PersonalNamespaceCache.claimed?(user, reg) == :hit
    end

    test "GenServer kill: supervisor restart reestablishes the cache" do
      original_pid = Process.whereis(PersonalNamespaceCache)
      assert is_pid(original_pid)

      ref = Process.monitor(original_pid)
      Process.exit(original_pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^original_pid, _}, 500

      # Poll until the supervisor restarts the GenServer (default restart
      # strategy). Should take <100ms in practice; cap at 1s.
      new_pid =
        Enum.find_value(1..50, fn _ ->
          Process.sleep(20)

          case Process.whereis(PersonalNamespaceCache) do
            nil -> nil
            pid when pid != original_pid -> pid
            _ -> nil
          end
        end)

      assert is_pid(new_pid), "GenServer was not restarted within 1s"
      refute new_pid == original_pid

      # Post-restart the cache is usable again — new writes and reads work.
      user = unique_user()
      reg = unique_registry()

      assert PersonalNamespaceCache.put_claimed(user, reg) == :ok
      assert PersonalNamespaceCache.claimed?(user, reg) == :hit
    end
  end
end
