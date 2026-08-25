# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuildLimiterTest do
  # Not async: the singleton limiter and the app-env cap are node-global.
  use ExUnit.Case, async: false

  alias Locus.BuildLimiter

  setup do
    drain_limiter()

    on_exit(fn ->
      Application.delete_env(:cyfr, :max_concurrent_builds)
      drain_limiter()
    end)

    :ok
  end

  # The limiter is a supervised singleton shared with the rest of the suite;
  # rather than restart it (racing the supervisor), release any slots this
  # test process holds and wait for the cast queue to settle.
  defp drain_limiter do
    Application.put_env(:cyfr, :max_concurrent_builds, 1000)
    Enum.each(1..20, fn _ -> BuildLimiter.release() end)
    :sys.get_state(BuildLimiter)
    Application.delete_env(:cyfr, :max_concurrent_builds)
    :ok
  end

  defp settled(fun) do
    # Casts and :DOWN messages land asynchronously; a get_state round-trip
    # flushes everything already in the mailbox before asserting.
    :sys.get_state(BuildLimiter)
    fun.()
  end

  test "grants up to the cap, rejects past it, frees on release" do
    Application.put_env(:cyfr, :max_concurrent_builds, 2)

    assert :ok = BuildLimiter.acquire()
    assert :ok = BuildLimiter.acquire()
    assert {:error, :busy} = BuildLimiter.acquire()

    :ok = BuildLimiter.release()
    settled(fn -> assert :ok = BuildLimiter.acquire() end)

    :ok = BuildLimiter.release()
    :ok = BuildLimiter.release()
  end

  test "a rejected acquire does not eat a slot" do
    Application.put_env(:cyfr, :max_concurrent_builds, 1)

    assert :ok = BuildLimiter.acquire()
    assert {:error, :busy} = BuildLimiter.acquire()
    assert {:error, :busy} = BuildLimiter.acquire()

    :ok = BuildLimiter.release()
    settled(fn -> assert :ok = BuildLimiter.acquire() end)
    :ok = BuildLimiter.release()
  end

  test "the same holder may take several slots and they count individually" do
    Application.put_env(:cyfr, :max_concurrent_builds, 2)

    assert :ok = BuildLimiter.acquire()
    assert :ok = BuildLimiter.acquire()
    assert {:error, :busy} = BuildLimiter.acquire()

    :ok = BuildLimiter.release()
    settled(fn -> assert :ok = BuildLimiter.acquire() end)

    :ok = BuildLimiter.release()
    :ok = BuildLimiter.release()
  end

  test "a brutally killed holder frees its slot without calling release" do
    Application.put_env(:cyfr, :max_concurrent_builds, 1)
    parent = self()

    holder =
      spawn(fn ->
        :ok = BuildLimiter.acquire()
        send(parent, :acquired)

        receive do
          :never -> :ok
        end
      end)

    assert_receive :acquired, 1_000
    assert {:error, :busy} = BuildLimiter.acquire()

    # The MCP tool layer's Task.shutdown(:brutal_kill) and the SSE-cancel
    # Process.exit(pid, :cancelled) both bypass `after` — only the monitor
    # can return the slot.
    Process.exit(holder, :kill)

    wait_until(fn -> BuildLimiter.acquire() == :ok end)
    :ok = BuildLimiter.release()
  end

  test "release without acquire never underflows the count" do
    Application.put_env(:cyfr, :max_concurrent_builds, 1)

    :ok = BuildLimiter.release()
    :ok = BuildLimiter.release()

    settled(fn ->
      assert :ok = BuildLimiter.acquire()
      assert {:error, :busy} = BuildLimiter.acquire()
    end)

    :ok = BuildLimiter.release()
  end

  test "a killed holder releases every slot it held" do
    Application.put_env(:cyfr, :max_concurrent_builds, 2)
    parent = self()

    holder =
      spawn(fn ->
        :ok = BuildLimiter.acquire()
        :ok = BuildLimiter.acquire()
        send(parent, :acquired)

        receive do
          :never -> :ok
        end
      end)

    assert_receive :acquired, 1_000
    assert {:error, :busy} = BuildLimiter.acquire()

    Process.exit(holder, :kill)

    wait_until(fn -> BuildLimiter.acquire() == :ok end)
    settled(fn -> assert :ok = BuildLimiter.acquire() end)

    :ok = BuildLimiter.release()
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
    # Build records are rows now — the status lookup queries the Repo, so
    # this test needs its own sandbox connection like any DB test.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()

    assert {:error, message} =
             Locus.MCP.handle("build", ctx, %{"action" => "status", "build_id" => "build_nope"})

    assert message =~ "Unknown build"
  end

  defp wait_until(fun, deadline_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    Stream.repeatedly(fn ->
      if fun.() do
        :done
      else
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition not met within #{deadline_ms}ms")
        end

        Process.sleep(10)
        :again
      end
    end)
    |> Enum.find(&(&1 == :done))
  end
end
