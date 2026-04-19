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
end
