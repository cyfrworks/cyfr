# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.OAuth.RefreshLock do
  @moduledoc """
  Node-local single-flight serializer for OAuth token refresh.

  The refresh race lives at the *provider*: two concurrent refreshes present
  the same refresh token, and a provider that rotates refresh tokens on use
  invalidates the loser's stored bundle — a compare-and-swap on our side
  cannot prevent that. Exactly one refresh per key may be in flight; every
  other caller waits for the leader and re-reads the result.

  Mechanics: each call runs in a supervised task that tries to register the
  key in a unique `Registry`. The winner (leader) executes the refresh; a
  loser (follower) monitors the leader's task and, when it goes down,
  reports back so the caller can re-read the freshly stored token. The
  Registry entry dies with the leader's task, so a crashed refresh never
  leaves a stuck lock.

  Node-local by design: clustering is not currently possible (no
  distribution config, SQLite default, bare-name singletons), and the
  deployment-wide, vault-entry-keyed version belongs to the Vault redesign.
  Keys are opaque terms so that migration only narrows the key.
  """

  @registry Sanctum.OAuth.RefreshRegistry
  @task_supervisor Sanctum.OAuth.RefreshTaskSupervisor

  @default_timeout_ms 20_000

  @doc """
  Run `refresh_fun` under the single-flight lock for `key`.

  `recheck_fun` is invoked when another caller's refresh completed first; it
  must re-read the stored token and return `{:ok, token}` when fresh or
  `:stale` to trigger one bounded retry (covers a leader that crashed
  mid-refresh).
  """
  @spec run(term(), (-> result), (-> {:ok, term()} | :stale), non_neg_integer()) :: result
        when result: {:ok, term()} | {:error, term()}
  def run(key, refresh_fun, recheck_fun, timeout_ms \\ @default_timeout_ms) do
    do_run(key, refresh_fun, recheck_fun, timeout_ms, 2)
  end

  defp do_run(_key, _refresh_fun, _recheck_fun, _timeout_ms, 0) do
    {:error, "authorization_required: token refresh contention did not settle"}
  end

  defp do_run(key, refresh_fun, recheck_fun, timeout_ms, attempts) do
    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        case Registry.register(@registry, key, :leader) do
          {:ok, _} ->
            {:leader, refresh_fun.()}

          {:error, {:already_registered, leader_pid}} ->
            ref = Process.monitor(leader_pid)

            receive do
              {:DOWN, ^ref, :process, _pid, _reason} -> :follower_retry
            after
              timeout_ms -> :follower_timeout
            end
        end
      end)

    case Task.yield(task, timeout_ms + 1_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:leader, result}} ->
        result

      {:ok, :follower_retry} ->
        case recheck_fun.() do
          {:ok, _} = fresh -> fresh
          :stale -> do_run(key, refresh_fun, recheck_fun, timeout_ms, attempts - 1)
        end

      {:ok, :follower_timeout} ->
        {:error, "authorization_required: timed out waiting for a concurrent token refresh"}

      {:exit, reason} ->
        {:error, "authorization_required: token refresh failed: #{inspect(reason)}"}

      nil ->
        {:error, "authorization_required: token refresh timed out"}
    end
  end
end
