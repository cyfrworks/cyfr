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

  require Logger

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
    {:error, {:authorization_required, "token refresh contention did not settle"}}
  end

  defp do_run(key, refresh_fun, recheck_fun, timeout_ms, attempts) do
    logger_metadata = Cyfr.LoggerContext.capture()

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        Cyfr.LoggerContext.restore(logger_metadata)

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

    # The margin over timeout_ms covers the leader's full worst case — the
    # provider POST (15s receive ceiling) plus the CAS write-back and a
    # possible conflict merge. A margin of one second used to let this
    # brutal-kill land between the POST and the write, losing a refresh
    # token the provider had already rotated.
    case Task.yield(task, timeout_ms + 15_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:leader, result}} ->
        result

      {:ok, :follower_retry} ->
        case recheck_fun.() do
          {:ok, _} = fresh -> fresh
          :stale -> do_run(key, refresh_fun, recheck_fun, timeout_ms, attempts - 1)
        end

      {:ok, :follower_timeout} ->
        {:error, {:authorization_required, "timed out waiting for a concurrent token refresh"}}

      {:exit, reason} ->
        # The exit reason is the host's to log, not the caller's to read.
        Logger.warning("[Sanctum.OAuth.RefreshLock] refresh exited: #{inspect(reason)}")
        {:error, {:authorization_required, "the token refresh failed"}}

      nil ->
        {:error, {:authorization_required, "the token refresh timed out"}}
    end
  end
end
