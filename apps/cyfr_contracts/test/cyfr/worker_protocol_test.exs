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

  test "the wire's bounds are the shared limits" do
    assert HostAPI.max_body_bytes() == Cyfr.Limits.default_max_request_size()
    assert HostAPI.max_answer_bytes() == Cyfr.Limits.default_max_response_size()
    assert HostAPI.max_body_bytes() > 0 and HostAPI.max_answer_bytes() > 0
    assert Assignment.claim_window_ms() == 30_000
    assert WorkerAuth.window_ms() == 30_000
  end
end
