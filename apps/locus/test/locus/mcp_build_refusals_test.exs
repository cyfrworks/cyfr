# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.MCPBuildRefusalsTest do
  @moduledoc """
  What the build tool answers when it cannot take a build slot: the node's
  cap, the athanor's, and slots not being handed out at all each refuse
  with the one retryable message; a killed build's slot comes back; and a
  build id nobody recorded is not found.
  """
  # Not async: the build slots are one node-global instance, and these
  # tests fill it, stop it and restart it with caps of their own.
  use ExUnit.Case, async: false

  alias Cyfr.Slots
  alias Locus.MCP

  @slots Locus.BuildSlots
  # A reference that parses and is local, so an admitted compile runs as far
  # as the source read and fails there: proof of admission without a
  # toolchain.
  @reference "reagent:local.nonexistent:0.1.0"

  setup do
    # Whatever a test did to the instance, the booted one is back for the
    # next module.
    on_exit(fn -> replace_build_slots(Locus.Application.build_slots()) end)
    :ok
  end

  describe "the build slots" do
    test "are one Cyfr.Slots instance with the configured caps, refusing rather than queueing" do
      assert {Cyfr.Slots, opts} = Locus.Application.build_slots()
      assert opts[:name] == @slots
      assert opts[:child_reserve] == 0
      assert opts[:policy] == :reject

      status = Slots.status(@slots)
      refute Map.has_key?(status, :error)
      assert status.max == opts[:max]
      assert status.key_max == opts[:key_max]
      assert status.child_reserve == 0
      assert Locus.Application.max_builds() == status.max
    end
  end

  describe "build.compile" do
    test "refuses with a retryable message at capacity, and a killed build's slot comes back" do
      restart_build_slots(max: 2, key_max: 1)
      holder = hold(nil, 2)

      assert {:error, message} = compile(local_ctx())
      assert message =~ "Build capacity is full (2 concurrent)"
      assert message =~ "retry shortly"
      assert %{active: 2, queued: 0} = Slots.status(@slots)

      # The tool layer's brutal kill and an SSE disconnect's exit both
      # bypass `after`; the slot's monitor returns it.
      Process.exit(holder, :kill)
      wait_until(fn -> Slots.status(@slots).active == 0 end)

      assert {:error, message} = compile(local_ctx())
      assert message =~ "Source not found"
    end

    test "refuses an athanor at its cap while another athanor's build is admitted" do
      restart_build_slots(max: 2, key_max: 1)
      _holder = hold("ath_a", 1)

      assert {:error, message} = compile(ctx_in("ath_a"))
      assert message =~ "Build capacity is full (2 concurrent)"

      # Admitted: the compile ran as far as the source read.
      assert {:error, message} = compile(ctx_in("ath_b"))
      assert message =~ "Source not found"
      assert %{active: 1, keys: %{"ath_a" => 1}} = Slots.status(@slots)
    end

    test "refuses with the same message when the build slots are down" do
      :ok = Supervisor.terminate_child(Locus.Supervisor, @slots)
      assert %{error: :unavailable} = Slots.status(@slots)

      assert {:error, message} = compile(local_ctx())

      # The cap named is the configured one, so the answer reads as it does
      # at capacity, not as a cap of zero.
      assert [cap] =
               Regex.run(
                 ~r/^Build capacity is full \((\d+) concurrent\) — retry shortly$/,
                 message,
                 capture: :all_but_first
               )

      assert String.to_integer(cap) >= 1
    end
  end

  describe "build.status" do
    test "of an unknown build errors" do
      # Build records are rows: the status lookup queries the Repo, so this
      # test needs its own sandbox connection like any DB test.
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

      assert {:error, {:not_found, "Build", "build_nope"}} =
               MCP.handle("build", local_ctx(), %{
                 "action" => "status",
                 "build_id" => "build_nope"
               })
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp compile(ctx),
    do: MCP.handle("build", ctx, %{"action" => "compile", "reference" => @reference})

  defp local_ctx, do: Sanctum.TestContext.local()

  defp ctx_in(athanor_id), do: %{local_ctx() | athanor_id: athanor_id}

  # The build slots restarted with caps of the test's own, so the numbers
  # asserted here are the test's and not the environment's.
  defp restart_build_slots(opts) do
    {Cyfr.Slots, booted} = Locus.Application.build_slots()
    replace_build_slots({Cyfr.Slots, Keyword.merge(booted, opts)})
  end

  defp replace_build_slots(spec) do
    case Supervisor.terminate_child(Locus.Supervisor, @slots) do
      :ok -> :ok = Supervisor.delete_child(Locus.Supervisor, @slots)
      {:error, :not_found} -> :ok
    end

    {:ok, _pid} = Supervisor.start_child(Locus.Supervisor, spec)
    :ok
  end

  # A process holding `n` root slots for `key` for as long as the test runs,
  # or until it is killed.
  defp hold(key, n) do
    test = self()

    holder =
      spawn(fn ->
        Process.monitor(test)
        results = for _ <- 1..n, do: Slots.acquire(@slots, key, :root, wait_ms: 0)
        send(test, {:held, self(), results})

        receive do
          {:DOWN, _ref, :process, ^test, _reason} -> :ok
        end
      end)

    assert_receive {:held, ^holder, results}, 2_000

    assert Enum.all?(results, &match?({:ok, _}, &1)),
           "could not hold #{n} slot(s) for #{inspect(key)}: #{inspect(results)}"

    holder
  end

  defp wait_until(fun, deadline_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    Stream.repeatedly(fn ->
      cond do
        fun.() ->
          :done

        System.monotonic_time(:millisecond) > deadline ->
          flunk("condition not met within #{deadline_ms}ms")

        true ->
          Process.sleep(10)
          :again
      end
    end)
    |> Enum.find(&(&1 == :done))
  end
end
