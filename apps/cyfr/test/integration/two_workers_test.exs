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
  its terminal event. Cancelling a formula ends its children with it; a
  restarted service holds none of its predecessor's attempts, which lapse
  through their lease; an exit report signed with another service's key,
  naming a boot that no longer runs or a runner that holds nothing lapses
  nothing; and a run cancelled mid-flight releases nothing its masking set
  covers.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait
  import Ecto.Query, only: [from: 2]

  alias Cyfr.Execution.{Attempt, Keys, Sweeper, WorkerClient}
  alias Cyfr.Slots
  alias Cyfr.Test.{AttemptFixtures, AuthorityFixtures, OpusService, ScriptedWorker}
  alias Cyfr.{WorkerAuth, WorkerWire}
  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.{Bootstrap, Commit, Plan, Source}

  @moduletag timeout: 180_000
  @moduletag :capture_log

  @stub_wasm Path.expand("../support/test_wasm/step_stub/step_stub.wasm", __DIR__)
  @math_wasm Path.expand("../support/test_wasm/math.wasm", __DIR__)
  @stub "catalyst:local.step-stub"
  @scripted "reagent:local.two-workers"
  @soul "agent:local.aqua"
  @slots Cyfr.Execution.Slots
  @version "0.1.0"
  @key_field "STUB_API_KEY"
  @stub_text "The stub answers at once."
  @stub_deltas ["The stub ", "answers ", "at ", "once."]
  @lapsed "Execution terminated: runner stopped without cleanup"
  @local OpusService.service()
  @other ScriptedWorker.service()

  # A wire between a client and a listener that loses what it is told to:
  # a Plug served on a loopback port that forwards each request, header and
  # body as they are, to `target` and answers what came back — or, as
  # planned per route, forwards it and answers 502 in place of the answer
  # (lost after the listener acted), or answers 502 without forwarding
  # (lost before it acted). What it did for each route is kept, in order.
  defmodule Wire do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    def start!(target) do
      agent = ExUnit.Callbacks.start_supervised!({Agent, fn -> %{plan: %{}, seen: []} end})

      server =
        ExUnit.Callbacks.start_supervised!(
          {Bandit,
           plug: {__MODULE__, %{agent: agent, target: target}},
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      %{agent: agent, url: "http://127.0.0.1:#{port}"}
    end

    def plan(%{agent: agent}, route, actions) when is_list(actions),
      do: Agent.update(agent, &put_in(&1, [:plan, route], actions))

    def seen(%{agent: agent}, route) do
      for {^route, action} <- Enum.reverse(Agent.get(agent, & &1.seen)), do: action
    end

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, %{agent: agent, target: target}) do
      {:ok, body, conn} = read_body(conn, length: 16_000_000)
      route = conn.request_path

      action =
        Agent.get_and_update(agent, fn state ->
          case get_in(state, [:plan, route]) do
            [action | rest] -> {action, put_in(state, [:plan, route], rest)}
            _ -> {:forward, state}
          end
        end)

      answer =
        if action == :drop do
          :dropped
        else
          headers =
            for {name, value} <- conn.req_headers,
                name in ["x-cyfr-auth", "content-type"],
                do: {name, value}

          Req.post!(target <> route,
            headers: headers,
            body: body,
            retry: false,
            decode_body: false,
            receive_timeout: 60_000
          )
        end

      Agent.update(agent, &%{&1 | seen: [{route, action} | &1.seen]})

      case {action, answer} do
        {:forward, %Req.Response{status: status, body: answer}} ->
          conn |> put_resp_content_type("application/json") |> send_resp(status, answer)

        _lost ->
          send_resp(conn, 502, "")
      end
    end
  end

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    run_dir = Path.join(System.tmp_dir!(), "two_workers_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path, :consent_source, :workers]
    previous = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, Path.join(run_dir, "data"))
    Application.put_env(:cyfr, :consent_source, Source.DB)

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Slots.forgive_unreaped(@slots, ctx.athanor_id)

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
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
      Application.put_env(:cyfr, :seed_path, lay_seed!(Path.join(run_dir, "seed")))
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
               Arca.ExecutionAttempts.current(ctx.athanor_id, opus_id)

      assert opus_boot == OpusService.boot()

      assert %{state: "completed", service_id: @other, boot_id: scripted_boot} =
               Arca.ExecutionAttempts.current(ctx.athanor_id, scripted_id)

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
               Arca.ExecutionAttempts.current(ctx.athanor_id, id)
    end

    test "a host call's lost answer is retried by its class, and a lossy stream stays whole and ordered",
         %{ctx: ctx} do
      secrets = arm!(ctx, key: "k-#{System.unique_integer([:positive])}", token: "t-unused")
      wire = Wire.start!(OpusService.host_url())
      point_opus_at!(wire.url)

      push = WorkerWire.host_route(:push_deltas)
      complete = WorkerWire.host_route(:complete)
      Wire.plan(wire, push, [:drop])
      Wire.plan(wire, complete, [:forward_then_drop])

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
      wait_until(fn -> match?([:drop, :forward | _], Wire.seen(wire, push)) end)
      wait_until(fn -> Wire.seen(wire, complete) == [:forward_then_drop, :forward] end)

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
      client = Opus.HostClient.new(fixture.keys, fixture.runner, fixture.boot, wire.url)
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

      parent_client = Opus.HostClient.new(parent.keys, parent.runner, parent.boot, wire.url)
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
               Arca.ExecutionAttempts.get(ctx.athanor_id, fixture.attempt)
    end

    test "a run cancelled mid-flight releases nothing its masking set covers", %{ctx: ctx} do
      secrets = arm!(ctx, key: "stub answers", token: "at once")
      id = Cyfr.UUID7.execution_id()
      :ok = Cyfr.Execution.subscribe_events(id, ctx)
      await_entry!(id)

      run =
        Task.async(fn ->
          Cyfr.Execution.run_root(ctx, :default, @stub, chat(), execution_id: id)
        end)

      # Held at its entry: the key is unsealed and the token dispensed — both
      # in the masking set — and nothing has been written yet.
      assert_receive {:entered, ^id, guest}, 30_000
      assert {:ok, %{cancelled: true}} = Cyfr.Execution.cancel(ctx, id)
      send(guest, :continue)

      assert {:error, message} = Task.await(run, 60_000)
      refute_unmasked(message, secrets)

      assert %{status: "cancelled"} = row(id)
      refute_unmasked(row(id), secrets)
      refute_unmasked(live_events(), secrets)
      refute_unmasked(event_rows(ctx, id), secrets)
      assert {:error, :not_found} = Arca.ExecutionPayloads.get(ctx, id, "result")

      wait_until(fn -> match?({:ok, %{attempts: []}}, Opus.WorkerService.status()) end, 10_000)
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
      hold_children!(root_id)

      request = %{
        "tool" => "execution",
        "action" => "run",
        "args" => %{"reference" => Probe.probe_ref(), "input" => %{"op" => "echo"}}
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
          assert_receive {:held, component, id}, 30_000
          {id, component}
        end

      assert Slots.status(@slots).child_active == children_before + 3
      assert {:ok, %{cancelled: true}} = Cyfr.Execution.cancel(ctx, root_id)
      assert {:error, _cancelled} = Task.await(root, 30_000)
      assert %{status: "cancelled"} = row(root_id)

      for {id, component} <- held do
        wait_until(fn -> row(id).status == "failed" end, 10_000)
        wait_until(fn -> not Process.alive?(component) end)
        wait_until(fn -> Attempt.whereis(id) == nil end)
      end

      wait_until(fn -> match?({:ok, %{attempts: []}}, Opus.WorkerService.status()) end, 10_000)
      wait_until(fn -> Slots.status(@slots).child_active == children_before end)
    end

    test "a restarted service holds none of its predecessor's attempts, which lapse through their lease",
         %{ctx: ctx} do
      root_id = Cyfr.UUID7.execution_id()
      await_entry!(root_id)

      root =
        Task.async(fn ->
          Cyfr.Execution.run_root(ctx, :default, Probe.probe_ref(), %{"op" => "echo"},
            execution_id: root_id
          )
        end)

      assert_receive {:entered, ^root_id, _guest}, 30_000

      assert %{attempt: attempt, boot_id: old_boot, state: "running"} =
               Arca.ExecutionAttempts.current(ctx.athanor_id, root_id)

      assert old_boot == OpusService.boot()

      new_boot = OpusService.restart!()
      refute new_boot == old_boot
      assert {:ok, %{boot: ^new_boot, attempts: []}} = Opus.WorkerService.status()

      # Nothing reported the runner: the row is still running, on a lease
      # nothing renews. When it lapses, the sweep ends the run.
      assert %{status: "running"} = row(root_id)
      past = DateTime.add(DateTime.utc_now(), -1, :second)
      assert {:ok, ^past} = Arca.ExecutionAttempts.renew(attempt, past)
      :ok = Sweeper.sweep()

      assert {:error, @lapsed} = Task.await(root, 30_000)
      assert %{status: "failed", error_message: @lapsed} = row(root_id)

      assert %{state: "lapsed", outcome: "uncertain", boot_id: ^old_boot} =
               Arca.ExecutionAttempts.get(ctx.athanor_id, attempt)

      wait_until(fn -> Attempt.whereis(root_id) == nil end)
    end
  end

  # ---------------------------------------------------------------------------
  # The estate
  # ---------------------------------------------------------------------------

  defp lay_seed!(seed) do
    unit = Path.join([seed, "components", "catalysts", "local", "step-stub", @version])
    File.mkdir_p!(unit)
    File.cp!(@stub_wasm, Path.join(unit, "catalyst.wasm"))

    manifest = %{
      "name" => "step-stub",
      "type" => "catalyst",
      "version" => @version,
      "publisher" => "local",
      "description" => "A model/chat@1 catalyst the two-service matrix runs",
      "contracts" => [Cyfr.Models.chat_contract()],
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:step-stub",
          "reason" => "to read a key as a model catalyst does",
          "required" => true,
          "fields" => [@key_field]
        }
      },
      "caps" => %{
        "limits" => %{
          "timeout" => "1m",
          "max_memory_bytes" => 67_108_864,
          "max_request_size" => 1_048_576,
          "max_response_size" => 5_242_880,
          "rate_limit" => %{"requests" => 10_000, "window" => "1m"}
        }
      }
    }

    File.write!(Path.join(unit, "cyfr-manifest.json"), Jason.encode!(manifest))
    File.mkdir_p!(Path.join(seed, "aqua"))

    File.write!(Path.join([seed, "aqua", "aqua.md"]), """
    ---
    title: AQUA
    catalyst_ref: #{@stub}
    model: step-stub
    ---

    You answer the person.
    """)

    seed
  end

  # Bind `key` as the stub's vault field, in an entry whose OAuth bundle
  # holds `token`, and dispense `token` to every run of the stub as its
  # guest starts. Answers both, the credentials to look for.
  defp arm!(ctx, key: key, token: token) do
    {:ok, entry} =
      Sanctum.Vault.create(ctx, %{
        name: "#{@stub} key",
        kind: "api_key",
        fields: %{@key_field => key},
        oauth: %{"access_token" => token}
      })

    {:ok, plan} = Plan.plan(ctx, %{ref: @stub})
    decisions = %{ref: @stub, bindings: [%{need: "api_key", entry_id: entry.id}]}
    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, _} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    handler = "two-workers-dispense-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :opus, :runtime, :authority_entered],
        fn _event, _measurements, %{execution_id: id, reference: reference}, _config ->
          if String.starts_with?(reference, @stub <> ":") do
            attempt = AttemptFixtures.current!(ctx.athanor_id, id)

            %{"ok" => ^token} =
              AttemptFixtures.call(attempt, "oauth_token", %{"provider" => "stub"})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    [key, token]
  end

  # A scripted run: a child of a synthetic root, admitted with the charge
  # its authority names, as a chain's child is. Answers the result and the
  # child's id.
  defp scripted_run!(ctx) do
    auth = AuthorityFixtures.root!()
    root_id = "exec_two_workers_root_#{System.unique_integer([:positive])}"

    {:ok, %{attempt: root_attempt}} =
      Arca.Execution.admit(
        %{
          id: root_id,
          reference: "#{AuthorityFixtures.formula_ref()}:1.0.0",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "formula"
        },
        reservation: %{budget_id: auth.budget.id, cap: 2}
      )

    child_id = Cyfr.UUID7.execution_id()

    charge = %{
      id: "call:t:1:c1:g0",
      attempt: root_attempt.attempt,
      generation: 0,
      holder_execution_id: child_id
    }

    result =
      Cyfr.Execution.run_child(auth, "#{@scripted}:1.0.0", nil, %{"messages" => []},
        ctx: ctx,
        execution_id: child_id,
        parent_execution_id: root_id,
        root_execution_id: root_id,
        declared_needs: [],
        retention_class: "chat_step",
        charge: charge,
        guest_fn: :spawn
      )

    {result, child_id}
  end

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

  # Point the Opus service's host calls at `url` for this test, restarting
  # it (a new boot), and back at the host listener when the test ends.
  defp point_opus_at!(url) do
    previous = Application.get_env(:opus, :host_url)
    Application.put_env(:opus, :host_url, url)
    OpusService.restart!()

    on_exit(fn ->
      Application.put_env(:opus, :host_url, previous)
      OpusService.restart!()
    end)
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
  # of `worker_key` for `service` and `boot`, naming `runner` and `attempts`.
  defp report(worker_key, service, boot, runner, attempts) do
    body =
      Jason.encode!(%{
        "op" => "runner_exited",
        "args" => %{"runner" => runner, "attempts" => attempts}
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
  # Holding a guest
  # ---------------------------------------------------------------------------

  # Hold the guest of `id` at its authority's entry until the test sends
  # `:continue` to the process it names.
  defp await_entry!(id) do
    handler = "two-workers-entry-#{System.unique_integer([:positive])}"
    test = self()

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :opus, :runtime, :authority_entered],
        fn _event, _measurements, metadata, _config ->
          if metadata.execution_id == id do
            send(test, {:entered, id, self()})

            receive do
              :continue -> :ok
            after
              60_000 -> :ok
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # Children of `root_id` wait at their guest's entry for `:continue`.
  defp hold_children!(root_id) do
    handler = "two-workers-children-#{System.unique_integer([:positive])}"
    test = self()

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :opus, :runtime, :authority_entered],
        fn _event, _measurements, %{execution_id: id}, _config ->
          case Arca.Repo.get(Arca.Execution, id) do
            %{parent_execution_id: ^root_id} ->
              send(test, {:held, self(), id})

              receive do
                :continue -> :ok
              after
                60_000 -> :ok
              end

            _ ->
              :ok
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # ---------------------------------------------------------------------------
  # Reading what happened
  # ---------------------------------------------------------------------------

  defp chat, do: %{"operation" => "chat", "params" => %{}}

  defp row(id), do: Arca.Repo.get!(Arca.Execution, id)

  defp children_of(parent_id),
    do: from(e in Arca.Execution, where: e.parent_execution_id == ^parent_id)

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
    {:ok, rows} = Arca.ExecutionEvents.since(ctx.athanor_id, id, 0)
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
