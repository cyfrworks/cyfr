# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.ScriptedWorkerTest do
  @moduledoc """
  The scripted worker service runs a child's whole lifecycle for real but
  its component. CYFR steps the chain and charges the invoke budget, admits
  the run with its hold barrier and dispatches it over the wire, to the
  endpoint the worker service's listener answers on; the runner attaches
  with its signed assignment under the attempt's keys and claims the row;
  the attempt holds the slot, the charge and the masking set and closes
  the run. Only the answer is scripted. A waiter that dies kills its runner
  through the worker service, a cancel's kill is reported back under the
  worker service's own key, a start whose answer was lost after the runner
  attached is left to that runner, and the listener refuses what its
  service's key did not sign before it reads a body.

  The runners reach CYFR as Opus's do, over HTTP through a real host
  listener (`Crucible.HostListener`), sealed and signed with their
  attempt's keys, so every scripted run crosses that listener's checks.
  The listener refuses a header at another version before it reads the
  body, a body at another version once it is opened, and a call addressed
  to another member at the same generation; a runner exit report naming
  another member lapses nothing.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Prima.Test.Wait

  alias Prima.Authority
  alias Crucible.{Attempt, Dispatch, WorkerClient}
  alias Cyfr.Test.{AttemptFixtures, ScriptedWorker}
  alias Prima.Test.AuthorityFixtures
  alias Prima.{WorkerAuth, WorkerWire}

  @scripted "reagent:local.ta"
  @math_wasm_path Path.expand("../support/test_wasm/math.wasm", __DIR__)

  setup tags do
    Arca.Cache.init()
    # An owner of its own, so what a run leaves behind is ended before the
    # connection goes (`Cyfr.Test.Sandbox`).
    Cyfr.Test.Sandbox.setup!(tags)

    test_path =
      Path.join(System.tmp_dir!(), "scripted_worker_#{System.unique_integer([:positive])}")

    keys = [arca: :base_path, cyfr: :opus_workers]
    previous = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
    Application.put_env(:arca, :base_path, test_path)

    Application.put_env(
      :cyfr,
      :opus_workers,
      ScriptedWorker.workers(@scripted, previous[{:cyfr, :opus_workers}])
    )

    # An athanor of this test's own: the unreaped kills, rate windows and
    # slots its runs are counted under are keyed by athanor and node-global.
    ctx = ScriptedWorker.athanor!(Sanctum.TestContext.local())

    on_exit(fn ->
      Prima.Slots.forgive_unreaped(Crucible.Slots, ctx.athanor_id)
      File.rm_rf!(test_path)
      for {{app, key}, value} <- previous, do: Application.put_env(app, key, value)
    end)

    # The runs stop before the worker routing and the base path they read
    # are put back.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm_path), %{
        name: "ta",
        version: "1.0.0",
        type: "reagent"
      })

    auth = AuthorityFixtures.root!()
    root_id = "exec_scripted_root_#{System.unique_integer([:positive])}"

    {:ok, %{attempt: root_attempt}} =
      Arca.Execution.admit(
        %{
          id: root_id,
          reference: "#{AuthorityFixtures.formula_ref()}:1.0.0",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "formula"
        },
        reservation: %{budget_id: auth.budget.id, cap: 2},
        grant: Cyfr.Test.AttemptFixtures.grant(ctx.athanor_id),
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    child_id = Prima.UUID7.execution_id()

    charge = %{
      id: "call:t:1:c1:g0",
      attempt: root_attempt.attempt,
      generation: 0,
      holder_execution_id: child_id
    }

    {:ok, ctx: ctx, auth: auth, root_id: root_id, child_id: child_id, charge: charge}
  end

  # The hold's admission window has passed.
  defp expire_hold(athanor_id, charge_id) do
    import Ecto.Query, only: [from: 2]
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    {1, _} =
      from(c in Arca.Schemas.BudgetCharge,
        where: c.athanor_id == ^athanor_id and c.id == ^charge_id
      )
      |> Arca.Repo.update_all(set: [admit_by: past])

    :ok
  end

  defp run(%{ctx: ctx, auth: auth, root_id: root_id, child_id: child_id, charge: charge}) do
    Crucible.run_child(auth, "#{@scripted}:1.0.0", nil, %{"messages" => []},
      ctx: ctx,
      execution_id: child_id,
      parent_execution_id: root_id,
      root_execution_id: root_id,
      declared_needs: [],
      retention_class: "chat_step",
      charge: charge,
      guest_fn: :spawn
    )
  end

  defp boot do
    {:ok, %{boot: boot}} = ScriptedWorker.status()
    boot
  end

  test "a scripted child's attempt holds the charge, the claimed row and a child slot for the run",
       fx do
    %{ctx: ctx, auth: auth, child_id: child_id} = fx
    athanor_id = ctx.athanor_id

    start_supervised!(
      {ScriptedWorker,
       ref: @scripted,
       script: [{:probe, self()}, %{"content" => [%{"type" => "text", "text" => "hi"}]}]}
    )

    task = Task.async(fn -> run(fx) end)
    assert_receive {:scripted_probe, runner, ^child_id}, 5_000
    refute runner == task.pid

    assert Sanctum.Authority.budget(auth).in_flight == 1

    assert {:ok, [charge_row]} =
             Arca.BudgetReservations.charges(Prima.Actor.in_athanor(athanor_id), auth.budget.id)

    assert charge_row.admitted_at != nil
    assert charge_row.holder_execution_id == child_id

    # Claimed at attach by the runner, on the worker service and boot it was
    # sent to.
    assert %{
             state: "running",
             claimed_by: "runner" <> _,
             service_id: service_id,
             boot_id: boot_id
           } =
             Arca.ExecutionAttempts.current(Prima.Actor.in_athanor(athanor_id), child_id)

    assert service_id == ScriptedWorker.service()
    assert boot_id == boot()

    # The slot is held for the attempt by its slot holder, a process linked
    # to it.
    status = Prima.Slots.status(Crucible.Slots)
    {:links, linked} = Process.info(Attempt.whereis(child_id), :links)
    held_for = Enum.map(linked, &inspect/1)
    assert status.child_active == 1
    assert Enum.any?(status.holders, &(&1.pid in held_for and &1.class == :child))

    send(runner, :continue)

    assert {:ok, %{status: :completed, output: %{"status" => 200, "data" => data}}} =
             Task.await(task)

    assert data["content"] == [%{"type" => "text", "text" => "hi"}]

    assert Sanctum.Authority.budget(auth).in_flight == 0

    assert {:ok, []} =
             Arca.BudgetReservations.charges(Prima.Actor.in_athanor(athanor_id), auth.budget.id)

    assert %{state: "completed", outcome: "ok"} =
             Arca.ExecutionAttempts.current(Prima.Actor.in_athanor(athanor_id), child_id)

    assert %{status: "completed"} = Arca.Repo.get(Arca.Schemas.Execution, child_id)
    assert Prima.Slots.status(Crucible.Slots).child_active == 0

    assert [%{execution_id: ^child_id, input: %{"messages" => []}, authority: %Authority{}}] =
             ScriptedWorker.calls()
  end

  test "a waiter killed after attach kills its runner, and its attempt lapses with everything given back",
       fx do
    %{ctx: ctx, auth: auth, child_id: child_id} = fx
    athanor_id = ctx.athanor_id

    start_supervised!({ScriptedWorker, ref: @scripted, script: [{:crash, :before_response}]})

    {_pid, ref} = spawn_monitor(fn -> run(fx) end)
    assert_receive {:DOWN, ^ref, :process, _, :killed}, 5_000

    wait_until(fn -> child_id in ScriptedWorker.kills() end)

    wait_until(fn ->
      match?(
        %{state: "lapsed"},
        Arca.ExecutionAttempts.current(Prima.Actor.in_athanor(athanor_id), child_id)
      )
    end)

    assert %{status: "failed"} = Arca.Repo.get(Arca.Schemas.Execution, child_id)

    wait_until(fn -> Sanctum.Authority.budget(auth).in_flight == 0 end)
    wait_until(fn -> Prima.Slots.status(Crucible.Slots).child_active == 0 end)

    assert {:ok, []} =
             Arca.BudgetReservations.charges(Prima.Actor.in_athanor(athanor_id), auth.budget.id)
  end

  test "an exhausted script fails the child and releases everything", fx do
    %{ctx: ctx, auth: auth, child_id: child_id} = fx
    athanor_id = ctx.athanor_id

    start_supervised!({ScriptedWorker, ref: @scripted, script: []})

    assert {:error, "script exhausted"} = run(fx)

    assert %{state: "failed", outcome: "error"} =
             Arca.ExecutionAttempts.current(Prima.Actor.in_athanor(athanor_id), child_id)

    assert Sanctum.Authority.budget(auth).in_flight == 0

    assert {:ok, []} =
             Arca.BudgetReservations.charges(Prima.Actor.in_athanor(athanor_id), auth.budget.id)
  end

  test "an expired hold refuses admission before anything is dispatched", fx do
    %{ctx: ctx, auth: auth, child_id: child_id, charge: charge} = fx
    athanor_id = ctx.athanor_id

    start_supervised!({ScriptedWorker, ref: @scripted, script: [%{"content" => []}]})

    :ok =
      Arca.BudgetReservations.charge(
        Prima.Actor.in_athanor(athanor_id),
        auth.budget.id,
        charge,
        1
      )

    expire_hold(athanor_id, charge.id)

    assert {:error, :hold_expired} = run(fx)
    assert Arca.ExecutionAttempts.current(Prima.Actor.in_athanor(athanor_id), child_id) == nil
    assert Arca.Repo.get(Arca.Schemas.Execution, child_id) == nil
    assert Sanctum.Authority.budget(auth).in_flight == 0
    assert ScriptedWorker.calls() == []
  end

  test "what the runner emits and answers is masked with the key its attempt unsealed", %{
    ctx: ctx
  } do
    secret = "sk-scripted-secret"

    {authority, _entry} =
      AttemptFixtures.vault_authority!(ctx, %{kind: "api_key", fields: %{"KEY" => secret}})

    start_supervised!(
      {ScriptedWorker,
       ref: @scripted,
       script: [
         {:emit, [%{"type" => "text.delta", "text" => "the key is #{secret}"}]},
         %{"echo" => secret}
       ]}
    )

    id = Prima.UUID7.execution_id()

    assert {:ok, %{output: %{"data" => %{"echo" => "[REDACTED]"}}}} =
             Dispatch.run(ctx, "#{@scripted}:1.0.0", %{}, authority: authority, execution_id: id)

    emitted =
      for %{type: "emit", data: data} <- Crucible.events_since(id, {0, 0}, ctx.athanor_id),
          do: data

    assert [%{"type" => "text.delta", "text" => "the key is [REDACTED]"}] = emitted
  end

  test "a cancel kills the runner through the worker service, and its exit report stops the attempt",
       %{ctx: ctx} do
    start_supervised!({ScriptedWorker, ref: @scripted, script: [:hang]})
    id = Prima.UUID7.execution_id()

    task =
      Task.async(fn ->
        Dispatch.run(ctx, "#{@scripted}:1.0.0", %{},
          authority: Authority.zero(),
          execution_id: id
        )
      end)

    wait_until(fn -> match?([_], ScriptedWorker.calls()) end, 5_000)

    assert {:ok, %{cancelled: true}} = Crucible.cancel(ctx, id)
    assert {:error, _cancelled} = Task.await(task)

    assert id in ScriptedWorker.kills()
    assert %{status: "cancelled"} = Arca.Repo.get(Arca.Schemas.Execution, id)
    assert Attempt.whereis(id) == nil
    assert {:ok, %{attempts: []}} = ScriptedWorker.status()
  end

  # A crash of a runner, or a memory kill the worker service made, ends the
  # run and is reported: the work the tenant would be charged an unreaped
  # kill for is over, and the worker service said so. The waiter's kill of
  # its lost run would find the runner ended and be answered `:ok`, as a
  # kill of a live runner is (`c:Prima.WorkerAPI.kill/1`), so a count taken
  # there is a refusal the tenant did not earn.
  test "a runner that ends on its own closes the run and costs the athanor no unreaped kill", %{
    ctx: ctx
  } do
    start_supervised!({ScriptedWorker, ref: @scripted, script: [{:probe, self()}, :hang]})
    id = Prima.UUID7.execution_id()
    athanor_id = ctx.athanor_id
    watch_unreaped!()

    task =
      Task.async(fn ->
        Dispatch.run(ctx, "#{@scripted}:1.0.0", %{},
          authority: Authority.zero(),
          execution_id: id
        )
      end)

    assert_receive {:scripted_probe, runner, ^id}, 10_000

    # The runner ends while it holds the run, its attempt still open.
    Process.exit(runner, :kill)

    assert {:error, "Execution terminated: runner stopped without cleanup"} = Task.await(task)

    # `Dispatch.run/3` answers the caller before the attempt process is
    # done: the attempt closes the row, settles the accounting and then
    # stops. Every assertion below reads state that settles on that path,
    # so the attempt being gone is the barrier they all wait behind —
    # without it this reads the accounting mid-flight and fails wherever
    # the scheduler happened to be.
    wait_until(fn -> Attempt.whereis(id) == nil end, 5_000, "the attempt to stop")
    assert %{status: "failed"} = Arca.Repo.get(Arca.Schemas.Execution, id)

    # The athanor carries no note for it, and nothing was killed, because
    # nothing was left to kill.
    refute_received {:unreaped_kill, ^id, _count}
    assert unreaped_count(athanor_id) == 0
    refute id in ScriptedWorker.kills()

    # And the worker service answers a kill of that run as the contract
    # says: `:ok` for a runner of this boot that already ended, and
    # `:not_found` only where no runner of this boot ever held it.
    assert :ok = WorkerClient.kill(ScriptedWorker.endpoint(), id)
    assert {:error, :not_found} = WorkerClient.kill(ScriptedWorker.endpoint(), "exec_never_ran")
  end

  # The other half of the same distinction: a cancel ends the row and kills
  # what ran it, so the kill the run's end is counted by is still made and
  # still noted, however the runner's exit is reported afterwards.
  test "a cancel of the same run is still counted against the athanor", %{ctx: ctx} do
    start_supervised!({ScriptedWorker, ref: @scripted, script: [{:probe, self()}, :hang]})
    id = Prima.UUID7.execution_id()
    athanor_id = ctx.athanor_id
    watch_unreaped!()

    task =
      Task.async(fn ->
        Dispatch.run(ctx, "#{@scripted}:1.0.0", %{},
          authority: Authority.zero(),
          execution_id: id
        )
      end)

    assert_receive {:scripted_probe, _runner, ^id}, 10_000

    assert {:ok, %{cancelled: true}} = Crucible.cancel(ctx, id)
    assert {:error, _cancelled} = Task.await(task)

    assert id in ScriptedWorker.kills()
    # The athanor is this test's alone, so its count is this run's kill.
    assert_received {:unreaped_kill, ^id, 1}
    assert unreaped_count(athanor_id) == 1
  end

  # Every unreaped kill noted from here on, forwarded to this process.
  defp unreaped_count(athanor_id) do
    Prima.Slots.status(Crucible.Slots).unreaped
    |> Map.get(athanor_id, 0)
  end

  defp watch_unreaped! do
    handler = "scripted-unreaped-#{System.unique_integer([:positive])}"
    test = self()

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :opus, :execution, :unreaped_kill],
        &__MODULE__.forward_unreaped/4,
        test
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc false
  def forward_unreaped(_event, %{unreaped_count: count}, metadata, test),
    do: send(test, {:unreaped_kill, metadata.execution_id, count})

  test "a waiter is killed once the answer it waits for is written, before it returns it", %{
    ctx: ctx
  } do
    start_supervised!(
      {ScriptedWorker, ref: @scripted, script: [{:crash, :after_persist}, %{"done" => true}]}
    )

    id = Prima.UUID7.execution_id()
    test = self()

    {_pid, ref} =
      spawn_monitor(fn ->
        answer =
          Dispatch.run(ctx, "#{@scripted}:1.0.0", %{},
            authority: Authority.zero(),
            execution_id: id
          )

        send(test, {:returned, answer})
      end)

    assert_receive {:DOWN, ^ref, :process, _, :killed}, 5_000
    refute_received {:returned, _}
    assert %{status: "completed"} = Arca.Repo.get(Arca.Schemas.Execution, id)
  end

  test "dispatch reaches the worker service at the endpoint its listener answers on", %{ctx: ctx} do
    start_supervised!({ScriptedWorker, ref: @scripted, script: []})

    assert [%{id: "wrk_scripted", url: url, components: [@scripted]} | _rest] =
             Application.get_env(:cyfr, :opus_workers)

    assert url == ScriptedWorker.url()
    assert "http://127.0.0.1:" <> port = url
    assert String.to_integer(port) > 0

    assert {:ok, %{service: "wrk_scripted", boot: boot, endpoint: %{url: ^url}}} =
             Dispatch.worker("#{@scripted}:1.0.0")

    assert boot == boot()
    assert {:ok, %{boot: ^boot, attempts: []}} = WorkerClient.status(ScriptedWorker.endpoint())

    # A kill of a run no runner runs finds nothing, and is no failure.
    assert {:error, :not_found} = WorkerClient.kill(ScriptedWorker.endpoint(), "exec_none")
    assert :ok = Dispatch.stop("exec_none", ctx.athanor_id)
    assert ScriptedWorker.kills() == ["exec_none"]
  end

  test "a start whose answer was lost after the runner attached is left to that runner, never dispatched again",
       %{ctx: ctx} do
    start_supervised!(
      {ScriptedWorker, ref: @scripted, script: [%{"content" => "once"}], lose_start_answer: true}
    )

    id = Prima.UUID7.execution_id()

    assert {:ok, %{status: :completed, output: %{"data" => %{"content" => "once"}}}} =
             Dispatch.run(ctx, "#{@scripted}:1.0.0", %{},
               authority: Authority.zero(),
               execution_id: id
             )

    assert [%{execution_id: ^id}] = ScriptedWorker.calls()

    assert %{state: "completed", outcome: "ok"} =
             Arca.ExecutionAttempts.current(Sanctum.Context.actor(ctx), id)

    assert Attempt.whereis(id) == nil
  end

  defp post(route, headers, body) do
    {:ok, response} =
      Req.request(
        method: :post,
        url: ScriptedWorker.url() <> route,
        headers: headers,
        body: body,
        retry: false,
        decode_body: false
      )

    {response.status, Jason.decode!(response.body)}
  end

  defp signed(key, body) do
    request = %{
      service: ScriptedWorker.service(),
      boot: "boot_test",
      ts: System.system_time(:millisecond),
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    }

    {:ok, header} = WorkerAuth.request_header(key, request, body)
    [{WorkerWire.auth_header(), header}]
  end

  defp dispatch_key do
    {:ok, worker_key} = Crucible.Keys.opus_key(ScriptedWorker.service())
    WorkerAuth.dispatch_key(worker_key)
  end

  describe "the listener" do
    setup do
      start_supervised!({ScriptedWorker, ref: @scripted, script: []})
      :ok
    end

    test "refuses a request its service's key did not sign before reading the body" do
      body = Jason.encode!(WorkerWire.request_body(:status, %{}))
      route = WorkerWire.worker_route(:status)

      assert {401, %{"error" => "malformed"}} = post(route, [], body)

      other = WorkerAuth.dispatch_key(:crypto.strong_rand_bytes(32))
      assert {401, %{"error" => "bad_mac"}} = post(route, signed(other, body), body)

      assert {200, %{"ok" => %{"service" => "wrk_scripted"}}} =
               post(route, signed(dispatch_key(), body), body)
    end

    test "refuses a body that is not the one the header named, at another version, or not its route's" do
      body = Jason.encode!(WorkerWire.request_body(:status, %{}))
      headers = signed(dispatch_key(), body)

      assert {400, %{"error" => "bad_mac"}} =
               post(WorkerWire.worker_route(:status), headers, body <> " ")

      assert {400, %{"error" => "malformed"}} =
               post(WorkerWire.worker_route(:kill), headers, body)

      kill = Jason.encode!(WorkerWire.request_body(:kill, %{"runner" => "r1"}))

      assert {400, %{"error" => "malformed"}} =
               post(WorkerWire.worker_route(:kill), signed(dispatch_key(), kill), kill)

      # The body's version is read before its op.
      for unversioned <- [~s({"op":"status","args":{}}), ~s({"v":2,"op":"status","args":{}})] do
        assert {400, %{"v" => 1, "error" => "unknown_version"}} =
                 post(
                   WorkerWire.worker_route(:status),
                   signed(dispatch_key(), unversioned),
                   unversioned
                 )
      end

      assert {404, %{"error" => "not_found"}} = post("/worker/v1/other", headers, body)
    end

    test "refuses a body past the host API's bound without serving it" do
      body = String.duplicate("x", Prima.HostAPI.max_body_bytes() + 1)

      assert {413, %{"error" => "malformed"}} =
               post(WorkerWire.worker_route(:kill), signed(dispatch_key(), body), body)

      assert ScriptedWorker.kills() == []
    end
  end

  describe "the host listener its runners reach" do
    setup do
      start_supervised!({ScriptedWorker, ref: @scripted, script: []})
      fixture = AttemptFixtures.attached!(service_id: ScriptedWorker.service())
      {:ok, fixture: fixture, url: ScriptedWorker.host_url()}
    end

    test "is a real host listener, bound on a port of its own", %{url: url} do
      assert "http://127.0.0.1:" <> port = url
      refute url == Cyfr.Test.OpusService.host_url()
      assert String.to_integer(port) > 0
    end

    @tag :capture_log
    test "refuses a header at another version before it reads the body", %{url: url} do
      header =
        "v2 kind=call athanor_id=ath_x execution_id=exec_x attempt=att_x fence=1 generation=1 " <>
          "service=wrk_scripted boot=b runner=r member=m ts=1 nonce=n body=00 mac=AA"

      assert {401, %{"connection" => "close"}, %{"v" => 1, "error" => "unknown_version"}} =
               unread_post(url, WorkerWire.host_route(:renew), header)
    end

    @tag :capture_log
    test "refuses a body at another version once it is opened", %{fixture: fixture, url: url} do
      body = ~s({"v":2,"op":"renew","args":{"attempts":["#{fixture.attempt}"]}})

      assert {400, %{"v" => 1, "error" => "unknown_version"}} =
               host_call(url, fixture, :renew, body)

      assert %{state: "running", lease_until: lease} = attempt_row(fixture)

      # The same call at this version is answered.
      body = Jason.encode!(WorkerWire.request_body(:renew, %{"attempts" => [fixture.attempt]}))
      assert {200, %{"v" => 1, "ok" => %{} = renewals}} = host_call(url, fixture, :renew, body)
      assert %{"lease_until" => _} = renewals[fixture.attempt]
      assert DateTime.compare(attempt_row(fixture).lease_until, lease) in [:gt, :eq]
    end

    test "refuses a call addressed to another member at the same generation", %{
      fixture: fixture,
      url: url
    } do
      body = Jason.encode!(WorkerWire.request_body(:renew, %{"attempts" => [fixture.attempt]}))
      other = "cyfr@elsewhere#boot_" <> Prima.UUID7.generate_id("peer")

      log =
        capture_log(fn ->
          assert {401, %{"v" => 1, "error" => "lost"}} =
                   host_call(url, fixture, :renew, body, member: other)
        end)

      assert log =~ "member_mismatch"
      refute log =~ "generation_mismatch"

      assert {200, %{"ok" => %{}}} = host_call(url, fixture, :renew, body)
    end

    @tag :capture_log
    test "lapses nothing on an exit report naming another member", %{fixture: fixture, url: url} do
      other = "cyfr@elsewhere#boot_" <> Prima.UUID7.generate_id("peer")

      assert {200, %{"v" => 1, "error" => "lost"}} = exit_report(url, fixture, other)
      assert %{state: "running"} = attempt_row(fixture)
      assert Process.alive?(fixture.pid)

      # The report naming this member lapses the attempt its runner held.
      assert {200, %{"v" => 1, "ok" => true}} = exit_report(url, fixture, fixture.member)

      assert {:error, "Execution terminated: runner stopped without cleanup"} =
               Dispatch.await(fixture.pid, fixture.close)

      assert %{state: "lapsed"} = attempt_row(fixture)
    end
  end

  defp attempt_row(fixture),
    do: Arca.ExecutionAttempts.get(Prima.Actor.in_athanor(fixture.athanor_id), fixture.attempt)

  # One host call of `fixture`'s attempt with the JSON `body`, sealed and
  # signed as a runner makes it, the header naming `:member` when given.
  # Answers the status and the answer, opened when sealed.
  defp host_call(url, fixture, callback, body, opts \\ []) do
    fields =
      Map.merge(fixture.keys.attempt, %{
        boot: fixture.boot,
        runner: fixture.runner,
        member: Keyword.get(opts, :member, fixture.member),
        ts: System.system_time(:millisecond),
        nonce: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      })

    {:ok, sealed} = WorkerAuth.seal_call(fixture.keys.seal, :body, fields, body)
    {:ok, header} = WorkerAuth.host_call_header(fixture.call_key, fields, sealed)

    {:ok, response} =
      Req.request(
        method: :post,
        url: url <> WorkerWire.host_route(callback),
        headers: [{WorkerWire.auth_header(), header}],
        body: sealed,
        retry: false,
        decode_body: false
      )

    answer =
      case WorkerAuth.open_call(fixture.keys.seal, :answer, fields, response.body) do
        {:ok, json} -> json
        {:error, :unsealable} -> response.body
      end

    {response.status, Jason.decode!(answer)}
  end

  # A report of the exit of `fixture`'s runner, naming `member`, signed with
  # the scripted worker service's dispatch key as it reports one.
  defp exit_report(url, fixture, member) do
    body =
      :runner_exited
      |> WorkerWire.request_body(%{
        "member" => member,
        "runner" => fixture.runner,
        "attempts" => [fixture.attempt]
      })
      |> Jason.encode!()

    fields = %{
      service: ScriptedWorker.service(),
      boot: fixture.boot,
      ts: System.system_time(:millisecond),
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    }

    {:ok, header} = WorkerAuth.report_header(dispatch_key(), fields, body)

    {:ok, response} =
      Req.request(
        method: :post,
        url: url <> WorkerWire.host_route(:runner_exited),
        headers: [{WorkerWire.auth_header(), header}],
        body: body,
        retry: false,
        decode_body: false
      )

    {response.status, Jason.decode!(response.body)}
  end

  # A request declaring a body it never sends: an answer that arrives was
  # given without reading it, and the listener closes the connection
  # rather than read the rest to reuse it.
  defp unread_post(url, path, header) do
    "http://127.0.0.1:" <> port = url

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, String.to_integer(port), [:binary, active: false])

    :ok =
      :gen_tcp.send(socket, [
        "POST ",
        path,
        " HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 1024\r\n",
        WorkerWire.auth_header(),
        ": ",
        header,
        "\r\n\r\n"
      ])

    {:ok, response} = read_until_closed(socket, "")
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    ["HTTP/1.1 " <> status_line | lines] = String.split(head, "\r\n")
    {status, _reason} = Integer.parse(status_line)

    headers =
      Map.new(lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    {status, headers, Jason.decode!(body)}
  end

  defp read_until_closed(socket, read) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, more} -> read_until_closed(socket, read <> more)
      {:error, :closed} -> {:ok, read}
      {:error, :timeout} -> {:still_open, read}
    end
  end
end
