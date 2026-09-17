# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.HostTest do
  @moduledoc """
  A runner reaches its attempt only through host calls, and each call is
  checked before it acts: the header's MAC under the attempt's call key
  (never its seal key, nor another worker service's), its generation and
  its window; at attach, the assignment's MAC, its claim deadline, that it
  names the header's attempt and is addressed to the header's worker
  service, and the claim on the row;
  on every other call, a nonce not presented before and a row still held
  by the calling runner. Anything that fails answers `lost`, or the
  specific refusal attach names. A runner exit report is signed with the
  reporting worker service's own dispatch key, and lapses only the
  attempts dispatched to it. A boot that does not hold the control
  plane answers every call `lost`: it unseals nothing, its open attempts
  stop without closing their runs, and neither they, their waiters nor a
  runner exit report writes a row.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait
  import ExUnit.CaptureLog

  alias Cyfr.Assignment
  alias Cyfr.Execution.{Close, Dispatch, Keys}
  alias Cyfr.Test.AttemptFixtures

  @service "wrk_host_test"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp attach(fixture, opts \\ []),
    do: AttemptFixtures.call(fixture, "attach", %{"assignment" => fixture.assignment}, opts)

  defp push(fixture, event, opts \\ []) do
    AttemptFixtures.call(
      fixture,
      "push_deltas",
      %{"deltas" => [AttemptFixtures.delta(fixture, Jason.encode!(event))]},
      opts
    )
  end

  defp complete(fixture, output) do
    AttemptFixtures.call(fixture, "complete", %{
      "outcome" => AttemptFixtures.outcome(fixture, "completed", %{"output" => output})
    })
  end

  defp renew(fixture, attempts \\ nil, opts \\ []) do
    AttemptFixtures.call(
      fixture,
      "renew",
      %{"attempts" => attempts || [fixture.attempt]},
      opts
    )
  end

  defp row(fixture), do: Arca.Repo.get!(Arca.Execution, fixture.execution_id)

  defp live_events do
    receive do
      {:execution_event, event} -> [event | live_events()]
    after
      200 -> []
    end
  end

  describe "attach" do
    test "claims the attempt for the runner and answers the fields its vault edge projects" do
      fixture =
        AttemptFixtures.attached!(vault: %{kind: "api_key", fields: %{"KEY" => "sk-fixture"}})

      assert fixture.secrets == %{"KEY" => "sk-fixture"}
      claimed = Arca.Repo.get!(Arca.Schemas.ExecutionAttempt, fixture.attempt)
      assert claimed.claimed_by == fixture.runner
    end

    test "a forged assignment is refused bad_mac and claims nothing" do
      fixture = AttemptFixtures.attached!(attach: false)
      {:ok, assignment} = Assignment.verify(fixture.assignment, Keys.assign_key(), now())
      {:ok, forged} = Assignment.sign(assignment, :crypto.strong_rand_bytes(32))

      assert %{"error" => "bad_mac"} =
               AttemptFixtures.call(fixture, "attach", %{"assignment" => forged})

      assert Arca.Repo.get!(Arca.Schemas.ExecutionAttempt, fixture.attempt).claimed_by == nil
    end

    test "a repeated attach by the same runner is idempotent; a second runner is replayed" do
      fixture =
        AttemptFixtures.attached!(vault: %{kind: "api_key", fields: %{"KEY" => "sk-fixture"}})

      assert %{"ok" => %{"KEY" => "sk-fixture"}} = attach(fixture)
      assert %{"error" => "replayed"} = attach(fixture, runner: "runner_second")

      assert Arca.Repo.get!(Arca.Schemas.ExecutionAttempt, fixture.attempt).claimed_by ==
               fixture.runner
    end

    test "an assignment whose claim deadline passed is refused" do
      fixture = AttemptFixtures.attached!(attach: false)
      {:ok, assignment} = Assignment.verify(fixture.assignment, Keys.assign_key(), now())

      {:ok, stale} =
        Assignment.sign(%{assignment | claim_by: now() - 1}, Keys.assign_key())

      assert %{"error" => "claim_expired"} =
               AttemptFixtures.call(fixture, "attach", %{"assignment" => stale})
    end

    test "an assignment naming another attempt than the header is lost" do
      fixture = AttemptFixtures.attached!(attach: false)
      other = AttemptFixtures.attached!(attach: false)

      assert %{"error" => "lost"} =
               AttemptFixtures.call(fixture, "attach", %{"assignment" => other.assignment})
    end

    @tag :capture_log
    test "an assignment addressed to another worker service is lost and claims nothing" do
      fixture = AttemptFixtures.attached!(attach: false, service_id: @service)

      # The attempt as the other worker service would present it, with the
      # keys CYFR would derive for it there.
      {:ok, keys} = Keys.attempt_keys(%{fixture.keys.attempt | service: "wrk_other"})

      assert %{"error" => "lost"} =
               attach(fixture, service: "wrk_other", call_key: keys.call)

      assert Arca.Repo.get!(Arca.Schemas.ExecutionAttempt, fixture.attempt).claimed_by == nil
      assert %{"ok" => _} = attach(fixture)
    end

    @tag :capture_log
    test "an attach or a call from another boot of the same worker service is lost" do
      fixture = AttemptFixtures.attached!(attach: false, service_id: @service)

      # The boot is signed beside the service but is no key input: the
      # header verifies, and the row's boot is what refuses it.
      assert %{"error" => "lost"} = attach(fixture, boot: "boot_other")
      assert Arca.Repo.get!(Arca.Schemas.ExecutionAttempt, fixture.attempt).claimed_by == nil

      assert %{"ok" => _} = attach(fixture)
      assert %{"ok" => %{} = renewals} = renew(fixture, nil, boot: "boot_other")
      assert renewals[fixture.attempt] == "lost"
      assert %{"error" => "lost"} = push(fixture, %{"type" => "note"}, boot: "boot_other")
      assert %{"ok" => _} = renew(fixture)
    end

    @tag :capture_log
    test "a header signed with the attempt's seal key, or another worker service's call key, is lost" do
      fixture = AttemptFixtures.attached!(attach: false, service_id: @service)
      {:ok, other} = Keys.attempt_keys(%{fixture.keys.attempt | service: "wrk_other"})

      assert capture_log(fn ->
               assert %{"error" => "lost"} = attach(fixture, call_key: fixture.keys.seal)
               assert %{"error" => "lost"} = attach(fixture, call_key: other.call)
             end) =~ "bad_mac"

      assert Arca.Repo.get!(Arca.Schemas.ExecutionAttempt, fixture.attempt).claimed_by == nil
    end

    test "an edge whose consent moved closes the run setup_required" do
      fixture =
        AttemptFixtures.attached!(
          attach: false,
          vault: %{kind: "api_key", fields: %{"KEY" => "sk-fixture"}}
        )

      {:ok, profile} =
        Arca.ProfileStorage.get(fixture.ctx.athanor_id, fixture.authority.profile_id)

      :ok = move_head!(profile)

      assert %{"error" => "setup_required", "payload" => %{"reason" => "consent_moved"}} =
               attach(fixture)

      assert {:error, {:setup_required, %{reason: "consent_moved"}}} =
               Dispatch.await(fixture.pid, fixture.close)

      assert %{status: "failed", error_message: message} = row(fixture)
      assert message =~ ": consent_moved"
    end
  end

  describe "every call" do
    test "a header signed with another key is lost" do
      fixture = AttemptFixtures.attached!()

      log =
        capture_log(fn ->
          assert %{"error" => "lost"} =
                   renew(%{fixture | call_key: :crypto.strong_rand_bytes(32)})

          assert %{"error" => "lost"} =
                   push(fixture, %{"type" => "note"}, call_key: :crypto.strong_rand_bytes(32))
        end)

      assert log =~ "bad_mac"
    end

    test "a header from another generation is refused, though signed with that generation's key" do
      fixture = AttemptFixtures.attached!()
      generation = fixture.generation + 1
      {:ok, keys} = Keys.attempt_keys(%{fixture.keys.attempt | generation: generation})
      opts = [generation: generation, call_key: keys.call]

      log =
        capture_log(fn ->
          assert %{"error" => "lost"} = push(fixture, %{"type" => "note"}, opts)

          assert %{"error" => "lost"} =
                   AttemptFixtures.call(
                     fixture,
                     "renew",
                     %{"attempts" => [fixture.attempt]},
                     opts
                   )
        end)

      assert log =~ "generation_mismatch"
      assert Process.alive?(fixture.pid)
    end

    test "a header outside the time window is lost" do
      fixture = AttemptFixtures.attached!()

      assert capture_log(fn ->
               assert %{"error" => "lost"} =
                        push(fixture, %{"type" => "note"}, ts: now() - 60_000)
             end) =~ "outside_window"
    end

    test "a replayed nonce is refused, and the attempt keeps running" do
      fixture = AttemptFixtures.attached!()
      :ok = Cyfr.Execution.Events.subscribe(fixture.execution_id, fixture.ctx)
      body = AttemptFixtures.body("push_deltas", %{"deltas" => [delta(fixture, "once")]})
      header = AttemptFixtures.header(fixture, body)

      assert %{"ok" => [_reply]} = Jason.decode!(Cyfr.Execution.Host.call(header, body))
      assert %{"error" => "lost"} = Jason.decode!(Cyfr.Execution.Host.call(header, body))

      assert [%{type: "emit", data: %{"text" => "once"}}] = live_events()
      assert Process.alive?(fixture.pid)
    end

    test "a call from a runner that is not the claimant is lost, and the attempt keeps running" do
      fixture = AttemptFixtures.attached!()

      assert %{"error" => "lost"} = push(fixture, %{"type" => "note"}, runner: "runner_other")
      assert %{"ok" => %{} = renewals} = renew(%{fixture | runner: "runner_other"})
      assert renewals[fixture.attempt] == "lost"
      assert Process.alive?(fixture.pid)
    end

    test "a body that is not an operation is lost" do
      fixture = AttemptFixtures.attached!()

      for body <- ["not json", ~s({"op":"storage","args":{}}), ~s({"op":"renew"})] do
        assert %{"error" => "lost"} = AttemptFixtures.call(fixture, "ignored", %{}, body: body)
      end
    end
  end

  describe "renew" do
    test "renews the caller's own attempt, carries a cancel, and names any other attempt lost" do
      fixture = AttemptFixtures.attached!()

      assert %{"ok" => %{} = renewals} = renew(fixture, [fixture.attempt, "att_other"])
      assert %{"lease_until" => until} = renewals[fixture.attempt]
      assert until > now()
      assert renewals["att_other"] == "lost"

      {:ok, 1} = Arca.ExecutionAttempts.request_cancel(fixture.athanor_id, fixture.execution_id)
      assert %{"ok" => %{} = renewals} = renew(fixture)
      assert renewals[fixture.attempt] == "cancel"
    end
  end

  describe "closing" do
    test "complete masks the output, closes the row and tells the waiter" do
      fixture =
        AttemptFixtures.attached!(vault: %{kind: "api_key", fields: %{"KEY" => "sk-fixture"}})

      assert %{"ok" => %{"said" => "[REDACTED]"}} = complete(fixture, %{"said" => "sk-fixture"})

      assert {:ok, %{status: :completed, output: %{"said" => "[REDACTED]"}}} =
               Dispatch.await(fixture.pid, fixture.close)

      assert row(fixture).status == "completed"
    end

    test "fail closes the row failed with the masked error" do
      fixture =
        AttemptFixtures.attached!(vault: %{kind: "api_key", fields: %{"KEY" => "sk-fixture"}})

      outcome = AttemptFixtures.outcome(fixture, "failed", %{"error" => "saw sk-fixture"})

      assert %{"ok" => "saw [REDACTED]"} =
               AttemptFixtures.call(fixture, "fail", %{"outcome" => outcome})

      assert {:error, "saw [REDACTED]"} = Dispatch.await(fixture.pid, fixture.close)
      assert %{status: "failed", error_message: "saw [REDACTED]"} = row(fixture)
    end

    @tag :capture_log
    test "an outcome naming another attempt closes nothing" do
      fixture = AttemptFixtures.attached!()
      outcome = %{AttemptFixtures.outcome(fixture, "completed", %{}) | "fence" => 7}

      assert %{"error" => "lost"} =
               AttemptFixtures.call(fixture, "complete", %{"outcome" => outcome})

      assert row(fixture).status == "running"
      assert Process.alive?(fixture.pid)
    end

    test "a delta pushed after the terminal row is refused" do
      fixture = AttemptFixtures.attached!()
      assert %{"ok" => _} = complete(fixture, %{"done" => true})
      assert {:ok, _} = Dispatch.await(fixture.pid, fixture.close)

      :ok = Cyfr.Execution.Events.subscribe(fixture.execution_id, fixture.ctx)
      assert %{"error" => "lost"} = push(fixture, %{"type" => "note", "text" => "late"})
      assert live_events() == []
    end
  end

  describe "after a takeover raises the fence" do
    setup do
      fixture = AttemptFixtures.attached!()
      :ok = Cyfr.Execution.Events.subscribe(fixture.execution_id, fixture.ctx)

      {:ok, %{attempt: successor}} =
        Arca.ExecutionAttempts.takeover(fixture.athanor_id, fixture.execution_id,
          boot_id: Cyfr.Boot.id(),
          lease_until: Arca.ExecutionAttempts.lease_until()
        )

      {:ok, fixture: fixture, successor: successor}
    end

    test "renew, push and complete answer lost, and the delta is dropped", %{
      fixture: fixture,
      successor: successor
    } do
      assert successor.fence == fixture.fence + 1

      assert %{"ok" => %{} = renewals} = renew(fixture)
      assert renewals[fixture.attempt] == "lost"

      assert %{"error" => "lost"} = push(fixture, %{"type" => "note", "text" => "stale"})
      assert %{"error" => "lost"} = complete(fixture, %{"stale" => true})

      assert live_events() == []
      assert %{status: "running", current_attempt: current} = row(fixture)
      assert current == successor.attempt
    end

    test "the attempt stops without closing, and its waiter's lost close writes nothing", %{
      fixture: fixture,
      successor: successor
    } do
      assert %{"error" => "lost"} = push(fixture, %{"type" => "note"})
      wait_until(fn -> not Process.alive?(fixture.pid) end)

      assert {:error, "Execution attempt ended before it closed"} =
               Dispatch.await(fixture.pid, fixture.close)

      assert %{status: "running", current_attempt: current} = row(fixture)
      assert current == successor.attempt
    end
  end

  describe "a turn root" do
    test "is never claimed, and a host call naming its attempt answers lost" do
      ctx = Sanctum.TestContext.local()

      {:ok, %{execution: execution, attempt: attempt}} =
        Arca.Execution.admit(%{
          id: Cyfr.UUID7.execution_id(),
          reference: "agent:local.aqua:0.1.0",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "agent",
          kind: "turn"
        })

      assert attempt.claimed_by == nil

      # Held by the control plane: dispatched to no worker service.
      assert attempt.service_id == nil
      assert attempt.boot_id == Cyfr.Boot.id()

      fixture =
        Map.merge(AttemptFixtures.current!(ctx.athanor_id, execution.id), %{
          runner: attempt.boot_id
        })

      assert %{"ok" => %{} = renewals} = renew(fixture)
      assert renewals[attempt.attempt] == "lost"
      assert %{"error" => "lost"} = push(fixture, %{"type" => "note"})
      assert %{"error" => "lost"} = complete(fixture, %{})

      assert %{"error" => "lost"} =
               AttemptFixtures.call(fixture, "take_rate", %{"bucket" => "http:agent:local.aqua"})

      assert Arca.Repo.get!(Arca.Execution, execution.id).status == "running"
    end
  end

  describe "rates and tokens" do
    test "take_rate counts the node's consented rate, only under its own bucket" do
      limits = %{Cyfr.Limits.defaults(:catalyst) | rate_limit: %{requests: 1, window: "1m"}}
      fixture = AttemptFixtures.attached!(limits: limits)
      bucket = "http:" <> fixture.component_ref

      assert %{"ok" => true} = AttemptFixtures.call(fixture, "take_rate", %{"bucket" => bucket})

      assert %{"error" => "guest_error", "type" => "rate_limited", "message" => message} =
               AttemptFixtures.call(fixture, "take_rate", %{"bucket" => bucket})

      assert message =~ "rate limit exceeded"

      assert %{"error" => "guest_error", "type" => "rate_limited"} =
               AttemptFixtures.call(fixture, "take_rate", %{"bucket" => "http:catalyst:other"})
    end

    test "a dispensed token is in the masking set before it is answered" do
      fixture =
        AttemptFixtures.attached!(vault: %{kind: "oauth", oauth: %{"access_token" => "ya29.tok"}})

      assert %{"ok" => "ya29.tok"} =
               AttemptFixtures.call(fixture, "oauth_token", %{"provider" => "google"})

      assert %{"ok" => %{"said" => "[REDACTED]"}} = complete(fixture, %{"said" => "ya29.tok"})
    end
  end

  describe "a lost close after the attempt's terminal write" do
    test "leaves the completed row, its children and its telemetry as the attempt wrote them" do
      fixture = AttemptFixtures.attached!(component_type: :formula)
      child = child_of!(fixture)
      assert %{"ok" => %{"done" => true}} = complete(fixture, %{"done" => true})
      assert {:ok, _result} = Dispatch.await(fixture.pid, fixture.close)

      handler = "host-test-lost-#{System.unique_integer([:positive])}"
      test = self()

      :ok =
        :telemetry.attach(
          handler,
          [:cyfr, :opus, :execute, :exception],
          fn _event, _measurements, metadata, _config -> send(test, {:exception, metadata}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, %{status: :completed, output: %{"done" => true}}} = Close.lost(fixture.close)

      assert row(fixture).status == "completed"
      assert Arca.Repo.get!(Arca.Execution, child).status == "running"
      refute_received {:exception, _}
    end
  end

  describe "a boot that does not hold the control plane" do
    setup do
      on_exit(fn -> Cyfr.ControlPlane.mark(:unclaimed) end)
      :ok
    end

    @tag :capture_log
    test "refuses attach, unseals nothing, and its waiter's lost close writes nothing" do
      fixture =
        AttemptFixtures.attached!(
          attach: false,
          vault: %{kind: "api_key", fields: %{"KEY" => "sk-fixture"}}
        )

      Cyfr.ControlPlane.mark(:lost)

      assert %{"error" => "lost"} = attach(fixture)

      assert {:error, :lost} =
               Cyfr.Execution.Attempt.attach(
                 fixture.execution_id,
                 AttemptFixtures.caller(fixture)
               )

      assert {:error, "Execution attempt ended before it closed"} =
               Dispatch.await(fixture.pid, fixture.close)

      assert Arca.Repo.get!(Arca.Schemas.ExecutionAttempt, fixture.attempt).claimed_by == nil

      assert {:ok, %{last_used_at: nil}} =
               Arca.VaultStorage.get(fixture.athanor_id, fixture.entry.id)

      assert %{status: "running"} = row(fixture)
      assert terminal_events(fixture) == []
    end

    @tag :capture_log
    test "refuses emit, renew and complete mid-run; the attempt stops and nothing closes the row" do
      fixture =
        AttemptFixtures.attached!(vault: %{kind: "api_key", fields: %{"KEY" => "sk-fixture"}})

      :ok = Cyfr.Execution.Events.subscribe(fixture.execution_id, fixture.ctx)
      Cyfr.ControlPlane.mark(:lost)

      assert %{"error" => "lost"} = push(fixture, %{"type" => "note", "text" => "late"})
      assert %{"error" => "lost"} = renew(fixture)
      assert %{"error" => "lost"} = complete(fixture, %{"said" => "done"})

      assert {:error, "Execution attempt ended before it closed"} =
               Dispatch.await(fixture.pid, fixture.close)

      refute Process.alive?(fixture.pid)
      assert %{status: "running"} = row(fixture)
      assert live_events() == []
      assert terminal_events(fixture) == []

      Cyfr.ControlPlane.mark(:unclaimed)
      assert %{"error" => "lost"} = complete(fixture, %{"said" => "done"})
      assert %{status: "running"} = row(fixture)
    end

    test "an open attempt stops on its own within a second, without closing its run" do
      fixture = AttemptFixtures.attached!()
      Cyfr.ControlPlane.mark(:lost)

      wait_until(fn -> not Process.alive?(fixture.pid) end, 3_000)
      assert %{status: "running"} = row(fixture)
      assert terminal_events(fixture) == []
    end

    test "a run refused before its runner started is left for the holder, not closed" do
      fixture = AttemptFixtures.attached!(attach: false)
      Cyfr.ControlPlane.mark(:lost)

      assert :closed = Cyfr.Execution.Attempt.refuse(fixture.pid, "not started")
      refute Process.alive?(fixture.pid)
      assert %{status: "running"} = row(fixture)
      assert terminal_events(fixture) == []
    end

    @tag :capture_log
    test "a runner exit report lapses nothing" do
      fixture = AttemptFixtures.attached!(service_id: @service)
      Cyfr.ControlPlane.mark(:lost)

      assert %{"error" => "unavailable"} = report(fixture)

      assert %{status: "running"} = row(fixture)
      assert %{state: "running"} = Arca.ExecutionAttempts.get(fixture.athanor_id, fixture.attempt)
    end
  end

  describe "a runner exit report" do
    # A report of the exit of `fixture`'s runner, naming the fixture's
    # service, boot and runner unless `:service`, `:boot` or `:runner`
    # override them, signed with the dispatch key of `:signer` (default the
    # service it names) or with `:key`.
    defp report(fixture, opts \\ []) do
      service = Keyword.get(opts, :service, fixture.service)
      runner = Keyword.get(opts, :runner, fixture.runner)

      body =
        AttemptFixtures.body("runner_exited", %{
          "runner" => runner,
          "attempts" => [fixture.attempt]
        })

      fields = %{
        service: service,
        boot: Keyword.get(opts, :boot, fixture.boot),
        ts: now(),
        nonce: "n_#{System.unique_integer([:positive])}"
      }

      key = Keyword.get_lazy(opts, :key, fn -> dispatch_key(opts[:signer] || service) end)
      {:ok, header} = Cyfr.WorkerAuth.report_header(key, fields, body)
      header |> Cyfr.Execution.Host.runner_exited(body) |> Jason.decode!()
    end

    defp dispatch_key(service) do
      {:ok, worker_key} = Keys.worker_key(service)
      Cyfr.WorkerAuth.dispatch_key(worker_key)
    end

    test "lapses the reporting worker's running attempts at once and stops their attempts" do
      fixture = AttemptFixtures.attached!(service_id: @service, component_type: :formula)
      child = child_of!(fixture)

      assert %{"ok" => true} = report(fixture)

      assert {:error, "Execution terminated: runner stopped without cleanup"} =
               Dispatch.await(fixture.pid, fixture.close)

      assert %{status: "failed"} = row(fixture)

      assert %{state: "lapsed", outcome: "uncertain"} =
               Arca.ExecutionAttempts.get(fixture.athanor_id, fixture.attempt)

      assert {:ok, events} =
               Arca.ExecutionEvents.since(fixture.athanor_id, fixture.execution_id, 0)

      assert "execution.lapsed" in Enum.map(events, & &1.type)

      assert %{status: "failed", error_message: message} = Arca.Repo.get!(Arca.Execution, child)
      assert message == "Parent execution (#{fixture.execution_id}) terminated"
    end

    test "a waiter admitted on the guest plane answers the lapsed row's error" do
      guest = Sanctum.Context.enter_guest(Sanctum.TestContext.local())
      fixture = AttemptFixtures.attached!(ctx: guest, service_id: @service)

      assert %{"ok" => true} = report(fixture)

      assert {:error, "Execution terminated: runner stopped without cleanup"} =
               Dispatch.await(fixture.pid, fixture.close)

      assert fixture.close.ctx.plane == :guest
    end

    @tag :capture_log
    test "lapses nothing dispatched to another worker, boot or runner, and a forged report nothing at all" do
      fixture = AttemptFixtures.attached!(service_id: @service)

      # Verified reports that speak for another worker service, another
      # boot of this one, or another runner name an attempt that is not
      # theirs to lapse.
      assert %{"ok" => true} = report(fixture, service: "wrk_other")
      assert %{"ok" => true} = report(fixture, boot: "boot_other")
      assert %{"ok" => true} = report(fixture, runner: "run_other")
      assert %{"error" => "lost"} = report(fixture, key: Keys.assign_key())

      forged_body = AttemptFixtures.body("renew", %{"attempts" => [fixture.attempt]})
      fields = %{service: @service, boot: fixture.boot, ts: now(), nonce: "n_forged"}
      {:ok, header} = Cyfr.WorkerAuth.report_header(dispatch_key(@service), fields, forged_body)

      assert %{"error" => "lost"} =
               header |> Cyfr.Execution.Host.runner_exited(forged_body) |> Jason.decode!()

      assert row(fixture).status == "running"
      assert Process.alive?(fixture.pid)
      assert %{"ok" => _} = renew(fixture)
      Cyfr.Execution.Attempt.refuse(fixture.pid, "not started")
    end

    @tag :capture_log
    test "signed by another worker service for this one, lapses nothing" do
      fixture = AttemptFixtures.attached!(service_id: @service)

      assert %{"error" => "lost"} = report(fixture, signer: "wrk_other")

      assert row(fixture).status == "running"
      assert %{state: "running"} = Arca.ExecutionAttempts.get(fixture.athanor_id, fixture.attempt)
      assert Process.alive?(fixture.pid)
      assert %{"ok" => _} = renew(fixture)
      Cyfr.Execution.Attempt.refuse(fixture.pid, "not started")
    end

    test "leaves a closed attempt's row as it closed, and is idempotent" do
      fixture = AttemptFixtures.attached!(service_id: @service)
      assert %{"ok" => _} = complete(fixture, %{"done" => true})
      assert {:ok, _} = Dispatch.await(fixture.pid, fixture.close)

      assert %{"ok" => true} = report(fixture)
      assert %{"ok" => true} = report(fixture)
      assert row(fixture).status == "completed"
    end
  end

  defp terminal_events(fixture) do
    {:ok, rows} = Arca.ExecutionEvents.since(fixture.athanor_id, fixture.execution_id, 0)
    for %{type: type} <- rows, type in Arca.ExecutionEvents.terminal_types(), do: type
  end

  defp delta(fixture, text),
    do: AttemptFixtures.delta(fixture, Jason.encode!(%{"type" => "note", "text" => text}))

  defp now, do: System.system_time(:millisecond)

  defp move_head!(profile) do
    Arca.ProfileStorage.advance_head(
      profile.athanor_id,
      profile.id,
      profile.head_consent_id,
      Cyfr.UUID7.generate_id("cons")
    )
  end

  defp child_of!(fixture) do
    {:ok, %{execution: child}} =
      Arca.Execution.admit(%{
        id: Cyfr.UUID7.execution_id(),
        reference: "reagent:local.child:0.1.0",
        user_id: fixture.ctx.user_id,
        athanor_id: fixture.athanor_id,
        component_type: "reagent",
        parent_execution_id: fixture.execution_id,
        root_execution_id: fixture.execution_id
      })

    child.id
  end
end
