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

  test "a TTL below the execution ceiling is clamped — live rows survive the sweep" do
    original = Application.get_env(:cyfr, :oauth_token_ttl_ms)
    # Token retention must cover the 30-minute execution ceiling so
    # finalization can still collect tokens for masking.
    Application.put_env(:cyfr, :oauth_token_ttl_ms, -1)

    on_exit(fn ->
      if original,
        do: Application.put_env(:cyfr, :oauth_token_ttl_ms, original),
        else: Application.delete_env(:cyfr, :oauth_token_ttl_ms)
    end)

    :ok = OAuthTokenTracker.put("exec_tracker_test", "tok-a")
    assert OAuthTokenTracker.sweep_now() == 0
    assert ["tok-a"] = OAuthTokenTracker.collect("exec_tracker_test")
  end

  test "draining is collect-and-delete, so a second reader gets nothing" do
    # This is why nobody may drain the tracker except the one caller that
    # masks with the result: the tokens are gone after the first collect.
    :ok = OAuthTokenTracker.put("exec_drain_once", "tok-live")

    assert ["tok-live"] = OAuthTokenTracker.collect("exec_drain_once")
    assert [] = OAuthTokenTracker.collect("exec_drain_once")
  end

  test "the executor never drains the tracker without masking with the result" do
    # Failure masking must collect OAuth tokens before any cleanup drains the tracker.
    source =
      [__DIR__, "../../lib/opus/executor.ex"]
      |> Path.join()
      |> Path.expand()
      |> File.read!()

    bare =
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _n} ->
        trimmed = String.trim(line)

        String.starts_with?(trimmed, "Opus.OAuthHandler.collect_dispensed(") or
          String.starts_with?(trimmed, "OAuthHandler.collect_dispensed(")
      end)
      |> Enum.map(fn {line, n} -> "executor.ex:#{n}: #{String.trim(line)}" end)

    assert bare == [],
           "collect_dispensed called for its side effect, discarding the tokens: #{inspect(bare)}"
  end
end
