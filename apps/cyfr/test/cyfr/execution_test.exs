# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ExecutionTest do
  @moduledoc """
  CYFR runs a component only on a worker service reached through its
  endpoint: with none configured, or none that answers as its configured
  id, execution is unavailable and a run is refused before it is admitted;
  a configured worker service that answers its id makes it available, and
  one that answers as another service is skipped. The test boot's worker
  services are endpoints, and its Opus service holds the key CYFR derives
  for its id.
  """
  use ExUnit.Case, async: false

  alias Cyfr.Execution.{Dispatch, Keys}
  alias Cyfr.Test.{AuthorityFixtures, ScriptedWorker, ScriptedWorkerListener}
  alias Cyfr.WorkerAuth

  # A worker service that answers as a service other than the one it is
  # configured as.
  defmodule Elsewhere do
    @moduledoc false
    @behaviour Cyfr.WorkerAPI

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

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Arca.Cache.init()

    previous = Application.get_env(:cyfr, :workers)
    on_exit(fn -> Application.put_env(:cyfr, :workers, previous) end)

    {:ok, ctx: Sanctum.TestContext.local(), configured: previous}
  end

  defp run(ctx) do
    Cyfr.Execution.run_child(AuthorityFixtures.root!(), "reagent:local.off-graph:1.0.0", nil, %{},
      ctx: ctx
    )
  end

  test "with no worker service configured, execution is unavailable and a run is refused", %{
    ctx: ctx
  } do
    Application.put_env(:cyfr, :workers, [])

    refute Cyfr.Execution.available?()
    assert {:error, :execution_unavailable} = run(ctx)
    assert Arca.Repo.all(Arca.Schemas.Execution) == []
    assert Cyfr.Execution.events_since("exec_1", {0, 0}, ctx.athanor_id) == []
  end

  test "with no worker service, a root run is refused before any consent is resolved or row written",
       %{ctx: ctx} do
    Application.put_env(:cyfr, :workers, [])

    assert {:error, :execution_unavailable} =
             Cyfr.Execution.run_root(ctx, :default, "reagent:local.off-graph:1.0.0", %{})

    assert Arca.Repo.all(Arca.Schemas.Execution) == []
    assert Arca.Repo.all(Arca.Schemas.PolicyLog) == []
  end

  test "a configured worker service that does not answer leaves execution unavailable", %{
    ctx: ctx
  } do
    Application.put_env(:cyfr, :workers, ScriptedWorker.workers("reagent:local.ta", []))

    assert [
             %{
               id: "wrk_scripted",
               url: "http://127.0.0.1:" <> _,
               components: ["reagent:local.ta"]
             }
           ] =
             Application.get_env(:cyfr, :workers)

    refute Cyfr.Execution.available?()
    assert {:error, :execution_unavailable} = run(ctx)
  end

  test "a configured worker service that answers makes execution available" do
    Application.put_env(:cyfr, :workers, ScriptedWorker.workers("reagent:local.ta", []))
    start_supervised!({ScriptedWorker, ref: "reagent:local.ta", script: []})

    assert Cyfr.Execution.available?()

    assert {:ok, %{service: "wrk_scripted", boot: boot, endpoint: endpoint}} =
             Dispatch.worker("reagent:local.ta")

    assert {:ok, %{boot: ^boot}} = ScriptedWorker.status()
    assert endpoint == %{ScriptedWorker.endpoint() | components: ["reagent:local.ta"]}
  end

  test "a worker service that answers as another service is skipped" do
    listener =
      start_supervised!({ScriptedWorkerListener, worker: Elsewhere, service: "wrk_imposter"})

    imposter = ScriptedWorkerListener.endpoint(listener, "wrk_imposter")

    Application.put_env(:cyfr, :workers, [imposter])
    refute Cyfr.Execution.available?()
    assert {:error, :execution_unavailable} = Dispatch.worker()

    start_supervised!({ScriptedWorker, ref: "reagent:local.ta", script: []})

    Application.put_env(:cyfr, :workers, [
      imposter | ScriptedWorker.workers("reagent:local.ta", [])
    ])

    assert {:ok, %{service: "wrk_scripted", endpoint: %{id: "wrk_scripted"}}} =
             Dispatch.worker("reagent:local.ta")

    assert {:error, :execution_unavailable} = Dispatch.worker("reagent:local.other")
  end

  test "the test boot's worker services are endpoints, and Opus holds the key CYFR derives for its id",
       %{configured: configured} do
    assert [%{id: "wrk_local", url: url, components: nil}] = configured
    assert url == Cyfr.Test.OpusService.url()
    assert {:ok, %{service: "wrk_local"}} = Dispatch.worker()
    assert Application.get_env(:opus, :service_id) == "wrk_local"
    assert Application.get_env(:cyfr, :worker_key) == Keys.root()

    {:ok, worker_key} = WorkerAuth.worker_key(Keys.root(), "wrk_local")
    assert Application.get_env(:opus, :service_key) == Base.encode16(worker_key, case: :lower)
  end
end
