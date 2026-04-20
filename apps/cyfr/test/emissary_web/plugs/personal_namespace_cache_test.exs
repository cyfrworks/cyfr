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
  # 30-second sleep. Covers Phase A "Done when" #29 + #39 (claim-gate self-
  # heal via TTL expiry).
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

    test "entry just inside the TTL window still returns :hit" do
      # Boundary check: an entry written (ttl - 1s) ago must still hit. Guards
      # against an off-by-one that would shrink the effective TTL to zero.
      user = unique_user()
      reg = unique_registry()

      # 29s ago — within the 30s TTL.
      fresh = System.monotonic_time(:millisecond) - 29_000
      :ets.insert(@table, {{user, reg}, fresh})

      assert PersonalNamespaceCache.claimed?(user, reg) == :hit
    end
  end
end
