# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.OAuth.RefreshLock do
  @moduledoc """
  Cell-wide single-flight serializer for OAuth token refresh.

  The refresh race lives at the *provider*: two concurrent refreshes present
  the same refresh token, and a provider that rotates refresh tokens on use
  invalidates the loser's stored bundle — a compare-and-swap on our side
  cannot prevent that. Exactly one refresh per key may be in flight; every
  other caller waits for the leader and re-reads the result.

  ## Two locks, because they answer two different questions

    * **A node-local `Registry`** serializes the callers on ONE member.
      Each call runs in a supervised task that tries to register the key.
      The winner (leader) goes on; a loser (follower) monitors the
      leader's task and, when it goes down, reports back so the caller can
      re-read the freshly stored token. The Registry entry dies with the
      leader's task, so a crashed refresh never leaves a stuck lock. It is
      also what makes the claim below meaningful: `Arca.JobClaims` admits
      one *owner*, and every caller on one member shares this boot's id.

    * **The `oauth_refresh` claim row** (`Arca.JobClaims`, key
      `"<athanor_id>:<credential_id>"`, a 30 s one-shot lease released as
      soon as the refresh returns) serializes the members. A member that
      finds a live peer holding it does not POST: it waits for the peer,
      re-reading the stored bundle, and takes the claim itself only once
      the row is free again.

  ## What the claim does not do, and the compare-and-set that does

  The claim stops N members refreshing at once. It cannot make a refresh
  that overran its 30 s lease harmless, because the provider call has
  already happened by then. The property — **an old refresh cannot
  replace a newer binding** — is enforced by the write, not by the lock:
  `Sanctum.Vault.OAuth` seals its result and writes it through
  `Arca.VaultStorage.rotate_payload/4`, a compare-and-set on the
  `payload_rev` the refresher read inside the lock. A refresh whose write
  lands after a newer binding finds a revision it did not read, loses, and
  is reconciled against what actually stands.

  That is also why a leader does not re-check its claim before writing
  back: by then the provider has rotated the refresh token this refresh
  consumed, so dropping the response would strand the entry on a dead
  token family. The CAS is the fence for that write, and it is a stricter
  one than the claim — it names the resource rather than the lock.

  Keys are `{kind, athanor_id, subject_id}` triples: the local registry
  takes the whole term, and the claim row takes
  `"<athanor_id>:<subject_id>"`, which is what the cell's roster of
  singleton jobs names an OAuth refresh by.
  """

  require Logger

  alias Arca.JobClaims

  @registry Sanctum.OAuth.RefreshRegistry
  @task_supervisor Sanctum.OAuth.RefreshTaskSupervisor

  @kind "oauth_refresh"
  # One-shot: the lease is a ceiling on a member that died holding it, not
  # a budget the refresh renews. Released as soon as the binding is written.
  @claim_lease_ms 30_000
  @peer_poll_ms 250

  @default_timeout_ms 20_000

  @doc """
  Run `refresh_fun` under the single-flight lock for `key`.

  `key` is `{kind, athanor_id, subject_id}`; the claim row the cell
  serializes on is `"<athanor_id>:<subject_id>"`.

  `recheck_fun` is invoked when another caller's refresh completed first; it
  must re-read the stored token and return `{:ok, token}` when fresh or
  `:stale` to trigger one bounded retry (covers a leader that crashed
  mid-refresh). It is also what a member waiting on a PEER's claim polls,
  so a refresh that landed on another member is read rather than repeated.
  """
  @spec run({atom(), String.t(), String.t()}, (-> result), (-> {:ok, term()} | :stale), non_neg_integer()) ::
          result
        when result: {:ok, term()} | {:error, term()}
  def run({_kind, athanor_id, subject_id} = key, refresh_fun, recheck_fun, timeout_ms \\ @default_timeout_ms)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(subject_id) and
             subject_id != "" do
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
            {:leader, claimed(key, refresh_fun, recheck_fun, timeout_ms)}

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
      {:ok, {:leader, {:done, result}}} ->
        result

      # The peer that held the cell's claim gave it up without leaving a
      # fresh bundle behind. Ask again as leader, bounded as a follower's
      # `:stale` is.
      {:ok, {:leader, :retry}} ->
        do_run(key, refresh_fun, recheck_fun, timeout_ms, attempts - 1)

      {:ok, {:leader, :timeout}} ->
        {:error, {:authorization_required, "timed out waiting for a concurrent token refresh"}}

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

  # This member's turn on its own; now the cell's. The claim is released
  # whatever the refresh answered, including a raise, so the next member
  # waits on a provider call and never on a lease.
  defp claimed(key, refresh_fun, recheck_fun, timeout_ms) do
    claim_key = claim_key(key)

    case JobClaims.claim(@kind, claim_key, Cyfr.Boot.id(), @claim_lease_ms) do
      {:ok, claim} ->
        try do
          {:done, refresh_fun.()}
        after
          JobClaims.release(claim)
        end

      {:busy, _peer} ->
        await_peer(claim_key, recheck_fun, System.monotonic_time(:millisecond) + timeout_ms)

      # The store that holds the claim is the store that holds the bundle:
      # a refresh serialized by nothing is the one thing that must not
      # happen quietly, and the write it would make needs the same store.
      {:error, :database_error} ->
        {:done, {:error, :database_error}}
    end
  end

  # A peer holds the cell's claim. Read what it writes rather than POSTing
  # beside it; give up the wait at the deadline, and take the claim once
  # the row is free.
  defp await_peer(claim_key, recheck_fun, deadline) do
    case recheck_fun.() do
      {:ok, _} = fresh ->
        {:done, fresh}

      :stale ->
        cond do
          System.monotonic_time(:millisecond) >= deadline -> :timeout
          peer_holds?(claim_key) -> sleep_then(claim_key, recheck_fun, deadline)
          true -> :retry
        end
    end
  end

  defp sleep_then(claim_key, recheck_fun, deadline) do
    Process.sleep(@peer_poll_ms)
    await_peer(claim_key, recheck_fun, deadline)
  end

  defp peer_holds?(claim_key) do
    case JobClaims.read(@kind, claim_key) do
      {:ok, claim} -> JobClaims.live?(claim)
      # A row that vanished is free; a store that cannot answer is not
      # evidence that nobody holds it, so the wait goes on to its deadline.
      {:error, :not_found} -> false
      {:error, :database_error} -> true
    end
  end

  defp claim_key({_kind, athanor_id, subject_id}), do: athanor_id <> ":" <> subject_id

  defp describe_exit({%{__struct__: mod}, _stacktrace}), do: inspect(mod)
  defp describe_exit(%{__struct__: mod}), do: inspect(mod)
  defp describe_exit(reason) when is_atom(reason), do: inspect(reason)

  defp describe_exit(other),
    do: inspect(Cyfr.Sanitizer.sanitize(other), limit: 20, printable_limit: 200)
end
