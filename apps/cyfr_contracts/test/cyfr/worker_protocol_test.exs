# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.WorkerProtocolTest do
  @moduledoc """
  The data the worker protocol publishes beside its callbacks: what a
  client may do when an answer is lost, how long it waits for one, and
  how much may cross. Every callback of both behaviours has an answer, and
  no answer names a callback that does not exist.
  """

  use ExUnit.Case, async: true

  alias Cyfr.{Assignment, HostAPI, WorkerAPI, WorkerAuth}

  defp behaviour_callbacks(module) do
    module.behaviour_info(:callbacks) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  end

  test "every host callback has a retry class and a timeout, and nothing else does" do
    assert Enum.sort(HostAPI.callbacks()) == behaviour_callbacks(HostAPI)

    for callback <- HostAPI.callbacks() do
      assert HostAPI.retry(callback) in [:idempotent, :outcome, :batch, :keyed, :never]
      assert HostAPI.request_timeout_ms(callback) == WorkerAuth.window_ms()
    end

    assert_raise FunctionClauseError, fn -> HostAPI.retry(:not_a_callback) end
  end

  test "only calls whose effect cannot happen twice may be repeated" do
    assert HostAPI.retry(:attach) == :idempotent
    assert HostAPI.retry(:renew) == :idempotent
    assert HostAPI.retry(:fetch_artifact) == :idempotent
    assert HostAPI.retry(:release_child) == :idempotent
    assert HostAPI.retry(:runner_exited) == :idempotent
    assert HostAPI.retry(:complete) == :outcome
    assert HostAPI.retry(:fail) == :outcome
    assert HostAPI.retry(:push_deltas) == :batch
    assert HostAPI.retry(:admit_child) == :keyed

    for effect <- [:tool_call, :storage, :oauth_token, :take_rate, :record_denial] do
      assert HostAPI.retry(effect) == :never
    end
  end

  test "a child key is unpadded base64url text of 1 to 128 characters" do
    assert HostAPI.valid_child_key?("c")
    assert HostAPI.valid_child_key?("ck_" <> String.duplicate("A9-_", 31) <> "z")
    refute HostAPI.valid_child_key?("")
    refute HostAPI.valid_child_key?(String.duplicate("a", 129))
    refute HostAPI.valid_child_key?("with space")
    refute HostAPI.valid_child_key?("ck=")
    refute HostAPI.valid_child_key?(nil)
    refute HostAPI.valid_child_key?(:atom)
  end

  test "every worker callback has a retry class and a timeout" do
    assert Enum.sort(WorkerAPI.callbacks()) == behaviour_callbacks(WorkerAPI)
    assert WorkerAPI.retry(:start) == :never
    assert WorkerAPI.retry(:kill) == :idempotent
    assert WorkerAPI.retry(:status) == :idempotent
    assert WorkerAPI.request_timeout_ms(:start) == Assignment.claim_window_ms()
    assert WorkerAPI.request_timeout_ms(:kill) == 5_000
    assert WorkerAPI.request_timeout_ms(:status) == 5_000
  end

  test "a status counts runners as fresh, idle, busy or tainted, and says what bounds and refuses them" do
    assert WorkerAPI.runner_states() == [:fresh, :idle, :busy, :tainted]

    status = %{
      service: "wrk_4f3c2a1e9d8b7c6a",
      boot: "boot_01a09fee-2e4f-7a5b-9c6d-7e8f9a0b1c2d",
      runners: %{fresh: 2, idle: 1, busy: 3, tainted: 1},
      attempts: ["att_01a09fee-0a31-7a2b-8f0c-3d1e5b7c9a42"],
      memory_bytes: 402_653_184,
      refusal: nil
    }

    refusal = %{reason: "memory_unavailable", message: "writable-cgroups=true is missing"}

    assert WorkerAPI.valid_status?(status)
    assert WorkerAPI.valid_status?(%{status | runners: %{fresh: 0, idle: 0, busy: 0, tainted: 0}})
    assert WorkerAPI.valid_status?(%{status | attempts: []})
    assert WorkerAPI.valid_status?(%{status | memory_bytes: nil})
    assert WorkerAPI.valid_status?(%{status | refusal: refusal})

    for bad <- [
          %{status | runners: Map.delete(status.runners, :tainted)},
          %{status | runners: Map.put(status.runners, :zombie, 1)},
          %{status | runners: %{status.runners | busy: -1}},
          %{status | runners: %{status.runners | idle: "1"}},
          %{status | runners: []},
          %{status | attempts: [:att]},
          %{status | service: nil},
          %{status | boot: 7},
          %{status | memory_bytes: 0},
          %{status | refusal: %{refusal | reason: :memory_unavailable}},
          %{status | refusal: Map.put(refusal, :since, 1)},
          %{status | refusal: "memory_unavailable"},
          Map.delete(status, :attempts),
          Map.delete(status, :memory_bytes),
          Map.delete(status, :refusal),
          Map.put(status, :extra, true),
          nil
        ] do
      refute WorkerAPI.valid_status?(bad), inspect(bad)
    end

    assert_raise ArgumentError, fn -> WorkerAPI.status_to_wire(%{status | memory_bytes: -1}) end

    # A kill and a status are repeatable on a lost answer, within five seconds.
    assert WorkerAPI.retry(:kill) == :idempotent
    assert WorkerAPI.retry(:status) == :idempotent
    assert WorkerAPI.request_timeout_ms(:kill) == 5_000
    assert WorkerAPI.request_timeout_ms(:status) == 5_000
  end

  test "a refusal's sentence is 1 to 1024 bytes of UTF-8 without a control character, and a status carries no other" do
    for sentence <- [
          "writable-cgroups=true is missing",
          "x",
          String.duplicate("x", 1024),
          String.duplicate("é", 512),
          "a sentence — with a dash"
        ] do
      assert WorkerAPI.valid_refusal_message?(sentence), inspect(sentence)
    end

    for sentence <- [
          "",
          String.duplicate("x", 1025),
          String.duplicate("é", 513),
          "line\nbreak",
          "tab\there",
          "nul\0byte",
          "delete\x7F",
          <<0xFF, 0xFE>>,
          nil,
          42,
          :sentence,
          ["a sentence"]
        ] do
      refute WorkerAPI.valid_refusal_message?(sentence), inspect(sentence)
    end

    status = %{
      service: "wrk_4f3c2a1e9d8b7c6a",
      boot: "boot_01a09fee-2e4f-7a5b-9c6d-7e8f9a0b1c2d",
      runners: %{fresh: 0, idle: 0, busy: 0, tainted: 0},
      attempts: [],
      memory_bytes: 402_653_184,
      refusal: nil
    }

    for message <- [
          "writable-cgroups=true is missing",
          "",
          "line\nbreak",
          String.duplicate("x", 1025)
        ] do
      assert WorkerAPI.valid_status?(%{
               status
               | refusal: %{reason: "memory_unavailable", message: message}
             }) == WorkerAPI.valid_refusal_message?(message),
             inspect(message)
    end
  end

  describe "the status vectors" do
    @status_vectors Path.expand("../../../../tests/fixtures/worker_auth.json", __DIR__)
                    |> File.read!()
                    |> Jason.decode!()
                    |> Map.fetch!("status")

    test "every valid wire reads to a status that writes back to exactly that wire" do
      for %{"why" => why, "wire" => wire} <- @status_vectors["valid"] do
        assert {:ok, status} = WorkerAPI.read_status(wire), why
        assert WorkerAPI.valid_status?(status), why
        assert WorkerAPI.status_to_wire(status) == wire, why
      end
    end

    test "every invalid wire is refused" do
      for %{"why" => why, "wire" => wire} <- @status_vectors["invalid"] do
        assert WorkerAPI.read_status(wire) == :error, why
      end
    end

    test "the vectors cover a refusal, a bound and none" do
      statuses =
        for %{"wire" => wire} <- @status_vectors["valid"] do
          {:ok, status} = WorkerAPI.read_status(wire)
          status
        end

      assert Enum.any?(statuses, &(&1.memory_bytes == nil))
      assert Enum.any?(statuses, &is_integer(&1.memory_bytes))
      assert Enum.any?(statuses, &match?(%{refusal: %{reason: "memory_unavailable"}}, &1))
      assert Enum.any?(statuses, &(&1.refusal == nil))
    end
  end

  test "the wire's bounds are the shared limits" do
    assert HostAPI.max_body_bytes() == Cyfr.Limits.default_max_request_size()
    assert HostAPI.max_answer_bytes() == Cyfr.Limits.default_max_response_size()
    assert HostAPI.max_body_bytes() > 0 and HostAPI.max_answer_bytes() > 0
    assert Assignment.claim_window_ms() == 30_000
    assert WorkerAuth.window_ms() == 30_000
  end
end
