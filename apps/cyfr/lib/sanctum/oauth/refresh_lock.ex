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

  Locks are node-local and do not serialize refreshes across nodes. Keys are opaque terms.
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

    # Allow time for the provider response, CAS write and conflict merge before
    # terminating the task; a rotated token must be persisted.
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
        # The exit reason is the host's to log, not the caller's to read —
        # and not the log's to spell out either: a crashed refresh's reason
        # can embed the very material this module guards (a
        # FunctionClauseError carries the oauth map with its refresh_token
        # in the failing frame's args; a KeyError from the cipher path
        # carries the keyring, under labels no key-roster sanitizer knows).
        # An exception exit is named by type only; anything else is
        # sanitized and bounded.
        Logger.warning("[Sanctum.OAuth.RefreshLock] refresh exited: #{describe_exit(reason)}")
        {:error, {:authorization_required, "the token refresh failed"}}

      nil ->
        {:error, {:authorization_required, "the token refresh timed out"}}
    end
  end

  defp describe_exit({%{__struct__: mod}, _stacktrace}), do: inspect(mod)
  defp describe_exit(%{__struct__: mod}), do: inspect(mod)
  defp describe_exit(reason) when is_atom(reason), do: inspect(reason)

  defp describe_exit(other),
    do: inspect(Sanctum.Sanitizer.sanitize(other), limit: 20, printable_limit: 200)
end
