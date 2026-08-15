# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuildLimiterTest do
  # Not async: the limiter is a node-global counter and these tests reach
  # through the app-env cap.
  use ExUnit.Case, async: false

  alias Locus.BuildLimiter

  setup do
    BuildLimiter.init()

    on_exit(fn ->
      Application.delete_env(:cyfr, :max_concurrent_builds)
      BuildLimiter.init()
    end)

    :ok
  end

  test "grants up to the cap, rejects past it, frees on release" do
    Application.put_env(:cyfr, :max_concurrent_builds, 2)

    assert :ok = BuildLimiter.acquire()
    assert :ok = BuildLimiter.acquire()
    assert {:error, :busy} = BuildLimiter.acquire()

    :ok = BuildLimiter.release()
    assert :ok = BuildLimiter.acquire()

    :ok = BuildLimiter.release()
    :ok = BuildLimiter.release()
  end

  test "a rejected acquire does not eat a slot" do
    Application.put_env(:cyfr, :max_concurrent_builds, 1)

    assert :ok = BuildLimiter.acquire()
    assert {:error, :busy} = BuildLimiter.acquire()
    assert {:error, :busy} = BuildLimiter.acquire()

    :ok = BuildLimiter.release()
    assert :ok = BuildLimiter.acquire()
    :ok = BuildLimiter.release()
  end

  test "compile refuses with a retryable message when capacity is exhausted" do
    Application.put_env(:cyfr, :max_concurrent_builds, 0)

    ctx = Sanctum.TestContext.local()

    assert {:error, message} =
             Locus.MCP.handle("build", ctx, %{
               "action" => "compile",
               "reference" => "reagent:local.anything:0.1.0"
             })

    assert message =~ "Build capacity is full"
  end

  test "status of an unknown build errors" do
    ctx = Sanctum.TestContext.local()

    assert {:error, message} =
             Locus.MCP.handle("build", ctx, %{"action" => "status", "build_id" => "build_nope"})

    assert message =~ "Unknown build"
  end
end
