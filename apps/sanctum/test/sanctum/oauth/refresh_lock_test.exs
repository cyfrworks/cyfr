# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.OAuth.RefreshLockTest do
  @moduledoc """
  The refresh single flight across the cell: the `oauth_refresh` claim is
  what stops two members POSTing the same refresh token at once, and it is
  given up as soon as the refresh returns rather than held for its lease.

  What the claim cannot do — keep an old refresh from replacing a newer
  binding — is the binding ciphertext's compare-and-set, and is covered
  where that write lives (`Sanctum.VaultOAuthRefreshTest`).

  `job_claims` is shared, cross-node, node-global state. Each case takes a
  credential id of its own, so the key it writes is one nothing else
  touches.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arca.JobClaims
  alias Sanctum.OAuth.RefreshLock

  @kind "oauth_refresh"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    n = System.unique_integer([:positive])
    athanor_id = "ath_refresh_#{n}"
    credential_id = "vlt_refresh_#{n}"

    {:ok,
     key: {:vault_oauth_refresh, athanor_id, credential_id},
     claim_key: "#{athanor_id}:#{credential_id}"}
  end

  test "the leader claims the cell's row and gives it up as soon as the refresh returns", %{
    key: key,
    claim_key: claim_key
  } do
    assert {:ok, "fresh"} = RefreshLock.run(key, fn -> {:ok, "fresh"} end, fn -> :stale end)

    assert {:ok, row} = JobClaims.read(@kind, claim_key)
    assert row.owner == Cyfr.Boot.id()

    refute JobClaims.live?(row),
           "a one-shot claim held past its refresh makes the next member wait out a lease"
  end

  test "a refresh that raises still gives the claim up", %{key: key, claim_key: claim_key} do
    log =
      capture_log(fn ->
        assert {:error, {:authorization_required, _}} =
                 RefreshLock.run(key, fn -> raise "provider exploded" end, fn -> :stale end)
      end)

    assert log =~ "refresh exited"

    assert {:ok, row} = JobClaims.read(@kind, claim_key)
    refute JobClaims.live?(row)
  end

  test "a live peer's claim is read out, not raced: no provider call happens here", %{
    key: key,
    claim_key: claim_key
  } do
    {:ok, peer} = JobClaims.claim(@kind, claim_key, "member-b", 30_000)
    posted = :counters.new(1, [:atomics])

    refresh = fn ->
      :counters.add(posted, 1, 1)
      {:ok, "ours"}
    end

    assert {:ok, "the peer's"} = RefreshLock.run(key, refresh, fn -> {:ok, "the peer's"} end)

    assert :counters.get(posted, 1) == 0,
           "this member POSTed beside the member that held the cell's claim"

    # The peer's claim is untouched: a live claim is never taken.
    assert {:ok, still_held} = JobClaims.read(@kind, claim_key)
    assert still_held.owner == "member-b"
    assert still_held.fence == peer.fence
  end

  test "a peer that gives the claim up without a fresh bundle hands leadership on", %{
    key: key,
    claim_key: claim_key
  } do
    {:ok, peer} = JobClaims.claim(@kind, claim_key, "member-b", 30_000)
    posted = :counters.new(1, [:atomics])
    rechecks = :counters.new(1, [:atomics])

    # The peer finishes — and leaves nothing fresh behind, which is what a
    # leader that crashed mid-refresh looks like from here.
    recheck = fn ->
      :counters.add(rechecks, 1, 1)
      if :counters.get(rechecks, 1) >= 2, do: JobClaims.release(peer)
      :stale
    end

    refresh = fn ->
      :counters.add(posted, 1, 1)
      {:ok, "ours"}
    end

    assert {:ok, "ours"} = RefreshLock.run(key, refresh, recheck)
    assert :counters.get(posted, 1) == 1

    assert {:ok, row} = JobClaims.read(@kind, claim_key)
    assert row.owner == Cyfr.Boot.id()
    refute JobClaims.live?(row)
  end

  test "a wait on a peer that never finishes ends at its bound", %{
    key: key,
    claim_key: claim_key
  } do
    {:ok, _peer} = JobClaims.claim(@kind, claim_key, "member-b", 30_000)
    posted = :counters.new(1, [:atomics])

    refresh = fn ->
      :counters.add(posted, 1, 1)
      {:ok, "ours"}
    end

    assert {:error, {:authorization_required, detail}} =
             RefreshLock.run(key, refresh, fn -> :stale end, 400)

    assert detail =~ "concurrent token refresh"
    assert :counters.get(posted, 1) == 0
  end
end
