# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("opus/support/nested_execution_helper.exs", __DIR__)
Code.require_file("opus/support/formula_host_helper.exs", __DIR__)

defmodule Cyfr.TwoWorkersTest do
  @moduledoc """
  Two worker services, reached over the wire and reaching back over it:
  the test boot's Opus service (`wrk_local`) and the scripted service
  (`wrk_scripted`), each with the key CYFR derives for its id. Independent
  roots run on each, and a request signed with one service's key is
  refused by the other. What the wire may lose is answered by its class:
  a worker request's lost answer is retried once for `kill` and `status`
  and never for `start`, whose reconciliation keeps a run its runner
  attached to; a host call's lost answer is retried as the same batch
  (`push_deltas`), for the outcome already recorded (`complete`), under
  the same child key (`admit_child`), as it was (`renew`), or not at all
  (`record_denial`, which ends uncertain) — and a run whose stream and
  completion crossed a lossy wire keeps every delta once, in order, before
  its terminal event. Cancelling a formula ends its children with it and
  the runner they ran in; a restarted service holds none of its
  predecessor's attempts, which the worker watch lapses when it hears the
  new boot; an exit report signed with another service's key,
  naming a boot that no longer runs or a runner that holds nothing lapses
  nothing; and a run cancelled mid-flight releases nothing its masking set
  covers.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.TwoServices,
    only: [
      arm!: 2,
      hold!: 3,
      lay_seed!: 1,
      plan!: 2,
      release!: 2,
      scripted_run!: 1,
      seen: 1
    ]

  import Cyfr.Test.Wait
  import Ecto.Query, only: [from: 2]

  alias Cyfr.Execution.{Attempt, Keys, WorkerClient}
  alias Cyfr.Slots
  alias Cyfr.Test.{AttemptFixtures, OpusService, ScriptedWorker, TwoServices}
  alias Cyfr.Test.TwoServices.Wire
  alias Cyfr.{WorkerAuth, WorkerWire}
  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.{Bootstrap}

  @moduletag timeout: 180_000
  @moduletag :capture_log

  @math_wasm Path.expand("../support/test_wasm/math.wasm", __DIR__)
  @stub TwoServices.stub()
  @scripted TwoServices.scripted()
  @soul "agent:local.aqua"
  @slots Cyfr.Execution.Slots
  @version TwoServices.version()
  @stub_text "The stub answers at once."
  @stub_deltas ["The stub ", "answers ", "at ", "once."]
  @lapsed "Execution terminated: runner stopped without cleanup"
  @local OpusService.service()
  @other ScriptedWorker.service()

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    run_dir = Path.join(System.tmp_dir!(), "two_workers_#{System.unique_integer([:positive])}")
    keys = [arca: :base_path, arca: :seed_path, cyfr: :workers]
    previous = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
    Application.put_env(:arca, :base_path, Path.join(run_dir, "data"))

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Slots.forgive_unreaped(@slots, ctx.athanor_id)

      for {{app, key}, value} <- previous do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end

      File.rm_rf!(run_dir)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()
    {:ok, ctx: ctx, run_dir: run_dir}
  end

  # ---------------------------------------------------------------------------
  # The step stub on Opus, the scripted reagent on the scripted service
  # ---------------------------------------------------------------------------

  describe "with the step stub on Opus and a scripted reagent" do
    setup %{ctx: ctx, run_dir: run_dir} do
      Application.put_env(:arca, :seed_path, lay_seed!(Path.join(run_dir, "seed")))
      :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
      {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
      {:ok, _} = Compendium.AgentIndex.sync(ctx)
      {:ok, %{minted: minted}} = Bootstrap.run(ctx)
      assert @soul in minted and @stub in minted

      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm), %{
          name: "two-workers",
          version: "1.0.0",
          type: "reagent"
        })

      :ok
    end

    test "independent roots run on each service, under keys of their own", %{ctx: ctx} do
      arm!(ctx, key: "k-#{System.unique_integer([:positive])}", token: "t-unused")
      answer = %{"content" => [%{"type" => "text", "text" => "scripted"}]}
      start_supervised!({ScriptedWorker, ref: @scripted, script: [answer]})
      opus_id = Cyfr.UUID7.execution_id()

      on_opus =
        Task.async(fn ->
          Cyfr.Execution.run_root(ctx, :default, @stub, chat(), execution_id: opus_id)
        end)

      on_scripted = Task.async(fn -> scripted_run!(ctx) end)

      assert {:ok, %{output: %{"data" => %{"content" => [%{"text" => @stub_text}]}}}} =
               Task.await(on_opus, 60_000)

      assert {{:ok, %{status: :completed, output: %{"data" => ^answer}}}, scripted_id} =
               Task.await(on_scripted, 60_000)

      # Each row's attempt names the service and boot it ran on.
      assert %{state: "completed", service_id: @local, boot_id: opus_boot} =
               Arca.ExecutionAttempts.current(Sanctum.Context.actor(ctx), opus_id)

      assert opus_boot == OpusService.boot()

      assert %{state: "completed", service_id: @other, boot_id: scripted_boot} =
               Arca.ExecutionAttempts.current(Sanctum.Context.actor(ctx), scripted_id)

      assert {:ok, %{boot: ^scripted_boot}} = ScriptedWorker.status()
      assert [%{execution_id: ^scripted_id}] = ScriptedWorker.calls()

      # The keys differ, and each listener refuses a request under the
      # other's before reading it.
      {:ok, local_key} = Keys.worker_key(@local)
      {:ok, other_key} = Keys.worker_key(@other)
      refute local_key == other_key

      assert {401, %{"error" => "bad_mac"}} = status_request(OpusService.url(), @local, other_key)

      assert {401, %{"error" => "bad_mac"}} =
               status_request(ScriptedWorker.url(), @other, local_key)

      assert {200, %{"ok" => %{"service" => @local}}} =
               status_request(OpusService.url(), @local, local_key)

      assert {200, %{"ok" => %{"service" => @other}}} =
               status_request(ScriptedWorker.url(), @other, other_key)

      # Each status read over the wire has the contract's shape, a count of
      # tainted runners among it: neither service holds one after its run.
      for endpoint <- [OpusService.endpoint(), ScriptedWorker.endpoint()] do
        assert {:ok, %{runners: %{tainted: 0}} = status} = WorkerClient.status(endpoint)
        assert Cyfr.WorkerAPI.valid_status?(status)
      end
    end

    test "a worker request's lost answer is retried once for kill and status, never for start" do
      start_supervised!({ScriptedWorker, ref: @scripted, script: []})
      wire = Wire.start!(ScriptedWorker.url())
      endpoint = %{id: @other, url: wire.url, components: nil}

      Wire.plan(wire, WorkerWire.worker_route(:status), [:forward_then_drop])
      assert {:ok, %{service: @other}} = WorkerClient.status(endpoint)
      assert Wire.seen(wire, WorkerWire.worker_route(:status)) == [:forward_then_drop, :forward]

      # A kill that acted is asked again, and the worker service saw both.
      Wire.plan(wire, WorkerWire.worker_route(:kill), [:forward_then_drop])
      assert {:error, :not_found} = WorkerClient.kill(endpoint, "exec_absent")
      assert Wire.seen(wire, WorkerWire.worker_route(:kill)) == [:forward_then_drop, :forward]
      assert ScriptedWorker.kills() == ["exec_absent", "exec_absent"]

      # A start is never asked again, whether the worker service acted or not.
      Wire.plan(wire, WorkerWire.worker_route(:start), [:forward_then_drop, :drop])
      assert {:error, :lost} = WorkerClient.start(endpoint, "not-an-assignment", "{}", "sealed")
      assert {:error, :lost} = WorkerClient.start(endpoint, "not-an-assignment", "{}", "sealed")
      assert Wire.seen(wire, WorkerWire.worker_route(:start)) == [:forward_then_drop, :drop]
    end

    test "a start whose answer was lost after the runner attached keeps the run, dispatched once",
         %{ctx: ctx} do
      answer = %{"content" => [%{"type" => "text", "text" => "kept"}]}

      start_supervised!(
        {ScriptedWorker, ref: @scripted, script: [answer], lose_start_answer: true}
      )

      assert {{:ok, %{status: :completed, output: %{"data" => ^answer}}}, id} =
               scripted_run!(ctx)

      assert [%{execution_id: ^id}] = ScriptedWorker.calls()

      assert %{state: "completed", service_id: @other} =
               Arca.ExecutionAttempts.current(Sanctum.Context.actor(ctx), id)
    end

    test "a host call's lost answer is retried by its class, and a lossy stream stays whole and ordered",
         %{ctx: ctx} do
      secrets = arm!(ctx, key: "k-#{System.unique_integer([:positive])}", token: "t-unused")
      # The runners reach the host listener through the suite's wire.
      wire = TwoServices.wire()
      plan!(:push_deltas, [:drop])
      plan!(:complete, [:forward_then_drop])

      id = Cyfr.UUID7.execution_id()
      :ok = Cyfr.Execution.subscribe_events(id, ctx)

      assert {:ok, result} =
               Cyfr.Execution.run_root(ctx, :default, @stub, chat(), execution_id: id)

      assert %{"data" => %{"content" => [%{"text" => @stub_text}]}} = result.output
      refute_unmasked(result, secrets)

      # The first batch went again as the same batch; the completion, which
      # CYFR had recorded, was asked for again and answered as recorded. The
      # wire notes a call once its answer is back, which the waiter's answer
      # can precede.
      wait_until(fn -> match?([:drop, :forward | _], seen(:push_deltas)) end)
      wait_until(fn -> seen(:complete) == [:forward_then_drop, :forward] end)

      live = live_events()
      assert delta_texts(live) == @stub_deltas

      assert Enum.map(live, & &1.type) |> Enum.filter(&(&1 == "execution.completed")) == [
               "execution.completed"
             ]

      assert List.last(live).type == "execution.completed"

      replayed = Cyfr.Execution.Events.since(id, {0, 0}, ctx.athanor_id)
      assert delta_texts(replayed) == @stub_deltas
      assert List.last(replayed).type == "execution.completed"
      assert %{status: "completed"} = row(id)

      # A renewal is asked again as it was; a denial's record is not, and ends
      # uncertain; a child is asked for again under the same key, and is one child.
      fixture = attached!(ctx)

      client =
        Opus.HostClient.new(fixture.keys, fixture.runner, fixture.boot, %{
          member: fixture.member,
          host_url: wire.url
        })

      attempt = fixture.attempt

      Wire.plan(wire, WorkerWire.host_route(:renew), [:forward_then_drop])
      assert {:ok, %{^attempt => {:ok, _until}}} = Opus.HostClient.renew(client, [attempt])
      assert Wire.seen(wire, WorkerWire.host_route(:renew)) == [:forward_then_drop, :forward]

      Wire.plan(wire, WorkerWire.host_route(:record_denial), [:forward_then_drop])

      assert {:error, {:uncertain, _sentence}} =
               Opus.HostClient.record_denial(client, "egress_denied", "refused by the test")

      assert Wire.seen(wire, WorkerWire.host_route(:record_denial)) == [:forward_then_drop]

      {:ok, authority} = Cyfr.Execution.authority_for(ctx, :default, @soul)

      parent =
        Opus.Test.FormulaHost.attached!(
          ctx: ctx,
          authority: authority,
          component_ref: "formula:local.two-workers-parent:0.1.0"
        )

      parent_client =
        Opus.HostClient.new(parent.keys, parent.runner, parent.boot, %{
          member: parent.member,
          host_url: wire.url
        })

      Wire.plan(wire, WorkerWire.host_route(:admit_child), [:forward_then_drop])

      assert {:ok, child} =
               Opus.HostClient.admit_child(
                 parent_client,
                 "#{@stub}:#{@version}",
                 nil,
                 chat(),
                 :spawn
               )

      assert Wire.seen(wire, WorkerWire.host_route(:admit_child)) == [
               :forward_then_drop,
               :forward
             ]

      child_id = child.assignment.execution_id
      assert [%{id: ^child_id}] = Arca.Repo.all(children_of(parent.execution_id))
      assert :ok = Opus.HostClient.release_child(parent_client, child_id)
      assert %{status: "failed"} = row(child_id)
    end

    test "an exit report signed with another key, for a boot that no longer runs or a runner holding nothing lapses nothing",
         %{ctx: ctx} do
      fixture = attached!(ctx)
      {:ok, local_key} = Keys.worker_key(@local)
      {:ok, other_key} = Keys.worker_key(@other)
      running = fn -> match?(%{status: "running"}, row(fixture.execution_id)) end

      # Another service's key, naming this one.
      assert {401, %{"error" => "lost"}} =
               report(other_key, @local, fixture.boot, fixture.runner, [fixture.attempt])

      assert running.()

      # This service's key, a boot that no longer runs.
      assert {200, %{"ok" => true}} =
               report(local_key, @local, "boot_stale", fixture.runner, [fixture.attempt])

      assert running.()

      # The right boot, a runner that holds nothing.
      assert {200, %{"ok" => true}} =
               report(local_key, @local, fixture.boot, "runner_other", [fixture.attempt])

      assert running.()
      assert Process.alive?(fixture.pid)

      # The genuine report.
      assert {200, %{"ok" => true}} =
               report(local_key, @local, fixture.boot, fixture.runner, [fixture.attempt])

      wait_until(fn ->
        match?(%{status: "failed", error_message: @lapsed}, row(fixture.execution_id))
      end)

      wait_until(fn -> not Process.alive?(fixture.pid) end)

      assert %{state: "lapsed", outcome: "uncertain"} =
               Arca.ExecutionAttempts.get(Sanctum.Context.actor(ctx), fixture.attempt)
    end

    test "a run cancelled mid-flight releases nothing its masking set covers", %{ctx: ctx} do
      secrets = arm!(ctx, key: "stub answers", token: "at once")
      id = Cyfr.UUID7.execution_id()
      :ok = Cyfr.Execution.subscribe_events(id, ctx)
      hold!(:push_deltas, id, once: true)

      run =
        Task.async(fn ->
          Cyfr.Execution.run_root(ctx, :default, @stub, chat(), execution_id: id)
        end)

      # Held at its first delta: the key is unsealed and the token dispensed
      # — both in the masking set — and its guest wrote both, but nothing of
      # it has reached the host yet.
      assert_receive {:held, ^id, guest}, 30_000
      assert {:ok, %{cancelled: true}} = Cyfr.Execution.cancel(ctx, id)
      release!(guest, :forward)

      assert {:error, message} = Task.await(run, 60_000)
      refute_unmasked(message, secrets)

      assert %{status: "cancelled"} = row(id)
      refute_unmasked(row(id), secrets)
      refute_unmasked(live_events(), secrets)
      refute_unmasked(event_rows(ctx, id), secrets)

      assert {:error, :not_found} =
               Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), id, "result")

      wait_until(fn -> OpusService.status().attempts == [] end, 10_000)
    end
  end

  # ---------------------------------------------------------------------------
  # The nested probe on Opus
  # ---------------------------------------------------------------------------

  describe "with the nested probe on Opus" do
    setup %{ctx: ctx} do
      :ok = Probe.publish_probe!(ctx)
      {:ok, %{minted: minted}} = Bootstrap.run(ctx)
      assert "formula:local.nested-probe" in minted
      :ok
    end

    test "cancelling a formula over the wire ends its children with it", %{ctx: ctx} do
      children_before = Slots.status(@slots).child_active
      root_id = Cyfr.UUID7.execution_id()

      # Each child asks for a catalog tool, and is held at that call.
      hold!(:tool_call, fn row, _call -> row && row.parent_execution_id == root_id end, [])

      request = %{
        "tool" => "execution",
        "action" => "run",
        "args" => %{"reference" => Probe.probe_ref(), "input" => Probe.held_input()}
      }

      root =
        Task.async(fn ->
          Cyfr.Execution.run_root(
            ctx,
            :default,
            Probe.probe_ref(),
            %{"op" => "spawn_await_all", "requests" => List.duplicate(request, 3)},
            execution_id: root_id
          )
        end)

      held =
        for _ <- 1..3 do
          assert_receive {:held, id, _conn}, 30_000
          id
        end

      runner = runner_of(ctx, root_id)
      assert Enum.all?(held, &(runner_of(ctx, &1) == runner))
      assert Slots.status(@slots).child_active == children_before + 3
      assert {:ok, %{cancelled: true}} = Cyfr.Execution.cancel(ctx, root_id)
      assert {:error, _cancelled} = Task.await(root, 30_000)
      assert %{status: "cancelled"} = row(root_id)

      for id <- held do
        wait_until(fn -> row(id).status == "failed" end, 10_000)
        wait_until(fn -> Attempt.whereis(id) == nil end)
      end

      # The kill ended the runner the formula and its children ran in: the
      # service reported it gone, and holds nothing.
      wait_until(fn -> reported_exit?(runner) end, 10_000, "the runner's exit report")
      wait_until(fn -> OpusService.status().attempts == [] end, 10_000)
      wait_until(fn -> Slots.status(@slots).child_active == children_before end)
    end

    test "a restarted service holds none of its predecessor's attempts, which its watch lapses",
         %{ctx: ctx} do
      # The worker watch is off in the test boot; this case runs one of its
      # own over the Opus service, polling fast.
      start_supervised!(
        {Cyfr.Execution.WorkerWatch,
         workers: [OpusService.endpoint()], poll_ms: 50, misses: 3, name: :two_workers_watch}
      )

      root_id = Cyfr.UUID7.execution_id()
      hold!(:complete, root_id, once: true)

      root =
        Task.async(fn ->
          Cyfr.Execution.run_root(ctx, :default, Probe.probe_ref(), %{"op" => "echo"},
            execution_id: root_id
          )
        end)

      # Its guest ran; its close is held on the wire.
      assert_receive {:held, ^root_id, close}, 30_000

      assert %{attempt: attempt, boot_id: old_boot, state: "running"} =
               Arca.ExecutionAttempts.current(Sanctum.Context.actor(ctx), root_id)

      assert old_boot == OpusService.boot()

      wait_until(
        fn ->
          Cyfr.Execution.WorkerWatch.fresh_boot(OpusService.endpoint(), :two_workers_watch) ==
            {:ok, old_boot}
        end,
        10_000,
        "the watch to hear the old boot"
      )

      new_boot = OpusService.restart!()
      refute new_boot == old_boot
      assert %{boot: ^new_boot, attempts: []} = OpusService.status()

      # The old boot's runner went with it, and its close is lost. Nothing
      # reported the runner: the watch hears a new boot, and lapses the old
      # boot's attempts.
      release!(close, :drop)

      assert {:error, @lapsed} = Task.await(root, 30_000)
      assert %{status: "failed", error_message: @lapsed} = row(root_id)

      assert %{state: "lapsed", outcome: "uncertain", boot_id: ^old_boot} =
               Arca.ExecutionAttempts.get(Sanctum.Context.actor(ctx), attempt)

      wait_until(fn -> Attempt.whereis(root_id) == nil end)
    end
  end

  # ---------------------------------------------------------------------------
  # The Opus service
  # ---------------------------------------------------------------------------

  # An attempt attached on the Opus service's boot, as a runner of its
  # would hold it.
  defp attached!(ctx) do
    AttemptFixtures.attached!(
      ctx: ctx,
      service_id: @local,
      boot_id: OpusService.boot(),
      worker: OpusService.endpoint()
    )
  end

  # ---------------------------------------------------------------------------
  # The wire, by hand
  # ---------------------------------------------------------------------------

  # A status request to the listener at `url`, addressed to `service` and
  # signed with the dispatch key of `worker_key`, as this boot.
  defp status_request(url, service, worker_key) do
    body = Jason.encode!(WorkerWire.request_body(:status, %{}))

    request = %{
      service: service,
      boot: Cyfr.Boot.id(),
      ts: System.system_time(:millisecond),
      nonce: nonce()
    }

    {:ok, header} = WorkerAuth.request_header(WorkerAuth.dispatch_key(worker_key), request, body)
    post(url <> WorkerWire.worker_route(:status), header, body)
  end

  # A runner exit report to the host listener, signed with the dispatch key
  # of `worker_key` for `service` and `boot`, naming this member, `runner`
  # and `attempts`.
  defp report(worker_key, service, boot, runner, attempts) do
    body =
      Jason.encode!(%{
        "op" => "runner_exited",
        "args" => %{
          "member" => Cyfr.Execution.Keys.member(),
          "runner" => runner,
          "attempts" => attempts
        }
      })

    fields = %{service: service, boot: boot, ts: System.system_time(:millisecond), nonce: nonce()}
    {:ok, header} = WorkerAuth.report_header(WorkerAuth.dispatch_key(worker_key), fields, body)
    post(OpusService.host_url() <> WorkerWire.host_route(:runner_exited), header, body)
  end

  defp post(url, header, body) do
    {:ok, %Req.Response{status: status, body: answer}} =
      Req.post(url,
        headers: [{WorkerWire.auth_header(), header}, {"content-type", "application/json"}],
        body: body,
        retry: false,
        decode_body: false
      )

    {status, Jason.decode!(answer)}
  end

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  # ---------------------------------------------------------------------------
  # Reading what happened
  # ---------------------------------------------------------------------------

  defp chat, do: %{"operation" => "chat", "params" => %{}}

  defp row(id), do: Arca.Repo.get!(Arca.Schemas.Execution, id)

  # The runner that claimed the run's attempt, as its host calls present it.
  defp runner_of(ctx, id),
    do: Arca.ExecutionAttempts.current(Sanctum.Context.actor(ctx), id).claimed_by

  # Whether the Opus service reported `runner`'s exit over the wire.
  defp reported_exit?(runner) do
    Enum.any?(
      TwoServices.calls(),
      &match?(%{callback: :runner_exited, args: %{"runner" => ^runner}}, &1)
    )
  end

  defp children_of(parent_id),
    do: from(e in Arca.Schemas.Execution, where: e.parent_execution_id == ^parent_id)

  defp live_events do
    receive do
      {:execution_event, event} -> [event | live_events()]
    after
      200 -> []
    end
  end

  defp delta_texts(events) do
    for %{type: "emit", data: %{"type" => "text.delta", "text" => text}} <- events, do: text
  end

  defp event_rows(ctx, id) do
    {:ok, rows} = Arca.ExecutionEvents.since(Sanctum.Context.actor(ctx), id, 0)
    Enum.map(rows, &%{type: &1.type, data: Arca.ExecutionEvents.data(&1)})
  end

  defp refute_unmasked(term, secrets) do
    text =
      if is_binary(term),
        do: term,
        else: inspect(term, limit: :infinity, printable_limit: :infinity)

    for secret <- secrets do
      refute text =~ secret, "#{inspect(secret)} left the run unmasked in: #{text}"
    end
  end
end
