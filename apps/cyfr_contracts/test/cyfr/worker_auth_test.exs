# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.WorkerAuthTest do
  @moduledoc """
  The worker key schedule and headers: every derived key is distinct per
  label and per attempt field; a host call verifies against the root at the
  current generation and is refused, in order, when its timestamp is outside
  the 30-second window, when its MAC is forged or made with any key but its
  attempt's, and when its generation is not current; WorkerAPI requests and
  worker service reports verify only as their own kind, under the dispatch
  key.
  """
  use ExUnit.Case, async: true

  alias Cyfr.WorkerAuth

  @root :binary.list_to_bin(Enum.to_list(0..31))
  @now 1_789_305_249_602
  @body ~s({"attempts":["att_1"]})

  @attempt %{
    athanor_id: "ath_01a09fee-045b-770b-b745-a62792bb8798",
    execution_id: "exec_01a09fee-07cc-791f-a598-e7f90608c9e2",
    attempt: "att_01a09fee-0a31-7a2b-8f0c-3d1e5b7c9a42",
    fence: 2,
    generation: 7
  }

  defp call(overrides \\ %{}) do
    @attempt
    |> Map.merge(%{runner: "run_4f3c2a1e", ts: @now, nonce: "n_7d3e9a"})
    |> Map.merge(overrides)
  end

  defp attempt_key!(fields) do
    {:ok, key} = WorkerAuth.attempt_key(@root, fields)
    key
  end

  defp call_header!(call, key \\ nil, body \\ @body) do
    {:ok, header} = WorkerAuth.host_call_header(key || attempt_key!(call), call, body)
    header
  end

  defp verify(header, opts \\ []) do
    WorkerAuth.verify_host_call(
      @root,
      header,
      Keyword.get(opts, :body, @body),
      Keyword.get(opts, :now, @now),
      Keyword.get(opts, :generation, 7)
    )
  end

  describe "key schedule" do
    test "every key is 32 bytes, stable, and distinct per label" do
      {:ok, attempt} = WorkerAuth.attempt_key(@root, @attempt)

      keys = [
        WorkerAuth.dispatch_key(@root),
        WorkerAuth.dispatch_seal_key(@root),
        WorkerAuth.assign_key(@root),
        attempt
      ]

      assert Enum.all?(keys, &(byte_size(&1) == 32))
      assert Enum.uniq(keys) == keys
      refute @root in keys
      assert WorkerAuth.assign_key(@root) == WorkerAuth.assign_key(@root)

      other_root = :binary.list_to_bin(Enum.to_list(1..32))
      refute WorkerAuth.assign_key(other_root) == WorkerAuth.assign_key(@root)
    end

    test "an attempt key is distinct per attempt field and ignores the rest" do
      base = attempt_key!(@attempt)

      variants = [
        athanor_id: "ath_other",
        execution_id: "exec_other",
        attempt: "att_other",
        fence: 3,
        generation: 8
      ]

      keys = for {field, value} <- variants, do: attempt_key!(Map.put(@attempt, field, value))

      assert Enum.uniq([base | keys]) == [base | keys]
      assert attempt_key!(call(%{runner: "run_other", ts: 1, nonce: "n_other"})) == base
    end

    test "an attempt key refuses an invalid field" do
      assert {:error, {:invalid_field, :fence}} =
               WorkerAuth.attempt_key(@root, %{@attempt | fence: -1})

      assert {:error, {:invalid_field, :athanor_id}} =
               WorkerAuth.attempt_key(@root, %{@attempt | athanor_id: "ath 1"})

      assert {:error, {:invalid_field, :generation}} =
               WorkerAuth.attempt_key(@root, Map.delete(@attempt, :generation))
    end
  end

  describe "host call" do
    test "verifies against the root, answering its fields" do
      call = call()
      header = call_header!(call)

      assert header =~
               ~r/\Av1 kind=call athanor_id=ath_\S+ execution_id=\S+ attempt=\S+ fence=2 generation=7 runner=run_4f3c2a1e ts=1789305249602 nonce=n_7d3e9a mac=\S+\z/

      assert {:ok, ^call} = verify(header)
    end

    test "is refused when its timestamp is outside the window, on either side" do
      header = call_header!(call())

      assert {:ok, _} = verify(header, now: @now + 30_000)
      assert {:ok, _} = verify(header, now: @now - 30_000)
      assert {:error, :outside_window} = verify(header, now: @now + 30_001)
      assert {:error, :outside_window} = verify(header, now: @now - 30_001)
    end

    test "is refused when its MAC is forged" do
      call = call()
      header = call_header!(call)
      forged_mac = Base.url_encode64(:binary.copy(<<0>>, 32), padding: false)
      [signed, _mac] = String.split(header, "mac=")

      assert {:error, :bad_mac} = verify(signed <> "mac=" <> forged_mac)
      assert {:error, :bad_mac} = verify(header, body: ~s({"attempts":["att_2"]}))
      assert {:error, :bad_mac} = verify(String.replace(header, "fence=2", "fence=3"))

      assert {:error, :bad_mac} =
               verify(String.replace(header, "runner=run_4f3c2a1e", "runner=run_x"))

      assert {:error, :bad_mac} = verify(String.replace(header, "nonce=n_7d3e9a", "nonce=n_x"))

      assert {:error, :bad_mac} =
               verify(String.replace(header, "ts=1789305249602", "ts=1789305249603"))
    end

    test "is refused when signed with another attempt's key" do
      other = attempt_key!(%{@attempt | attempt: "att_other"})
      successor = attempt_key!(%{@attempt | fence: 3})

      assert {:error, :bad_mac} = verify(call_header!(call(), other))
      assert {:error, :bad_mac} = verify(call_header!(call(), successor))
    end

    test "is refused when signed with the dispatch, seal or assign key" do
      for key <- [
            WorkerAuth.dispatch_key(@root),
            WorkerAuth.dispatch_seal_key(@root),
            WorkerAuth.assign_key(@root),
            @root
          ] do
        assert {:error, :bad_mac} = verify(call_header!(call(), key))
      end
    end

    test "is refused at another generation, even with its own generation's key" do
      previous = call(%{generation: 6})

      assert {:error, :generation_mismatch} = verify(call_header!(previous))
      assert {:error, :generation_mismatch} = verify(call_header!(call()), generation: 8)
    end

    test "checks the window before the MAC, and the MAC before the generation" do
      forged = call_header!(call(%{generation: 6}), WorkerAuth.dispatch_key(@root))

      assert {:error, :outside_window} = verify(forged, now: @now + 60_000)
      assert {:error, :bad_mac} = verify(forged)
    end

    test "is refused when the header is not one well-formed host-call header" do
      header = call_header!(call())

      assert {:error, :malformed} = verify(nil)
      assert {:error, :malformed} = verify("")
      assert {:error, :malformed} = verify(String.replace(header, "kind=call", "kind=request"))
      assert {:error, :malformed} = verify(String.replace(header, "fence=2", "fence=02"))
      assert {:error, :malformed} = verify(String.replace(header, " runner=run_4f3c2a1e", ""))
      assert {:error, :malformed} = verify(header <> " nonce=n_again")
    end
  end

  describe "WorkerAPI requests and reports" do
    @dispatch %{worker: "wrk_1", ts: @now, nonce: "n_1"}

    test "verify under the dispatch key as their own kind only" do
      key = WorkerAuth.dispatch_key(@root)
      {:ok, request} = WorkerAuth.request_header(key, @dispatch, @body)
      {:ok, report} = WorkerAuth.report_header(key, @dispatch, @body)

      assert {:ok, @dispatch} = WorkerAuth.verify_request(key, request, @body, @now)
      assert {:ok, @dispatch} = WorkerAuth.verify_report(key, report, @body, @now)
      assert {:error, :malformed} = WorkerAuth.verify_report(key, request, @body, @now)
      assert {:error, :malformed} = WorkerAuth.verify_request(key, report, @body, @now)

      forged = String.replace(report, "kind=report", "kind=request")
      assert {:error, :bad_mac} = WorkerAuth.verify_request(key, forged, @body, @now)
    end

    test "are refused outside the window, over another body or under another key" do
      key = WorkerAuth.dispatch_key(@root)
      {:ok, request} = WorkerAuth.request_header(key, @dispatch, @body)

      assert {:error, :outside_window} =
               WorkerAuth.verify_request(key, request, @body, @now + 30_001)

      assert {:error, :outside_window} =
               WorkerAuth.verify_request(key, request, @body, @now - 30_001)

      assert {:error, :bad_mac} = WorkerAuth.verify_request(key, request, "{}", @now)

      assert {:error, :bad_mac} =
               WorkerAuth.verify_request(WorkerAuth.assign_key(@root), request, @body, @now)

      {:ok, by_attempt} = WorkerAuth.request_header(attempt_key!(@attempt), @dispatch, @body)
      assert {:error, :bad_mac} = WorkerAuth.verify_request(key, by_attempt, @body, @now)

      readdressed = String.replace(request, "worker=wrk_1", "worker=wrk_2")
      assert {:error, :bad_mac} = WorkerAuth.verify_request(key, readdressed, @body, @now)
    end
  end
end
