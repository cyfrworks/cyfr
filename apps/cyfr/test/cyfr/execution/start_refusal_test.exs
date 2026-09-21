# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.StartRefusalTest do
  @moduledoc """
  A worker service whose keeper starts no runner refuses a start `503`
  `unavailable` with its sentence, which names what the deployment lacks
  (`writable-cgroups=true`): it started nothing, so dispatch closes the run
  failed with that sentence and reconciles nothing. A start whose answer is
  lost may have started the run, so dispatch reconciles against the
  attempt: with no runner attached it closes the run failed as a start the
  worker did not answer. The row and the caller's result tell the two
  apart. (A lost start whose runner did attach keeps the run:
  `Cyfr.Test.ScriptedWorkerTest` and `Cyfr.TwoWorkersTest`.)

  The worker service is a stub listener that answers `status` as a
  refusing Opus service does and `start` as the case needs; the sentence
  is the one Opus's keeper client gives (`Opus.Keeper.Spawn.refusal/1`),
  which Opus's own suite shows its listener answering a start with
  (`Opus.WorkerServicePoolTest`).
  """

  use ExUnit.Case, async: false

  alias Cyfr.Authority
  alias Cyfr.Authority.Blob
  alias Cyfr.WorkerWire

  @compile {:no_warn_undefined, [Opus.Keeper.Spawn]}

  @service "wrk_refusing"
  @math_wasm_path Path.expand("../../support/test_wasm/math.wasm", __DIR__)
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

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path =
      Path.join(System.tmp_dir!(), "start_refusal_#{System.unique_integer([:positive])}")

    previous =
      Map.new([arca: :base_path, cyfr: :workers], fn {app, key} ->
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

    ctx = Sanctum.TestContext.local()

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm_path), %{
        name: "start-refusal",
        version: "0.1.0",
        type: "reagent",
        description: "A reagent no worker service starts"
      })

    {:ok, ctx: ctx, refusal: Opus.Keeper.Spawn.refusal(:memory_unavailable)}
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
    Application.put_env(:cyfr, :workers, [endpoint])
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

  defp run(ctx) do
    id = Cyfr.UUID7.execution_id()

    result =
      Cyfr.Execution.Dispatch.run(ctx, @ref, %{"a" => 1, "b" => 2},
        type: :reagent,
        authority: authority(),
        execution_id: id
      )

    {result, Arca.Repo.get!(Arca.Execution, id), id}
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
