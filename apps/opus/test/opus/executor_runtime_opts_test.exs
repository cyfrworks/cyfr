# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutorRuntimeOptsTest do
  @moduledoc """
  Who gets the last word on the options the runtime runs under.

  Checks that consented limits, resources, and memory ceilings take
  precedence over caller-supplied runtime options.
  """
  use ExUnit.Case, async: true

  alias Opus.Executor

  # What enforce_authority/3 produces.
  defp consented do
    [
      component_type: :reagent,
      timeout_ms: 60_000,
      max_memory_bytes: 64 * 1024 * 1024,
      edge: %{storage: %{paths: ["data/"], actions: ["read"]}},
      limits: %{max_concurrent_tasks: 1},
      ctx: :a_context,
      execution_id: "exec_1"
    ]
  end

  test "consent wins over caller opts for everything it settled" do
    caller = [
      max_memory_bytes: 4 * 1024 * 1024 * 1024,
      limits: %{max_concurrent_tasks: 9_999},
      edge: %{storage: %{paths: ["*"], actions: ["read", "write", "delete"]}},
      component_type: :formula
    ]

    out = Executor.runtime_opts(consented(), caller)

    assert out[:max_memory_bytes] == 64 * 1024 * 1024
    assert out[:limits] == %{max_concurrent_tasks: 1}
    assert out[:edge] == %{storage: %{paths: ["data/"], actions: ["read"]}}
    assert out[:component_type] == :reagent
  end

  test "caller opts still fill in what consent did not settle" do
    caller = [
      preloaded_fields: %{"token" => "t"},
      root_execution_id: "exec_root",
      declared_needs: ["dest"],
      authority: :an_authority
    ]

    out = Executor.runtime_opts(consented(), caller)

    assert out[:preloaded_fields] == %{"token" => "t"}
    assert out[:root_execution_id] == "exec_root"
    assert out[:declared_needs] == ["dest"]
    assert out[:authority] == :an_authority
    # ...and what consent did settle is still there.
    assert out[:limits] == %{max_concurrent_tasks: 1}
  end

  test "the pipeline's own keys are protected too, not just the consented four" do
    # :ctx scopes every host import, :preloaded_fields is the unsealed
    # vault map, :digest keys the compiled-component cache — a caller
    # overwriting any of them would run under another tenant, other
    # secrets, or another component's compiled bytes.
    pipeline =
      consented() ++
        [
          preloaded_fields: %{"key" => "sealed"},
          digest: "sha256:real",
          execution_attempt: "att_1"
        ]

    caller = [
      ctx: :attacker_context,
      preloaded_fields: %{"key" => "injected"},
      execution_id: "exec_other",
      execution_attempt: "att_other",
      digest: "sha256:poisoned"
    ]

    out = Executor.runtime_opts(pipeline, caller)

    assert out[:ctx] == :a_context
    assert out[:preloaded_fields] == %{"key" => "sealed"}
    assert out[:execution_id] == "exec_1"
    assert out[:execution_attempt] == "att_1"
    assert out[:digest] == "sha256:real"
  end

  test "the attempt that owns the row reaches the runtime" do
    # The lease watch renews under it and a guest's spawns are charged to
    # it: without it every renewal answers lost, and a run still going at
    # the first lease tick is killed.
    out = Executor.runtime_opts(consented() ++ [execution_attempt: "att_1"], [])

    assert out[:execution_attempt] == "att_1"
  end

  test "with no authority-derived value, the caller's is used" do
    # A pipeline that never reached enforce_authority has nothing to protect,
    # so the guard must not turn into "the caller may never say".
    out = Executor.runtime_opts([ctx: :a_context], max_memory_bytes: 123, limits: %{a: 1})

    assert out[:max_memory_bytes] == 123
    assert out[:limits] == %{a: 1}
  end

  test "only the runtime's own keys survive" do
    out = Executor.runtime_opts(consented(), some_unrelated_key: :dropped)

    refute Keyword.has_key?(out, :some_unrelated_key)
    # `timeout_ms` is passed to the runtime separately, not through here.
    refute Keyword.has_key?(out, :timeout_ms)
  end
end
