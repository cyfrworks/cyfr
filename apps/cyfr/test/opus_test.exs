# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule OpusTest do
  @moduledoc """
  CYFR runs a component only on a worker service reached through its
  endpoint: with none configured, or none that answers as its configured
  id, execution is unavailable and a run is refused before it is admitted;
  a configured worker service that answers its id makes it available, and
  one that answers as another service is skipped. The test boot's worker
  services are endpoints, and its runtime holds the key CYFR derives
  for its id.
  """
  use ExUnit.Case, async: false

  alias Opus.{Dispatch, Keys}
  alias Cyfr.Test.{ScriptedWorker, ScriptedWorkerListener}
  alias Prima.Test.AuthorityFixtures
  alias Prima.WorkerAuth

  # A worker service that answers as a service other than the one it is
  # configured as.
  defmodule Elsewhere do
    @moduledoc false
    @behaviour Prima.WorkerAPI

    @impl true
    def start(_token, _input, _sealed_keys), do: {:error, :malformed}

    @impl true
    def kill(_execution_id), do: {:error, :not_found}

    @impl true
    def status do
      {:ok,
       %{
         service: "wrk_elsewhere",
         boot: "boot_elsewhere",
         runners: %{fresh: 0, idle: 0, busy: 0},
         attempts: []
       }}
    end
  end

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Arca.Cache.init()

    previous = Application.get_env(:cyfr, :locus_runtime_workers)
    on_exit(fn -> Application.put_env(:cyfr, :locus_runtime_workers, previous) end)

    Sanctum.TestContext.ready!(Sanctum.TestContext.athanor_id())
    {:ok, ctx: Sanctum.TestContext.local(), configured: previous}
  end

  defp run(ctx) do
    Opus.run_child(AuthorityFixtures.root!(), "reagent:local.off-graph:1.0.0", nil, %{}, ctx: ctx)
  end

  test "with no worker service configured, execution is unavailable and a run is refused", %{
    ctx: ctx
  } do
    Application.put_env(:cyfr, :locus_runtime_workers, [])

    refute Opus.available?()
    assert {:error, :execution_unavailable} = run(ctx)
    assert Arca.Repo.all(Arca.Schemas.Execution) == []
    assert Opus.events_since("exec_1", {0, 0}, ctx.athanor_id) == []
  end

  test "with no worker service, a root run is refused before any consent is resolved or row written",
       %{ctx: ctx} do
    Application.put_env(:cyfr, :locus_runtime_workers, [])

    assert {:error, :execution_unavailable} =
             Opus.run_root(ctx, :default, "reagent:local.off-graph:1.0.0", %{}, [])

    assert Arca.Repo.all(Arca.Schemas.Execution) == []
    assert Arca.Repo.all(Arca.Schemas.PolicyLog) == []
  end

  test "a key narrowed to named tools starts no other, before anything else about the run is asked",
       %{ctx: ctx} do
    Application.put_env(:cyfr, :locus_runtime_workers, [])
    issuer = Sanctum.TestContext.issuer!(ctx)
    Sanctum.TestContext.ready!(issuer.athanor_id)

    key_ctx = fn name, attrs ->
      {:ok, %{api_key: raw}} =
        Sanctum.TestContext.create_key(issuer, Map.put(attrs, :name, name))

      {:ok, key_ctx} = Sanctum.Caller.establish({:api_key, raw}, client_ip: "127.0.0.1")
      key_ctx
    end

    narrowed = key_ctx.("one-tool", %{tools: ["r:local.named"]})
    open = key_ctx.("any-tool", %{})

    for ref <- ["reagent:local.off-graph:1.0.0", "catalyst:local.named:1.0.0", "not a ref"] do
      assert {:error, :key_tool_not_named} = Opus.run_root(narrowed, :default, ref, %{}, [])
      assert {:error, :key_tool_not_named} = Opus.start_root(narrowed, :default, ref, %{}, [])
    end

    # The named tool at any version, and any tool under a key with no
    # tools or under no key, passes the key and meets the next question.
    for {run_ctx, ref} <- [
          {narrowed, "reagent:local.named:1.0.0"},
          {narrowed, "reagent:local.named:2.1.0"},
          {open, "reagent:local.off-graph:1.0.0"},
          {issuer, "reagent:local.off-graph:1.0.0"}
        ] do
      assert {:error, :execution_unavailable} = Opus.run_root(run_ctx, :default, ref, %{}, [])
    end

    assert Arca.Repo.all(Arca.Schemas.Execution) == []

    assert %Prima.Refusal{
             class: :forbidden,
             reason: :key_tool_not_named,
             message:
               "This API key may run only the tools named when it was made, and this is not one of them."
           } = Prima.Refusal.classify(:key_tool_not_named)
  end

  test "a key revoked after its context was made starts nothing", %{ctx: ctx} do
    Application.put_env(:cyfr, :locus_runtime_workers, [])
    issuer = Sanctum.TestContext.issuer!(ctx)

    {:ok, %{api_key: raw}} =
      Sanctum.TestContext.create_key(issuer, %{name: "gone", tools: ["r:local.named"]})

    {:ok, key_ctx} = Sanctum.Caller.establish({:api_key, raw}, client_ip: "127.0.0.1")
    :ok = Sanctum.ApiKey.revoke(issuer, "gone")

    assert {:error, :invalid_api_key} =
             Opus.run_root(key_ctx, :default, "reagent:local.named:1.0.0", %{}, [])
  end

  test "a configured worker service that does not answer leaves execution unavailable", %{
    ctx: ctx
  } do
    Application.put_env(
      :cyfr,
      :locus_runtime_workers,
      ScriptedWorker.workers("reagent:local.ta", [])
    )

    assert [
             %{
               id: "wrk_scripted",
               url: "http://127.0.0.1:" <> _,
               components: ["reagent:local.ta"]
             }
           ] =
             Application.get_env(:cyfr, :locus_runtime_workers)

    refute Opus.available?()
    assert {:error, :execution_unavailable} = run(ctx)
  end

  test "a configured worker service that answers makes execution available" do
    Application.put_env(
      :cyfr,
      :locus_runtime_workers,
      ScriptedWorker.workers("reagent:local.ta", [])
    )

    start_supervised!({ScriptedWorker, ref: "reagent:local.ta", script: []})

    assert Opus.available?()

    assert {:ok, %{service: "wrk_scripted", boot: boot, endpoint: endpoint}} =
             Dispatch.worker("reagent:local.ta")

    assert {:ok, %{boot: ^boot}} = ScriptedWorker.status()
    assert endpoint == %{ScriptedWorker.endpoint() | components: ["reagent:local.ta"]}
  end

  test "a worker service that answers as another service is skipped" do
    listener =
      start_supervised!({ScriptedWorkerListener, worker: Elsewhere, service: "wrk_imposter"})

    imposter = ScriptedWorkerListener.endpoint(listener, "wrk_imposter")

    Application.put_env(:cyfr, :locus_runtime_workers, [imposter])
    refute Opus.available?()
    assert {:error, :execution_unavailable} = Dispatch.worker()

    start_supervised!({ScriptedWorker, ref: "reagent:local.ta", script: []})

    Application.put_env(:cyfr, :locus_runtime_workers, [
      imposter | ScriptedWorker.workers("reagent:local.ta", [])
    ])

    assert {:ok, %{service: "wrk_scripted", endpoint: %{id: "wrk_scripted"}}} =
             Dispatch.worker("reagent:local.ta")

    assert {:error, :execution_unavailable} = Dispatch.worker("reagent:local.other")
  end

  test "the test boot's worker services are endpoints, and the runtime holds the key CYFR derives for its id",
       %{configured: configured} do
    assert [%{id: "wrk_local", url: url, components: nil}] = configured
    assert url == Cyfr.Test.RuntimeService.url()
    assert {:ok, %{service: "wrk_local"}} = Dispatch.worker()
    assert Application.get_env(:locus, :runtime)[:service_id] == "wrk_local"
    assert Application.get_env(:cyfr, :locus_runtime_root) == Keys.root()

    {:ok, worker_key} = WorkerAuth.worker_key(Keys.root(), "wrk_local")

    assert Application.get_env(:locus, :runtime)[:service_key] ==
             Base.encode16(worker_key, case: :lower)
  end
end
