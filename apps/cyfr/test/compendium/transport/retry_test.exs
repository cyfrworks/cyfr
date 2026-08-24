# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Transport.RetryTest do
  use ExUnit.Case, async: true

  alias Compendium.Transport.Retry

  describe "classify/1" do
    test "429 retries for any method; 5xx only for idempotent ones" do
      assert Retry.classify({:status, 429}) == :retry_always
      assert Retry.classify({:status, 500}) == :retry_if_idempotent
      assert Retry.classify({:status, 503}) == :retry_if_idempotent
      assert Retry.classify({:status, 404}) == :never
      assert Retry.classify({:status, 200}) == :never
    end

    test "an unreached host retries; an ambiguous transport error is method-gated" do
      for reason <- [:econnrefused, :nxdomain, :ehostunreach, :enetunreach, :ehostdown] do
        assert Retry.classify({:error, reason}) == :retry_always
        assert Retry.classify({:error, %{reason: reason}}) == :retry_always
      end

      assert Retry.classify({:error, :timeout}) == :retry_if_idempotent
      assert Retry.classify({:error, %Mint.TransportError{reason: :closed}}) ==
               :retry_if_idempotent
    end

    test "an SSRF refusal — a binary reason — is a decision, never retried" do
      assert Retry.classify({:error, "private IP 127.0.0.1 blocked"}) == :never
    end
  end

  test "idempotent?/1 excludes exactly the minting methods" do
    for method <- [:get, :head, :put, :delete, :options], do: assert(Retry.idempotent?(method))
    refute Retry.idempotent?(:post)
    refute Retry.idempotent?(:patch)
  end

  describe "retry_after_ms/1" do
    test "delta-seconds, clamped" do
      assert Retry.retry_after_ms([{"retry-after", "2"}]) == 2_000
      assert Retry.retry_after_ms([{"retry-after", "100000"}]) == 30_000
      assert Retry.retry_after_ms([{"retry-after", "-5"}]) == 0
    end

    test "an HTTP-date in the near future is honoured; the past and garbage are 0" do
      header =
        DateTime.utc_now()
        |> DateTime.add(5)
        |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
      ms = Retry.retry_after_ms([{"retry-after", header}])
      assert ms > 0 and ms <= 5_000

      assert Retry.retry_after_ms([{"retry-after", "Wed, 21 Oct 2015 07:28:00 GMT"}]) == 0
      assert Retry.retry_after_ms([{"retry-after", "soon"}]) == 0
      assert Retry.retry_after_ms([]) == 0
    end
  end

  test "backoff/1 doubles from 500ms" do
    assert Retry.backoff(0) == 500
    assert Retry.backoff(1) == 1_000
    assert Retry.backoff(2) == 2_000
  end
end
