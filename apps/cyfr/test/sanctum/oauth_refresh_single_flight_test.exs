# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.OAuthRefreshSingleFlightTest do
  use ExUnit.Case, async: false

  alias Sanctum.OAuth.RefreshLock

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  describe "RefreshLock.run/4" do
    test "concurrent callers on one key execute the refresh exactly once" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      key = {:oauth_refresh, {"test-ref", "prov", "local", "default"}}

      refresh_fun = fn ->
        Agent.update(counter, &(&1 + 1))
        # Hold the lock long enough that every other caller becomes a follower
        Process.sleep(200)
        {:ok, "fresh-token"}
      end

      # Followers re-read "storage" — the leader has completed by then
      recheck_fun = fn ->
        if Agent.get(counter, & &1) > 0, do: {:ok, "fresh-token"}, else: :stale
      end

      results =
        1..10
        |> Task.async_stream(
          fn _ -> RefreshLock.run(key, refresh_fun, recheck_fun, 5_000) end,
          max_concurrency: 10,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &(&1 == {:ok, "fresh-token"}))
      assert Agent.get(counter, & &1) == 1
    end

    test "a crashed leader does not leave a stuck lock" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      key = {:oauth_refresh, {"crash-ref", "prov", "local", "default"}}

      refresh_fun = fn ->
        if Agent.get_and_update(counter, &{&1, &1 + 1}) == 0 do
          Process.sleep(50)
          raise "provider exploded"
        else
          {:ok, "second-attempt-token"}
        end
      end

      recheck_fun = fn -> :stale end

      # First caller crashes as leader; a concurrent follower observes the
      # DOWN, rechecks (stale), and becomes the next leader.
      results =
        1..2
        |> Task.async_stream(
          fn _ -> RefreshLock.run(key, refresh_fun, recheck_fun, 5_000) end,
          max_concurrency: 2,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert {:ok, "second-attempt-token"} in results

      # The registry entry died with the tasks — a later caller can lead again
      assert {:ok, "second-attempt-token"} =
               RefreshLock.run(key, fn -> {:ok, "second-attempt-token"} end, recheck_fun, 5_000)
    end

    test "distinct keys do not serialize against each other" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      slow = fn ->
        Agent.update(counter, &(&1 + 1))
        Process.sleep(300)
        {:ok, "slow"}
      end

      fast = fn ->
        Agent.update(counter, &(&1 + 1))
        {:ok, "fast"}
      end

      slow_task =
        Task.async(fn -> RefreshLock.run({:oauth_refresh, :a}, slow, fn -> :stale end) end)

      Process.sleep(20)

      {fast_micros, {:ok, "fast"}} =
        :timer.tc(fn -> RefreshLock.run({:oauth_refresh, :b}, fast, fn -> :stale end) end)

      assert {:ok, "slow"} = Task.await(slow_task, 5_000)
      # The fast key completed while the slow key's leader still held its lock
      assert fast_micros < 250_000
      assert Agent.get(counter, & &1) == 2
    end
  end

  describe "get_access_token/3 refresh wiring" do
    # The https requirement on token endpoints means the provider can't be a
    # local plaintext stub; instead the provider attempt COUNT (via refresh
    # telemetry) proves serialization: 10 concurrent expired-token callers
    # must produce far fewer provider attempts than callers — one leader per
    # bounded retry round instead of one attempt per caller.
    test "concurrent expired-token callers serialize provider attempts", %{ctx: ctx} do
      manifest = %{
        "oauth" => %{
          "sfprov" => %{
            "authorize_url" => "https://example.com/auth",
            # Unreachable: connection refused immediately
            "token_url" => "https://127.0.0.1:1/token",
            "scopes" => ["read"]
          }
        }
      }

      Sanctum.Test.ComponentHelpers.register_test_component(
        "sf-cat",
        "1.0.0",
        "catalyst",
        manifest
      )

      :ok = Sanctum.ProviderCredentials.put(ctx, "sfprov", "cid", "csec")

      ref = "catalyst:local.sf-cat"
      seed_expired_bundle(ref, "sfprov")

      handler_id = "sf-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:cyfr, :opus, :oauth, :token_refresh],
        fn _event, _measurements, meta, _cfg -> send(test_pid, {:refresh_attempt, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      results =
        1..10
        |> Task.async_stream(
          fn _ -> Sanctum.OAuth.get_access_token(ctx, ref, "sfprov") end,
          max_concurrency: 10,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:error, _}, &1))

      attempts = drain_refresh_attempts(0)
      assert attempts >= 1
      # One leader per retry round (bounded at 2 rounds per caller), never
      # one attempt per caller. Without the lock this is exactly 10.
      assert attempts <= 4
    end

    test "revoke cascades versioned ref to the name-level bundle", %{ctx: ctx} do
      # Token stored under the name-level ref, as the cascade write path does
      seed_valid_bundle("catalyst:local.rv-cat", "rvprov")

      # A versioned read reaches it through the cascade
      assert {:ok, "live-token"} =
               Sanctum.OAuth.get_access_token(ctx, "catalyst:local.rv-cat:1.0.0", "rvprov")

      # Revoking with the VERSIONED ref must kill the name-level bundle too
      assert :ok = Sanctum.OAuth.revoke(ctx, "catalyst:local.rv-cat:1.0.0", "rvprov")

      assert {:error, message} =
               Sanctum.OAuth.get_access_token(ctx, "catalyst:local.rv-cat:1.0.0", "rvprov")

      assert message =~ "authorization_required"

      # And the name-level read agrees
      assert {:error, _} = Sanctum.OAuth.get_access_token(ctx, "catalyst:local.rv-cat", "rvprov")
    end
  end

  defp drain_refresh_attempts(count) do
    receive do
      {:refresh_attempt, _meta} -> drain_refresh_attempts(count + 1)
    after
      200 -> count
    end
  end

  defp seed_expired_bundle(storage_ref, provider) do
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()

    seed_bundle(storage_ref, provider, %{
      "access_token" => "stale-token",
      "refresh_token" => "refresh-1",
      "expires_at" => past,
      "scopes" => [],
      "token_type" => "bearer"
    })
  end

  defp seed_valid_bundle(storage_ref, provider) do
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

    seed_bundle(storage_ref, provider, %{
      "access_token" => "live-token",
      "refresh_token" => "refresh-1",
      "expires_at" => future,
      "scopes" => [],
      "token_type" => "bearer"
    })
  end

  defp seed_bundle(storage_ref, provider, token_data) do
    json = Jason.encode!(token_data)

    {:ok, encrypted} =
      Sanctum.Cipher.encrypt(
        json,
        Sanctum.CipherAAD.oauth_token(storage_ref, provider, "local", "default")
      )

    :ok = Arca.OAuthStorage.put_token(storage_ref, provider, encrypted, "local", "default")
  end
end
