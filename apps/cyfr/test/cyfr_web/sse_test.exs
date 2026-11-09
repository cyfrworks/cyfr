# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.SSETest do
  @moduledoc """
  The stream slots every SSE surface shares (`CyfrWeb.SSE.claim_slot/3`):
  counted per credential under each surface's own tag and setting, a
  released slot free at once, a connection process reused for another
  request counted once, and two claims made at once reserved one after the
  other under the key's lock, so only one takes the last slot.
  """

  # Writes platform settings and the stream slot registry, and recompiles
  # `CyfrWeb.SSE` for one case.
  use ExUnit.Case, async: false

  alias CyfrWeb.SSE
  alias Sanctum.Context

  # The MCP subscription surface's tag and setting (`Emissary.Web.McpController`).
  @listen_tag :mcp_listen
  @listen_limit :mcp_subscription_max_concurrent

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Cyfr.Test.Settings.put("mcp_subscription_max_concurrent", 1)
    Cyfr.Test.Settings.put("opus_events_max_concurrent", 1)
    {:ok, ctx: session("ath_sse_#{System.unique_integer([:positive])}")}
  end

  # A person's session context in `athanor`.
  defp session(athanor) do
    Context.build(
      user_id: "usr_sse",
      athanor_id: athanor,
      scope: :athanor,
      auth_method: :oidc,
      session_token_hash: :crypto.strong_rand_bytes(32),
      authenticated: true,
      validated_at: DateTime.utc_now()
    )
  end

  test "slots are counted per credential under each surface's tag, and a released slot is free at once",
       %{ctx: ctx} do
    assert :ok = SSE.claim_slot(@listen_tag, ctx, @listen_limit)
    assert {:error, :stream_limit} = SSE.claim_slot(@listen_tag, ctx, @listen_limit)

    # The same person's other session has a budget of its own, and so has
    # the other surface.
    other = %{ctx | session_token_hash: :crypto.strong_rand_bytes(32)}
    assert :ok = SSE.claim_slot(@listen_tag, other, @listen_limit)
    assert :ok = SSE.claim_slot(:sse_slot, ctx, :opus_events_max_concurrent)

    assert :ok = SSE.release_slot(@listen_tag, ctx)
    assert :ok = SSE.claim_slot(@listen_tag, ctx, @listen_limit)
  end

  test "a connection process reused for another request counts once", %{ctx: ctx} do
    [first, extra] = for _ <- 1..2, do: owner(ctx)

    assert :ok = claim(first)
    assert {:error, :stream_limit} = claim(extra)

    # The first stream ended, and its process lives on to serve another
    # request of the same connection.
    assert :ok = release(first)
    assert :ok = claim(first)
    assert {:error, :stream_limit} = claim(extra)
    assert {:error, :stream_limit} = claim(first)
  end

  test "two claims made at once are reserved one after the other, and only one takes the last slot",
       %{ctx: ctx} do
    instrument_before_count!()
    owners = for _ <- 1..2, do: owner(ctx)
    pids = Enum.map(owners, & &1.pid)
    refs = for owner <- owners, do: claim_async(owner, pause: true)

    # One claim counts and registers under the key's lock: while the
    # first holds it, the second counts nothing.
    assert_receive {:sse_claim_counting, first_pid}, 5_000
    assert first_pid in pids
    refute_receive {:sse_claim_counting, _other}, 300
    send(first_pid, :finish_sse_claim)

    assert_receive {:sse_claim_counting, second_pid}, 5_000
    assert second_pid in pids and second_pid != first_pid
    send(second_pid, :finish_sse_claim)

    answers =
      for ref <- refs do
        assert_receive {^ref, answer}, 5_000
        answer
      end

    assert Enum.sort(answers) == [:ok, {:error, :stream_limit}]
  end

  # A process that holds slots as a connection does: it claims and
  # releases when asked, and its slots end with it.
  defp owner(ctx) do
    task = Task.async(fn -> owner_loop(ctx) end)

    on_exit(fn ->
      monitor = Process.monitor(task.pid)
      if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)

      receive do
        {:DOWN, ^monitor, :process, _, _} -> :ok
      after
        5_000 -> raise "stream slot owner did not stop"
      end
    end)

    task
  end

  defp owner_loop(ctx) do
    receive do
      {:claim, parent, ref, pause?} ->
        if pause?, do: Process.put(:sse_pause_in_claim, parent)
        send(parent, {ref, SSE.claim_slot(@listen_tag, ctx, @listen_limit)})
        owner_loop(ctx)

      {:release, parent, ref} ->
        send(parent, {ref, SSE.release_slot(@listen_tag, ctx)})
        owner_loop(ctx)
    end
  end

  defp claim_async(owner, opts \\ []) do
    ref = make_ref()
    send(owner.pid, {:claim, self(), ref, Keyword.get(opts, :pause, false)})
    ref
  end

  defp claim(owner) do
    ref = claim_async(owner)
    assert_receive {^ref, answer}, 5_000
    answer
  end

  defp release(owner) do
    ref = make_ref()
    send(owner.pid, {:release, self(), ref})
    assert_receive {^ref, answer}, 5_000
    answer
  end

  # `CyfrWeb.SSE` compiled again with a pause where a claim counts the
  # key's slots, taken by a claimer that asked for one: it says so and
  # waits to be told to go on.
  defp instrument_before_count! do
    module = CyfrWeb.SSE
    {^module, original_beam, beam_file} = :code.get_object_code(module)
    original_options = Code.compiler_options()

    # Every owner's later on_exit callback stops it before this restore.
    # Register restoration before changing loaded code or compiler options.
    on_exit(fn ->
      :code.purge(module)
      {:module, ^module} = :code.load_binary(module, beam_file, original_beam)
      Code.compiler_options(Map.to_list(original_options))
    end)

    source_file = module.module_info(:compile) |> Keyword.fetch!(:source) |> to_string()
    source = File.read!(source_file)
    insertion = "    if CyfrWeb.SSE.Registry.count(key) >= limit do"
    assert length(String.split(source, insertion)) == 2, "SSE claim instrumentation site moved"

    pause = """
    if parent = Process.delete(:sse_pause_in_claim) do
      send(parent, {:sse_claim_counting, self()})

      receive do
        :finish_sse_claim -> :ok
      after
        10_000 -> raise "SSE claim not released"
      end
    end
    """

    instrumented = String.replace(source, insertion, pause <> insertion)
    Code.compiler_options(ignore_module_conflict: true)

    try do
      assert [{^module, _instrumented_beam}] = Code.compile_string(instrumented, source_file)
    after
      Code.compiler_options(Map.to_list(original_options))
    end
  end
end
