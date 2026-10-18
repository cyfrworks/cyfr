# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.FrameStreamSlotTest do
  @moduledoc """
  A frame's streams are counted per frame credential, and a claim counts
  and registers under one lock: a renewed credential opens no second
  connection for a stream already held, a bearer of the frame opens
  nothing past the cap whichever bearer it is, concurrent opens never
  take more slots than the cap, and a connection process reused for
  another request counts once.
  """

  use CyfrWeb.ConnCase, async: false

  import Prima.Test.Wait
  import Ecto.Query

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

  test "at the cap a stale bearer opens nothing, nor does the renewed one beside the stream it holds",
       %{source: source} do
    Cyfr.Test.Settings.put("frame_stream_max_concurrent", 1)
    frame = capped_frame!(source)
    {:ok, %{credential: renewed}} = TinctureAuth.renew_frame(source, frame.id)
    refute renewed == frame.bearer

    newest = open_stream(source, frame.frame_id, renewed)
    older = open_stream(source, frame.frame_id, frame.bearer)
    again = open_stream(source, frame.frame_id, renewed)
    tasks = [newest, older, again]

    try do
      {:ok, _} = TinctureAuth.revoke_frame(source, frame.id)
      statuses = Enum.map(tasks, &Task.await(&1, @stream_ms).status)
      assert statuses == [200, 429, 429]
    after
      TinctureAuth.revoke_frame(source, frame.id)
      for task <- tasks, Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end
  end

  test "two opens claimed at once are reserved one after the other, and only one takes the last slot",
       %{source: source} do
    instrument_before_count!()
    Cyfr.Test.Settings.put("frame_stream_max_concurrent", 1)
    frame = capped_frame!(source)

    opens =
      for _ <- 1..2 do
        open_stream(source, frame.frame_id, frame.bearer,
          pause_in_claim: self(),
          defer_wait: true
        )
      end

    pids = Enum.map(opens, & &1.pid)

    # One claim counts and registers under the key's lock: while the
    # first holds it, the second counts nothing.
    assert_receive {:sse_claim_counting, first_pid}, @stream_ms
    assert first_pid in pids
    refute_receive {:sse_claim_counting, _other}, 300
    send(first_pid, :finish_sse_claim)

    assert_receive {:sse_claim_counting, second_pid}, @stream_ms
    assert second_pid in pids and second_pid != first_pid
    send(second_pid, :finish_sse_claim)
    Enum.each(opens, &wait_for_open_or_finish(source, &1))

    try do
      {:ok, _} = TinctureAuth.revoke_frame(source, frame.id)
      statuses = Enum.map(opens, &Task.await(&1, @stream_ms).status)
      assert Enum.sort(statuses) == [200, 429]
    after
      TinctureAuth.revoke_frame(source, frame.id)
      for task <- opens, Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end
  end

  test "a connection process reused for another request counts once", %{source: source} do
    Cyfr.Test.Settings.put("frame_stream_max_concurrent", 1)
    {:ok, ctx} = Sanctum.Caller.establish({:frame_credential, capped_frame!(source).bearer})
    [first, extra] = owners = for _ <- 1..2, do: start_owner(ctx)

    try do
      assert :ok = claim(first)
      assert {:error, :stream_limit} = claim(extra)

      # The first stream ended, and its process lives on to serve another
      # request of the same connection.
      assert :ok = release(first)
      assert :ok = claim(first)
      assert {:error, :stream_limit} = claim(extra)
      assert {:error, :stream_limit} = claim(first)
    after
      for owner <- owners, do: send(owner.pid, :stop)
      for owner <- owners, do: Task.await(owner, 5_000)
    end
  end

  defp start_owner(ctx) do
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
      {:claim, parent, ref} ->
        send(
          parent,
          {ref, CyfrWeb.SSE.claim_slot(:frame_stream, ctx, :frame_stream_max_concurrent)}
        )

        owner_loop(ctx)

      {:release, parent, ref} ->
        send(parent, {ref, CyfrWeb.SSE.release_slot(:frame_stream, ctx)})
        owner_loop(ctx)

      :stop ->
        CyfrWeb.SSE.release_slot(:frame_stream, ctx)
    end
  end

  defp claim(task) do
    ref = make_ref()
    send(task.pid, {:claim, self(), ref})
    assert_receive {^ref, answer}, 5_000
    answer
  end

  defp release(task) do
    ref = make_ref()
    send(task.pid, {:release, self(), ref})
    assert_receive {^ref, answer}, 5_000
    answer
  end

  defp instrument_before_count! do
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

  defp capped_frame!(source) do
    Cyfr.Test.Settings.put("frame_credential_deadline_s", 3_600)
    hash = source.session_token_hash
    deadline = DateTime.add(Arca.ServerMetaStorage.now!(), 600, :second)

    # A live session near its expiry is an ordinary source. Both bearers
    # must stop there even when renewal occurs later.
    assert {1, _} =
             Arca.Repo.update_all(
               from(s in Arca.Schemas.Session, where: s.token_hash == ^hash),
               set: [expires_at: deadline]
             )

    Sanctum.Caller.invalidate_hash(hash)
    frame = canvas_frame!(source)
    assert {:ok, %{deadline: ^deadline}} = TinctureAuth.verify_frame_credential(frame.bearer)

    # The signature's issued-at value has second precision. Cross that
    # boundary so renewal produces different bearer bytes at the same cap.
    minted_second = DateTime.to_unix(Arca.ServerMetaStorage.now!())
    wait_until(fn -> DateTime.to_unix(Arca.ServerMetaStorage.now!()) > minted_second end, 3_000)
    frame
  end

  defp open_stream(source, frame_id, bearer, opts \\ []) do
    task =
      Task.async(fn ->
        if parent = Keyword.get(opts, :pause_in_claim) do
          Process.put(:sse_pause_in_claim, parent)
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
