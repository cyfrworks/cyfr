# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.StartRefusalTest do
  @moduledoc """
  A worker service whose keeper starts no runner refuses a start `503`
  `unavailable` with its sentence, which names what the deployment lacks
  (`writable-cgroups=true`): it started nothing, so dispatch closes the run
  failed with that sentence and reconciles nothing. A start whose answer is
  lost may have started the run, so dispatch reconciles against the
  attempt: with no runner attached it closes the run failed as a start the
  worker did not answer. The row and the caller's result tell the two
  apart. A start refused for room, `503` `no_memory` with what holds the
  memory, closes the run failed with that one sentence alone
  (`Prima.LocusPool.refusal_sentence/1`). (A lost start whose runner did attach keeps the run:
  `Cyfr.Test.ScriptedWorkerTest` and `Cyfr.TwoWorkersTest`.)

  The worker service is a stub listener that answers `status` as a
  refusing runtime does and `start` as the case needs; the sentence
  is the one the runtime's keeper gives (`Locus.Runtime.Keeper.Channel.refusal/1`),
  which the runtime's own suite shows its listener answering a start with
  (`Locus.Runtime.WorkerServicePoolTest`).
  """

  use ExUnit.Case, async: false

  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Prima.WorkerWire

  @compile {:no_warn_undefined, [Locus.Runtime.Keeper.Channel]}

  @service "wrk_refusing"
  @node "reagent:local.start-refusal"
  @ref "reagent:local.start-refusal:0.1.0"

  defmodule Stub do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: Map.new(opts)

    @impl true
    def call(conn, opts) do
      {:ok, _body, conn} = read_body(conn)
      send(opts.test, {:request, conn.request_path})

      case {conn.request_path, opts} do
        {"/worker/v1/status", _} -> json(conn, 200, WorkerWire.ok(opts.status))
        {"/worker/v1/start", %{start: :lost}} -> send_resp(conn, 200, "")
        {"/worker/v1/start", %{start: {status, answer}}} -> json(conn, status, answer)
        {"/worker/v1/kill", _} -> json(conn, 200, WorkerWire.error(:not_found))
      end
    end

    defp json(conn, status, answer) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(answer))
    end
  end

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_path =
      Path.join(System.tmp_dir!(), "start_refusal_#{System.unique_integer([:positive])}")

    previous =
      Map.new([arca: :base_path, cyfr: :locus_runtime_workers], fn {app, key} ->
        {{app, key}, Application.get_env(app, key)}
      end)

    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {{app, key}, value} <- previous do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end
    end)

    ctx = Sanctum.TestContext.local(:api)

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
        name: "start-refusal",
        version: "0.1.0",
        type: "reagent",
        description: "A reagent no worker service starts"
      })

    {:ok, ctx: ctx, refusal: Locus.Runtime.Keeper.Channel.refusal(:memory_unavailable)}
  end

  defp serve!(start, refusal) do
    status = %{
      service: @service,
      boot: "boot_refusing",
      runners: %{fresh: 0, idle: 0, busy: 0, tainted: 0},
      attempts: [],
      memory_bytes: 402_653_184,
      refusal: refusal
    }

    pid =
      start_supervised!(
        {Bandit,
         plug: {Stub, test: self(), start: start, status: status},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    endpoint = %{id: @service, url: "http://127.0.0.1:#{port}", components: nil}
    Application.put_env(:cyfr, :locus_runtime_workers, [endpoint])
    endpoint
  end

  defp authority do
    {:ok, blob} =
      Blob.parse(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          @node => %{
            "limits" => %{
              "timeout" => "1m",
              "max_memory_bytes" => 67_108_864,
              "max_request_size" => 1_048_576,
              "max_response_size" => 5_242_880,
              "rate_limit" => %{"requests" => 100, "window" => "1m"},
              "max_concurrent_tasks" => 1,
              "batch_timeout" => "1m"
            },
            "edges" => %{"@ingress" => %{}}
          }
        }
      })

    profile = %{
      profile_id: "prof-start-refusal",
      consent_id: "consent-start-refusal",
      source_ref: @node,
      kind: :owner,
      invoke_mode: :open_inert,
      activation: %{@node => "sha256:act-start-refusal"}
    }

    {:ok, authority} =
      Authority.root(profile, blob, ceiling: Sanctum.Policy.Ceiling.platform_ceiling())

    authority
  end

  defp run(ctx, opts \\ []) do
    id = Prima.UUID7.execution_id()

    result =
      Opus.Dispatch.run(
        ctx,
        @ref,
        %{"a" => 1, "b" => 2},
        [type: "reagent", authority: authority(), execution_id: id] ++ opts
      )

    {result, Arca.Repo.get!(Arca.Schemas.Execution, id), id}
  end

  @tag :capture_log
  test "a start refused 503 closes the run failed with the worker's sentence, reconciling nothing",
       %{ctx: ctx, refusal: refusal} do
    assert refusal.message =~ "writable-cgroups=true"
    serve!({503, WorkerWire.error(:unavailable, %{"message" => refusal.message})}, refusal)

    {result, row, id} = run(ctx)

    sentence = "the execution worker refused the start: " <> refusal.message
    assert result == {:error, sentence}
    assert row.status == "failed"
    assert row.error_message == sentence

    # One start, and nothing claimed: no runner was given the run.
    assert_received {:request, "/worker/v1/start"}
    refute_received {:request, "/worker/v1/start"}

    assert %{claimed_by: nil, state: state} =
             Arca.ExecutionAttempts.current(Sanctum.Context.actor(ctx), id)

    refute state == "running"
  end

  @tag :capture_log
  test "a start refused for room closes the run failed with the one sentence of what holds it, and nothing else",
       %{ctx: ctx, refusal: refusal} do
    # A runner's place is no one's until its work is assigned, so what the
    # keeper says holds the memory names nobody's work as the person's own:
    # all of it is one sum, and the sentence says it is work under way.
    held = %{
      "need" => 171_966_464,
      "free" => 8_388_608,
      "mine" => [],
      "others_bytes" => 2_147_483_648
    }

    serve!({503, WorkerWire.error(:no_memory, %{"held" => held})}, refusal)

    {result, row, id} = run(ctx)

    sentence =
      "This CYFR has not enough memory free. Work under way uses 2.0 GB. Wait, or try again later."

    assert result == {:error, sentence}
    assert row.status == "failed"
    assert row.error_message == sentence

    assert_received {:request, "/worker/v1/start"}
    refute_received {:request, "/worker/v1/start"}
    assert %{claimed_by: nil} = Arca.ExecutionAttempts.current(Sanctum.Context.actor(ctx), id)
  end

  # The person's record of who uses what on the refusing worker's
  # machine: a program of theirs named `claude`, 600 MiB.
  defp recorded!(ctx) do
    {:ok, claim} = Arca.JobClaims.claim("memory", Arca.JobClaims.cell_key(), "boot_test", 60_000)

    report = %{
      boot: String.duplicate("c", 32),
      budget: 8 * 1024 * 1_048_576,
      work: 4 * 1024 * 1_048_576,
      floor: 164 * 1_048_576,
      used: 2048 * 1_048_576,
      counters: [
        %{
          rev: 1,
          day: Date.utc_today(),
          athanor: ctx.athanor_id,
          kind: "program",
          subject: "srv_claude",
          bytes: 600 * 1_048_576,
          mib_ms: 0,
          measured_ms: 0,
          peak_bytes: 0,
          cap: 0,
          machine: 0,
          either: 0
        }
      ],
      next: nil
    }

    names = %{{ctx.athanor_id, "srv_claude"} => %{name: "claude", shown: "program"}}
    {:ok, _} = Arca.MemoryRecord.store(claim, :none, @service, 0, report, names, 90)
    :ok
  end

  @room %{
    "need" => 171_966_464,
    "free" => 8_388_608,
    "mine" => [],
    "others_bytes" => 2_147_483_648
  }

  @tag :capture_log
  test "a person's run refused for room names their own holders from the record",
       %{ctx: ctx, refusal: refusal} do
    recorded!(ctx)
    serve!({503, WorkerWire.error(:no_memory, %{"held" => @room})}, refusal)

    {result, row, _id} = run(ctx)

    sentence =
      "This CYFR has not enough memory free. Of yours, claude uses 600.0 MB. Others use " <>
        "1.4 GB. Stop one on the Programs page, or wait."

    assert result == {:error, sentence}
    assert row.error_message == sentence
  end

  @tag :capture_log
  test "a run a component asked for in its chain is told no name, size or sum",
       %{ctx: ctx, refusal: refusal} do
    recorded!(ctx)
    serve!({503, WorkerWire.error(:no_memory, %{"held" => @room})}, refusal)

    # The parent is a component's run, its attempt on a worker service.
    parent = Cyfr.Test.AttemptFixtures.attached!(ctx: ctx, attach: false)

    assert %{service_id: "wrk_fixture"} =
             Arca.ExecutionAttempts.current(Sanctum.Context.actor(ctx), parent.execution_id)

    {result, row, _id} =
      run(ctx,
        parent_execution_id: parent.execution_id,
        root_execution_id: parent.execution_id
      )

    sentence = "This CYFR has not enough memory free. Stop one on the Programs page, or wait."
    assert result == {:error, sentence}
    assert row.error_message == sentence
  end

  @tag :capture_log
  test "a run a tincture asked for is told no name, size or sum", %{ctx: ctx, refusal: refusal} do
    recorded!(ctx)
    serve!({503, WorkerWire.error(:no_memory, %{"held" => @room})}, refusal)

    {result, row, _id} = run(ctx, caller: {:tincture, %{publisher: "local", name: "page"}})

    sentence = "This CYFR has not enough memory free. Stop one on the Programs page, or wait."
    assert result == {:error, sentence}
    assert row.error_message == sentence
    refute row.error_message =~ "claude"
    refute row.error_message =~ "MB"
  end

  @tag :capture_log
  test "a 503 for room whose held does not read is a lost start, not a refusal",
       %{ctx: ctx, refusal: refusal} do
    serve!({503, WorkerWire.error(:no_memory, %{"held" => %{"need" => 1}})}, refusal)

    {result, row, _id} = run(ctx)

    assert result == {:error, "the execution worker did not answer the start"}
    assert row.error_message == "the execution worker did not answer the start"
  end

  @tag :capture_log
  test "a start whose answer is lost is reconciled, and ends as a start the worker did not answer",
       %{ctx: ctx, refusal: refusal} do
    serve!(:lost, refusal)

    {result, row, id} = run(ctx)

    sentence = "the execution worker did not answer the start"
    assert result == {:error, sentence}
    assert row.status == "failed"
    assert row.error_message == sentence
    refute row.error_message =~ "refused"

    assert_received {:request, "/worker/v1/start"}
    refute_received {:request, "/worker/v1/start"}
    assert %{claimed_by: nil} = Arca.ExecutionAttempts.current(Sanctum.Context.actor(ctx), id)
  end

  @tag :capture_log
  test "a 503 with no sentence is a lost start, not a refusal", %{ctx: ctx, refusal: refusal} do
    serve!({503, WorkerWire.error(:unavailable)}, refusal)

    {result, row, _id} = run(ctx)

    assert result == {:error, "the execution worker did not answer the start"}
    assert row.error_message == "the execution worker did not answer the start"
  end
end
