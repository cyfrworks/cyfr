# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.OAuthTokenTrackerTest do
  # Dispensed OAuth tokens live in a :private, owner-mediated table so no other
  # process can read or plant them, and undrained rows are swept.
  use ExUnit.Case, async: false

  alias Opus.OAuthTokenTracker

  @table :opus_oauth_dispensed_tokens

  setup do
    # A drain leaves the singleton's table empty for the next test.
    on_exit(fn -> OAuthTokenTracker.collect("exec_tracker_test") end)
    :ok
  end

  test "put then collect returns the dispensed tokens" do
    :ok = OAuthTokenTracker.put("exec_tracker_test", "tok-a")
    :ok = OAuthTokenTracker.put("exec_tracker_test", "tok-b")

    assert OAuthTokenTracker.collect("exec_tracker_test") |> Enum.sort() == ["tok-a", "tok-b"]
  end

  test "collect is idempotent — a second drain is empty" do
    :ok = OAuthTokenTracker.put("exec_tracker_test", "tok-a")
    assert ["tok-a"] = OAuthTokenTracker.collect("exec_tracker_test")
    assert [] = OAuthTokenTracker.collect("exec_tracker_test")
  end

  test "collect(nil) is empty" do
    assert [] = OAuthTokenTracker.collect(nil)
  end

  test "the token table is private — no other process may read it" do
    :ok = OAuthTokenTracker.put("exec_tracker_test", "tok-a")
    # A :private table raises for any process that is not its owner.
    assert catch_error(:ets.lookup(@table, "exec_tracker_test"))
  end

  test "the sweep drops rows past their TTL" do
    original = Application.get_env(:cyfr, :oauth_token_ttl_ms)
    # A negative TTL puts the cutoff in the future, so any existing row is stale.
    Application.put_env(:cyfr, :oauth_token_ttl_ms, -1)

    on_exit(fn ->
      if original,
        do: Application.put_env(:cyfr, :oauth_token_ttl_ms, original),
        else: Application.delete_env(:cyfr, :oauth_token_ttl_ms)
    end)

    :ok = OAuthTokenTracker.put("exec_tracker_test", "tok-a")
    assert OAuthTokenTracker.sweep_now() >= 1
    assert [] = OAuthTokenTracker.collect("exec_tracker_test")
  end
end
