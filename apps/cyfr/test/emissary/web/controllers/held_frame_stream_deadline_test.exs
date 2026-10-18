# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.HeldFrameStreamDeadlineTest do
  @moduledoc """
  A frame's open stream held to its credential's row: at its grant's
  deadline it reads the row again, so a renewal the last revalidation did
  not see keeps it; the held reading is internal to revalidation; and no
  renewal moves a stream past its own bound from the open.
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

  setup do
    previous = Application.fetch_env(:sanctum, :caller_memo_ttl_ms)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sanctum, :caller_memo_ttl_ms, value)
        :error -> Application.delete_env(:sanctum, :caller_memo_ttl_ms)
      end
    end)

    Application.put_env(:sanctum, :caller_memo_ttl_ms, 2_000)
    :ok
  end

  test "the deadline timer re-reads a renewal committed before the next freshness check", %{
    source: source
  } do
    Cyfr.Test.Settings.put("frame_credential_deadline_s", 2)
    frame = canvas_frame!(source)
    assert {:ok, %{deadline: old_deadline}} = TinctureAuth.verify_frame_credential(frame.bearer)
    stream = open_stream(source, frame.frame_id, frame.bearer)
    assert Process.alive?(stream.pid)

    try do
      Cyfr.Test.Settings.put("frame_credential_deadline_s", 3_600)
      assert {:ok, %{credential: renewed}} = TinctureAuth.renew_frame(source, frame.id)
      assert {:ok, _} = TinctureAuth.verify_frame_credential(renewed)
      wait_until(fn -> DateTime.compare(DateTime.utc_now(), old_deadline) == :gt end, 5_000)
      assert {:ok, _} = TinctureAuth.verify_frame_credential(frame.bearer, held: true)

      still_held = Task.yield(stream, 150) == nil

      assert still_held,
             "the stream ended at the prior deadline even though its credential was renewed"

      {:ok, _} = TinctureAuth.revoke_frame(source, frame.id)
      assert Task.await(stream, @stream_ms).status == 200
    after
      TinctureAuth.revoke_frame(source, frame.id)
      if Process.alive?(stream.pid), do: Task.shutdown(stream, :brutal_kill)
    end
  end

  test "held authority is internal: an expired bearer still cannot open with a held query parameter",
       %{source: source} do
    Cyfr.Test.Settings.put("frame_credential_deadline_s", 2)
    frame = canvas_frame!(source)
    Cyfr.Test.Settings.put("frame_credential_deadline_s", 3_600)
    assert {:ok, %{credential: renewed}} = TinctureAuth.renew_frame(source, frame.id)

    wait_until(
      fn ->
        TinctureAuth.verify_frame_credential(frame.bearer) == {:error, :expired_credential}
      end,
      5_000
    )

    assert {:ok, _} = TinctureAuth.verify_frame_credential(renewed)
    assert {:ok, _} = TinctureAuth.verify_frame_credential(frame.bearer, held: true)
    assert request_stream(frame.frame_id, frame.bearer, "?held=true").status == 401

    assert {:ok, _} = TinctureAuth.suspend_frame(source, frame.id)
    assert {:error, :suspended} = TinctureAuth.verify_frame_credential(frame.bearer, held: true)
    assert {:ok, _} = TinctureAuth.resume_frame(source, frame.id)
    assert {:ok, _} = TinctureAuth.revoke_frame(source, frame.id)
    assert {:error, :revoked} = TinctureAuth.verify_frame_credential(frame.bearer, held: true)
  end

  test "renewal cannot move a stream past the bound set at its open", %{source: source} do
    now = DateTime.utc_now()
    parent = self()
    ctx = %{source | frame: %{id: "frc_bound"}, validated_at: DateTime.add(now, -10, :second)}
    bound = DateTime.add(now, 700, :millisecond)

    grant = %Prima.StreamGrant{
      topic: :mcp_servers,
      projection: ["kind"],
      subject: nil,
      deadline: DateTime.add(now, 200, :millisecond),
      bound: bound,
      grant_id: "sgr_bound"
    }

    task =
      Task.async(fn ->
        CyfrWeb.SSE.deliver(build_conn(), ctx, grant,
          name: "mcp_servers.changes",
          revalidate_every: 20,
          revalidate: fn ->
            send(parent, :bound_revalidated)

            {:ok,
             %{
               ctx
               | credential_deadline: DateTime.add(DateTime.utc_now(), 60, :second),
                 validated_at: DateTime.utc_now()
             }}
          end
        )
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    assert_receive :bound_revalidated, 1_000
    conn = Task.await(task, 2_000)
    assert conn.status == 200
    assert DateTime.compare(DateTime.utc_now(), bound) != :lt
  end

  defp request_stream(frame_id, bearer, query \\ "") do
    body = TinctureWire.request(:stream_open, %{stream: "mcp_servers.changes", subject: nil})

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("origin", "null")
    |> put_req_header("authorization", TinctureWire.bearer(bearer))
    |> post(Prima.CanvasWire.stream_path(frame_id) <> query, Jason.encode!(body))
  end

  defp open_stream(source, frame_id, bearer) do
    task = Task.async(fn -> request_stream(frame_id, bearer) end)

    on_exit(fn ->
      monitor = Process.monitor(task.pid)
      if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)

      receive do
        {:DOWN, ^monitor, :process, _, _} -> :ok
      after
        @stream_ms -> raise "the stream did not stop"
      end
    end)

    wait_for_open_or_finish(source, task)
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
    name = "held-deadline-#{System.unique_integer([:positive])}"

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
