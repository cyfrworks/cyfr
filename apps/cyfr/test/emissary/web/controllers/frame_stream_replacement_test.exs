# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.FrameStreamReplacementTest do
  @moduledoc """
  A frame's stream slot holds the stream it admitted and at most one
  replacement under a newer bearer of the same credential, reserved under
  one lock: an older bearer cannot chain another connection onto a held
  replacement, and two replacements of one stream cannot both be admitted.
  """

  use CyfrWeb.ConnCase, async: false

  import Prima.Test.Wait

  alias Prima.TinctureWire
  alias Sanctum.TinctureAuth

  @stream_ms 10_000

  setup do
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    Prima.Test.RateLimiter.reset!()
    Sanctum.TestContext.athanor!()
    issuer = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
    {:ok, session} = Sanctum.TestContext.create_session(issuer)
    {:ok, source} = Sanctum.Caller.establish(session.token)
    {:ok, source: source}
  end

  test "a held replacement admits no other connection under the old bearer", %{
    source: source
  } do
    Cyfr.Test.Settings.put("frame_stream_max_concurrent", 1)
    frame = canvas_frame!(source)
    old = open_stream(source, frame.frame_id, frame.bearer)

    {:ok, %{credential: renewed}} = TinctureAuth.renew_frame(source, frame.id)
    refute renewed == frame.bearer
    replacement = open_stream(source, frame.frame_id, renewed)

    # All three opens happen sequentially, after the previous open either
    # subscribed or finished. This does not exercise a count/register race.
    # The first two requests are still connected when the old bearer is
    # reused; their two valid bearers must not form an unbounded chain.
    third = open_stream(source, frame.frame_id, frame.bearer)
    tasks = [old, replacement, third]

    try do
      {:ok, _} = TinctureAuth.revoke_frame(source, frame.id)
      [old_conn, replacement_conn, third_conn] = Enum.map(tasks, &Task.await(&1, @stream_ms))

      assert old_conn.status == 200
      assert replacement_conn.status == 200

      assert third_conn.status == 429,
             "at a one-stream cap, old/new/old opened three overlapping connections: " <>
               inspect(Enum.map([old_conn, replacement_conn, third_conn], & &1.status))

      assert {:refused, %{class: "rate_limited"}} =
               TinctureWire.decode_answer(:stream_open, Jason.decode!(third_conn.resp_body))
    after
      TinctureAuth.revoke_frame(source, frame.id)

      for task <- tasks, Process.alive?(task.pid) do
        Task.shutdown(task, :brutal_kill)
      end
    end
  end

  test "two replacements of one stream claimed at once are reserved one after the other, and only one is admitted",
       %{source: source} do
    instrument_after_snapshot!()
    Cyfr.Test.Settings.put("frame_stream_max_concurrent", 1)
    frame = canvas_frame!(source)
    old = open_stream(source, frame.frame_id, frame.bearer)
    {:ok, %{credential: renewed}} = TinctureAuth.renew_frame(source, frame.id)

    replacements =
      for _ <- 1..2 do
        open_stream(source, frame.frame_id, renewed,
          pause_after_snapshot: self(),
          defer_wait: true
        )
      end

    old_pid = old.pid
    pids = Enum.map(replacements, & &1.pid)

    # One claim reads the slots and reserves under the key's lock: while
    # the first replacement holds it, the second reads nothing, and once
    # the first has reserved, the second reads the slot it took. Only
    # their scheduling is instrumented; admission and registration remain
    # production code.
    assert_receive {:sse_snapshot_read, first_pid, [{^old_pid, _}]}, @stream_ms
    assert first_pid in pids
    refute_receive {:sse_snapshot_read, _other, _held}, 300
    send(first_pid, :finish_sse_snapshot)

    assert_receive {:sse_snapshot_read, second_pid, held}, @stream_ms
    assert second_pid in pids and second_pid != first_pid
    assert Enum.sort(Enum.map(held, &elem(&1, 0))) == Enum.sort([old_pid, first_pid])
    send(second_pid, :finish_sse_snapshot)
    Enum.each(replacements, &wait_for_open_or_finish(source, &1))
    tasks = [old | replacements]

    try do
      {:ok, _} = TinctureAuth.revoke_frame(source, frame.id)
      [old_conn | new_conns] = Enum.map(tasks, &Task.await(&1, @stream_ms))
      assert old_conn.status == 200

      assert Enum.sort(Enum.map(new_conns, & &1.status)) == [200, 429],
             "both concurrent renewed-bearer requests replaced the same held stream: " <>
               inspect(Enum.map(new_conns, & &1.status))
    after
      TinctureAuth.revoke_frame(source, frame.id)

      for task <- tasks, Process.alive?(task.pid) do
        Task.shutdown(task, :brutal_kill)
      end
    end
  end

  defp open_stream(source, frame_id, bearer, opts \\ []) do
    task =
      Task.async(fn ->
        if parent = Keyword.get(opts, :pause_after_snapshot) do
          Process.put(:sse_after_snapshot, parent)
        end

        body =
          TinctureWire.request(:stream_open, %{stream: "mcp_servers.changes", subject: nil})

        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "null")
        |> put_req_header("authorization", TinctureWire.bearer(bearer))
        |> post(Prima.CanvasWire.stream_path(frame_id), Jason.encode!(body))
      end)

    on_exit(fn ->
      monitor = Process.monitor(task.pid)
      if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)

      receive do
        {:DOWN, ^monitor, :process, _, _} -> :ok
      after
        @stream_ms -> raise "the stream did not stop"
      end
    end)

    unless Keyword.get(opts, :defer_wait, false), do: wait_for_open_or_finish(source, task)
    task
  end

  defp wait_for_open_or_finish(source, task) do
    topic = Cyfr.Bus.mcp_servers(Sanctum.Context.actor(source))

    wait_until(
      fn ->
        not Process.alive?(task.pid) or
          (Process.info(task.pid, :current_function) ==
             {:current_function, {CyfrWeb.SSE, :loop, 2}} and
             Enum.any?(Registry.lookup(Cyfr.PubSub, topic), &(elem(&1, 0) == task.pid)))
      end,
      @stream_ms
    )
  end

  defp instrument_after_snapshot! do
    module = CyfrWeb.SSE
    {^module, original_beam, beam_file} = :code.get_object_code(module)
    original_options = Code.compiler_options()

    # Every stream's later on_exit callback stops it before this restore.
    # Register restoration before changing loaded code or compiler options.
    on_exit(fn ->
      :code.purge(module)
      {:module, ^module} = :code.load_binary(module, beam_file, original_beam)
      Code.compiler_options(Map.to_list(original_options))
    end)

    source_file = module.module_info(:compile) |> Keyword.fetch!(:source) |> to_string()
    source = File.read!(source_file)
    insertion = "    held = CyfrWeb.SSE.Registry.entries(key)"
    assert length(String.split(source, insertion)) == 2, "SSE snapshot instrumentation site moved"

    pause = """
        if parent = Process.delete(:sse_after_snapshot) do
          send(parent, {:sse_snapshot_read, self(), held})

          receive do
            :finish_sse_snapshot -> :ok
          after
            10_000 -> raise "SSE snapshot reader not released"
          end
        end
    """

    instrumented = String.replace(source, insertion, insertion <> "\n" <> pause)
    Code.compiler_options(ignore_module_conflict: true)

    try do
      assert [{^module, _instrumented_beam}] = Code.compile_string(instrumented, source_file)
    after
      Code.compiler_options(Map.to_list(original_options))
    end
  end

  defp canvas_frame!(source) do
    name = "replacement-chain-#{System.unique_integer([:positive])}"

    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => %{
        "frame" => %{"placement" => "canvas"},
        "canvas" => %{"module" => "canvas.js", "toolkit" => 1},
        "streams" => [%{"name" => "mcp_servers.changes"}]
      }
    }

    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, name), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(source), %{
        id: "cmp_#{name}",
        name: name,
        version: "1.0.0",
        component_type: "tincture",
        description: name,
        tags: "[]",
        digest: digest,
        release_digest: release_digest,
        size: 100,
        exports: "[]",
        manifest: Jason.encode!(manifest),
        publisher: "local",
        publisher_id: "local|local|testns",
        source: Compendium.Source.filesystem(),
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })

    Sanctum.Test.ConsentFixtures.grant_tincture!(source, "tincture:local.#{name}")

    {:ok, %{revision: revision}} =
      Sanctum.Consent.tincture_grant(source, "tincture:local.#{name}:1.0.0")

    frame_id = "frm_chain_#{System.unique_integer([:positive])}"
    reference = %{publisher: "local", name: name, version: "1.0.0"}

    {:ok, %{credential: bearer, id: id}} =
      TinctureAuth.mint_frame_credential(source, reference, release_digest, revision, frame_id)

    %{bearer: bearer, id: id, frame_id: frame_id}
  end
end
