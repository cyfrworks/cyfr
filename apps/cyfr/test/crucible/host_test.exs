# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.HostTest do
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

  Every call of `tests/fixtures/host_api.json` is sent with its body read
  as the vector writes it, bound to a live attempt, and its answer is
  written as the vector writes answers: the wire's version first, and the
  vector's answer or one of the refusals it lists. Its connection cases are
  sent in order by one formula attempt and answered as the vector answers
  them: a child naming no account is admitted on its edge's default, one
  naming an account the edge lacks is refused, and a child key repeated
  naming another connection than its child's is refused `invalid_request`.
  """

  use ExUnit.Case, async: false

  import Prima.Test.Wait
  import ExUnit.CaptureLog

  alias Prima.{Assignment, PinnedTarget, WorkerWire}
  alias Prima.Authority.Blob
  alias Crucible.{Close, Dispatch, Keys}
  alias Cyfr.Test.AttemptFixtures

  @service "wrk_host_test"

  @vectors_path Path.expand("../../../../tests/fixtures/host_api.json", __DIR__)
  @external_resource @vectors_path
  @vectors @vectors_path |> File.read!() |> Jason.decode!()

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
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

  defp row(fixture), do: Arca.Repo.get!(Arca.Schemas.Execution, fixture.execution_id)

  defp live_events do
    receive do
      %Cyfr.Bus.ExecutionEvent{} = event -> [Cyfr.Bus.ExecutionEvent.event(event) | live_events()]
    after
      200 -> []
    end
  end

  describe "attach" do
    test "claims the attempt for the runner and answers the fields its vault edge projects" do
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          vault: %{kind: "api_key", fields: %{"KEY" => "sk-fixture"}}
        )

      assert fixture.secrets == %{"KEY" => "sk-fixture"}
      claimed = Arca.Repo.get!(Arca.Schemas.ExecutionAttempt, fixture.attempt)
      assert claimed.claimed_by == fixture.runner
    end

    test "a forged assignment is refused bad_mac and claims nothing" do
      fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), attach: false)
      {:ok, assignment} = Assignment.verify(fixture.assignment, Keys.assign_key(), now())
      {:ok, forged} = Assignment.sign(assignment, :crypto.strong_rand_bytes(32))

      assert %{"error" => "bad_mac"} =
               AttemptFixtures.call(fixture, "attach", %{"assignment" => forged})

      assert Arca.Repo.get!(Arca.Schemas.ExecutionAttempt, fixture.attempt).claimed_by == nil
    end

    test "a repeated attach by the same runner is idempotent; a second runner is replayed" do
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          vault: %{kind: "api_key", fields: %{"KEY" => "sk-fixture"}}
        )

      assert %{"ok" => %{"KEY" => "sk-fixture"}} = attach(fixture)
      assert %{"error" => "replayed"} = attach(fixture, runner: "runner_second")

      assert Arca.Repo.get!(Arca.Schemas.ExecutionAttempt, fixture.attempt).claimed_by ==
               fixture.runner
    end

    test "an assignment whose claim deadline passed is refused" do
      fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), attach: false)
      {:ok, assignment} = Assignment.verify(fixture.assignment, Keys.assign_key(), now())

      {:ok, stale} =
        Assignment.sign(%{assignment | claim_by: now() - 1}, Keys.assign_key())

      assert %{"error" => "claim_expired"} =
               AttemptFixtures.call(fixture, "attach", %{"assignment" => stale})
    end

    test "an assignment naming another attempt than the header is lost" do
      fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), attach: false)
      other = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), attach: false)

      assert %{"error" => "lost"} =
               AttemptFixtures.call(fixture, "attach", %{"assignment" => other.assignment})
    end

    @tag :capture_log
    test "an assignment addressed to another worker service is lost and claims nothing" do
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          attach: false,
          service_id: @service
        )

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
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          attach: false,
          service_id: @service
        )

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
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          attach: false,
          service_id: @service
        )

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
          ctx: Sanctum.TestContext.local(:api),
          attach: false,
          vault: %{kind: "api_key", fields: %{"KEY" => "sk-fixture"}}
        )

      {:ok, profile} =
        Arca.ProfileStorage.get(Sanctum.Context.actor(fixture.ctx), fixture.authority.profile_id)

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
      fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api))

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
      fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api))
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
      fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api))

      assert capture_log(fn ->
               assert %{"error" => "lost"} =
                        push(fixture, %{"type" => "note"}, ts: now() - 60_000)
             end) =~ "outside_window"
    end

    test "a replayed nonce is refused, and the attempt keeps running" do
      fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api))
      :ok = Crucible.Events.subscribe(fixture.execution_id, fixture.ctx)
      body = AttemptFixtures.body("push_deltas", %{"deltas" => [delta(fixture, "once")]})
      header = AttemptFixtures.header(fixture, body)

      assert %{"ok" => [_reply]} = Jason.decode!(Crucible.Host.call(header, body))
      assert %{"error" => "lost"} = Jason.decode!(Crucible.Host.call(header, body))

      assert [%{type: "emit", data: %{"text" => "once"}}] = live_events()
      assert Process.alive?(fixture.pid)
    end

    test "a call from a runner that is not the claimant is lost, and the attempt keeps running" do
      fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api))

      assert %{"error" => "lost"} = push(fixture, %{"type" => "note"}, runner: "runner_other")
      assert %{"ok" => %{} = renewals} = renew(%{fixture | runner: "runner_other"})
      assert renewals[fixture.attempt] == "lost"
      assert Process.alive?(fixture.pid)
    end

    test "a body that is not an operation is lost; one at another version is told so" do
      fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api))

      for body <- [
            "not json",
            ~s({"v":1,"op":"storage","args":{}}),
            ~s({"v":1,"op":"renew"}),
            ~s({"v":1,"op":"runner_exited","args":{}}),
            ~s({"v":1,"op":"renew","args":{"attempts":[]},"extra":true}),
            ~s(["renew"])
          ] do
        assert %{"v" => 1, "error" => "lost"} =
                 AttemptFixtures.call(fixture, "ignored", %{}, body: body),
               body
      end

      # The version is read before the operation.
      for body <- [
            ~s({"op":"renew","args":{"attempts":[]}}),
            ~s({"v":2,"op":"renew","args":{"attempts":[]}}),
            ~s({"v":"1","op":"renew","args":{"attempts":[]}}),
            ~s({"v":2,"op":"nothing"})
          ] do
        assert %{"v" => 1, "error" => "unknown_version"} =
                 AttemptFixtures.call(fixture, "ignored", %{}, body: body),
               body
      end

      assert Process.alive?(fixture.pid)
      assert %{"ok" => _} = renew(fixture)
    end
  end

  describe "renew" do
    test "renews the caller's own attempt, carries a cancel, and names any other attempt lost" do
      fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api))

      assert %{"ok" => %{} = renewals} = renew(fixture, [fixture.attempt, "att_other"])
      assert %{"lease_until" => until} = renewals[fixture.attempt]
      assert until > now()
      assert renewals["att_other"] == "lost"
    end
  end

  describe "closing" do
    test "complete masks the output, closes the row and tells the waiter" do
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          vault: %{kind: "api_key", fields: %{"KEY" => "sk-fixture"}}
        )

      assert %{"ok" => %{"said" => "[REDACTED]"}} = complete(fixture, %{"said" => "sk-fixture"})

      assert {:ok, %{status: :completed, output: %{"said" => "[REDACTED]"}}} =
               Dispatch.await(fixture.pid, fixture.close)

      assert row(fixture).status == "completed"
    end

    test "fail closes the row failed with the masked error" do
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          vault: %{kind: "api_key", fields: %{"KEY" => "sk-fixture"}}
        )

      outcome = AttemptFixtures.outcome(fixture, "failed", %{"error" => "saw sk-fixture"})

      assert %{"ok" => "saw [REDACTED]"} =
               AttemptFixtures.call(fixture, "fail", %{"outcome" => outcome})

      assert {:error, "saw [REDACTED]"} = Dispatch.await(fixture.pid, fixture.close)
      assert %{status: "failed", error_message: "saw [REDACTED]"} = row(fixture)
    end

    @tag :capture_log
    test "an outcome naming another attempt closes nothing" do
      fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api))
      outcome = %{AttemptFixtures.outcome(fixture, "completed", %{}) | "fence" => 7}

      assert %{"error" => "lost"} =
               AttemptFixtures.call(fixture, "complete", %{"outcome" => outcome})

      assert row(fixture).status == "running"
      assert Process.alive?(fixture.pid)
    end

    test "a delta pushed after the terminal row is refused" do
      fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api))
      assert %{"ok" => _} = complete(fixture, %{"done" => true})
      assert {:ok, _} = Dispatch.await(fixture.pid, fixture.close)

      :ok = Crucible.Events.subscribe(fixture.execution_id, fixture.ctx)
      assert %{"error" => "lost"} = push(fixture, %{"type" => "note", "text" => "late"})
      assert live_events() == []
    end
  end

  describe "after a takeover raises the fence" do
    setup do
      fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api))
      :ok = Crucible.Events.subscribe(fixture.execution_id, fixture.ctx)

      {:ok, %{attempt: successor}} =
        Arca.ExecutionAttempts.takeover(
          Prima.Actor.in_athanor(fixture.athanor_id),
          fixture.execution_id,
          boot_id: Prima.Boot.id(),
          lease_until: Arca.ExecutionAttempts.lease_until(),
          grant: :stored,
          verify: &Sanctum.ExecutionStanding.verify/1
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
      ctx = Sanctum.TestContext.local(:api)

      {:ok, %{execution: execution, attempt: attempt}} =
        Arca.Execution.admit(
          %{
            id: Prima.UUID7.execution_id(),
            reference: "agent:local.aqua:0.1.0",
            user_id: ctx.user_id,
            athanor_id: ctx.athanor_id,
            component_type: "agent",
            kind: "turn",
            origin: :programmatic
          },
          Cyfr.Test.AttemptFixtures.standing(ctx.athanor_id)
        )

      assert attempt.claimed_by == nil

      # Held by the control plane: dispatched to no worker service.
      assert attempt.service_id == nil
      assert attempt.boot_id == Prima.Boot.id()

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

      assert Arca.Repo.get!(Arca.Schemas.Execution, execution.id).status == "running"
    end
  end

  describe "rates and tokens" do
    test "take_rate counts the node's consented rate, only under its own bucket" do
      limits = %{Prima.Limits.defaults(:catalyst) | rate_limit: %{requests: 1, window: "1m"}}
      fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), limits: limits)
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
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          vault: %{kind: "oauth", oauth: %{"access_token" => "ya29.tok"}}
        )

      assert %{"ok" => "ya29.tok"} =
               AttemptFixtures.call(fixture, "oauth_token", %{"provider" => "google"})

      assert %{"ok" => %{"said" => "[REDACTED]"}} = complete(fixture, %{"said" => "ya29.tok"})
    end
  end

  describe "a lost close after the attempt's terminal write" do
    test "leaves the completed row, its children and its telemetry as the attempt wrote them" do
      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), component_type: :formula)

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
      assert Arca.Repo.get!(Arca.Schemas.Execution, child).status == "running"
      refute_received {:exception, _}
    end
  end

  describe "a boot that does not hold the control plane" do
    setup do
      on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)
      :ok
    end

    @tag :capture_log
    test "refuses attach, unseals nothing, and its waiter's lost close writes nothing" do
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          attach: false,
          vault: %{kind: "api_key", fields: %{"KEY" => "sk-fixture"}}
        )

      Arca.ControlPlane.record(:lost)

      assert %{"error" => "lost"} = attach(fixture)

      assert {:error, :lost} =
               Crucible.Attempt.attach(
                 fixture.execution_id,
                 AttemptFixtures.caller(fixture)
               )

      assert {:error, "Execution attempt ended before it closed"} =
               Dispatch.await(fixture.pid, fixture.close)

      assert Arca.Repo.get!(Arca.Schemas.ExecutionAttempt, fixture.attempt).claimed_by == nil

      assert {:ok, %{last_used_at: nil}} =
               Arca.VaultStorage.get(
                 %Prima.Actor{athanor_id: fixture.athanor_id},
                 fixture.entry.id
               )

      assert %{status: "running"} = row(fixture)
      assert terminal_events(fixture) == []
    end

    @tag :capture_log
    test "refuses emit, renew and complete mid-run; the attempt stops and nothing closes the row" do
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          vault: %{kind: "api_key", fields: %{"KEY" => "sk-fixture"}}
        )

      :ok = Crucible.Events.subscribe(fixture.execution_id, fixture.ctx)
      Arca.ControlPlane.record(:lost)

      assert %{"error" => "lost"} = push(fixture, %{"type" => "note", "text" => "late"})
      assert %{"error" => "lost"} = renew(fixture)
      assert %{"error" => "lost"} = complete(fixture, %{"said" => "done"})

      assert {:error, "Execution attempt ended before it closed"} =
               Dispatch.await(fixture.pid, fixture.close)

      refute Process.alive?(fixture.pid)
      assert %{status: "running"} = row(fixture)
      assert live_events() == []
      assert terminal_events(fixture) == []

      Arca.ControlPlane.record(:unclaimed)
      assert %{"error" => "lost"} = complete(fixture, %{"said" => "done"})
      assert %{status: "running"} = row(fixture)
    end

    test "an open attempt stops on its own within a second, without closing its run" do
      fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api))
      Arca.ControlPlane.record(:lost)

      wait_until(fn -> not Process.alive?(fixture.pid) end, 3_000)
      assert %{status: "running"} = row(fixture)
      assert terminal_events(fixture) == []
    end

    test "a run refused before its runner started is left for the holder, not closed" do
      fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), attach: false)
      Arca.ControlPlane.record(:lost)

      assert :closed = Crucible.Attempt.refuse(fixture.pid, "not started")
      refute Process.alive?(fixture.pid)
      assert %{status: "running"} = row(fixture)
      assert terminal_events(fixture) == []
    end

    @tag :capture_log
    test "a runner exit report lapses nothing" do
      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), service_id: @service)

      Arca.ControlPlane.record(:lost)

      assert %{"error" => "unavailable"} = report(fixture)

      assert %{status: "running"} = row(fixture)

      assert %{state: "running"} =
               Arca.ExecutionAttempts.get(
                 Prima.Actor.in_athanor(fixture.athanor_id),
                 fixture.attempt
               )
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
          "member" => Keyword.get(opts, :member, fixture.member),
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
      {:ok, header} = Prima.WorkerAuth.report_header(key, fields, body)
      header |> Crucible.Host.runner_exited(body) |> Jason.decode!()
    end

    defp dispatch_key(service) do
      {:ok, worker_key} = Keys.opus_key(service)
      Prima.WorkerAuth.dispatch_key(worker_key)
    end

    test "lapses the reporting worker's running attempts at once and stops their attempts" do
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          service_id: @service,
          component_type: :formula
        )

      child = child_of!(fixture)

      assert %{"ok" => true} = report(fixture)

      assert {:error, "Execution terminated: runner stopped without cleanup"} =
               Dispatch.await(fixture.pid, fixture.close)

      assert %{status: "failed"} = row(fixture)

      assert %{state: "lapsed", outcome: "uncertain"} =
               Arca.ExecutionAttempts.get(
                 Prima.Actor.in_athanor(fixture.athanor_id),
                 fixture.attempt
               )

      assert {:ok, events} =
               Arca.ExecutionEvents.since(
                 Prima.Actor.in_athanor(fixture.athanor_id),
                 fixture.execution_id,
                 0
               )

      assert "execution.lapsed" in Enum.map(events, & &1.type)

      assert %{status: "failed", error_message: message} =
               Arca.Repo.get!(Arca.Schemas.Execution, child)

      assert message == "Parent execution (#{fixture.execution_id}) terminated"
    end

    test "a waiter admitted on the guest plane answers the lapsed row's error" do
      guest = Sanctum.Context.enter_guest(Sanctum.TestContext.local(:api))
      fixture = AttemptFixtures.attached!(ctx: guest, service_id: @service)

      assert %{"ok" => true} = report(fixture)

      assert {:error, "Execution terminated: runner stopped without cleanup"} =
               Dispatch.await(fixture.pid, fixture.close)

      assert fixture.close.ctx.plane == :guest
    end

    @tag :capture_log
    test "lapses nothing dispatched to another worker, boot or runner, and a forged report nothing at all" do
      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), service_id: @service)

      # Verified reports that speak for another worker service, another
      # boot of this one, or another runner name an attempt that is not
      # theirs to lapse.
      assert %{"ok" => true} = report(fixture, service: "wrk_other")
      assert %{"ok" => true} = report(fixture, boot: "boot_other")
      assert %{"ok" => true} = report(fixture, runner: "run_other")
      assert %{"error" => "lost"} = report(fixture, key: Keys.assign_key())

      forged_body = AttemptFixtures.body("renew", %{"attempts" => [fixture.attempt]})
      fields = %{service: @service, boot: fixture.boot, ts: now(), nonce: "n_forged"}
      {:ok, header} = Prima.WorkerAuth.report_header(dispatch_key(@service), fields, forged_body)

      assert %{"error" => "lost"} =
               header |> Crucible.Host.runner_exited(forged_body) |> Jason.decode!()

      assert row(fixture).status == "running"
      assert Process.alive?(fixture.pid)
      assert %{"ok" => _} = renew(fixture)
      Crucible.Attempt.refuse(fixture.pid, "not started")
    end

    @tag :capture_log
    test "signed by another worker service for this one, lapses nothing" do
      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), service_id: @service)

      assert %{"error" => "lost"} = report(fixture, signer: "wrk_other")

      assert row(fixture).status == "running"

      assert %{state: "running"} =
               Arca.ExecutionAttempts.get(
                 Prima.Actor.in_athanor(fixture.athanor_id),
                 fixture.attempt
               )

      assert Process.alive?(fixture.pid)
      assert %{"ok" => _} = renew(fixture)
      Crucible.Attempt.refuse(fixture.pid, "not started")
    end

    test "leaves a closed attempt's row as it closed, and is idempotent" do
      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), service_id: @service)

      assert %{"ok" => _} = complete(fixture, %{"done" => true})
      assert {:ok, _} = Dispatch.await(fixture.pid, fixture.close)

      assert %{"ok" => true} = report(fixture)
      assert %{"ok" => true} = report(fixture)
      assert row(fixture).status == "completed"
    end

    @tag :capture_log
    test "stops an attempt a caller ended, leaving its row as the caller ended it; a stale or repeated report changes nothing" do
      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), service_id: @service)

      assert {:ok, %{cancelled: true}} = Crucible.cancel(fixture.ctx, fixture.execution_id)
      ended = row(fixture)
      assert ended.status == "cancelled"

      attempt = fn ->
        Arca.ExecutionAttempts.get(Prima.Actor.in_athanor(fixture.athanor_id), fixture.attempt)
      end

      held = attempt.()

      # Reports that do not speak for this attempt's runner on this member
      # stop nothing.
      assert %{"error" => "lost"} = report(fixture, member: "#{fixture.member}_stale")
      assert %{"ok" => true} = report(fixture, boot: "boot_stale")
      assert %{"ok" => true} = report(fixture, runner: "runner_stale")
      assert Process.alive?(fixture.pid)

      # The report of its runner's end stops the attempt without closing
      # its run: the waiter hears it stopped, and the row, its attempt and
      # its events stand as the cancel wrote them.
      monitor = Process.monitor(fixture.pid)
      assert %{"ok" => true} = report(fixture)
      assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 5_000
      # The registry drops a dead process's name when it hears the exit,
      # after the monitor's `:DOWN` may already have arrived here.
      wait_until(fn -> Crucible.Attempt.whereis(fixture.execution_id) == nil end)
      assert {:error, _stopped} = Dispatch.await(fixture.pid, fixture.close)

      events = terminal_events(fixture)

      for _ <- 1..2 do
        assert Map.take(row(fixture), [:status, :error_message, :completed_at]) ==
                 Map.take(ended, [:status, :error_message, :completed_at])

        assert attempt.() == held
        assert terminal_events(fixture) == events
        assert %{"ok" => true} = report(fixture)
      end
    end
  end

  describe "an attached request" do
    @tag :capture_log
    test "a connection the node's edge does not bind is refused before admission, naming its call id" do
      [vector] = Enum.filter(@vectors["calls"], &(&1["callback"] == "attached_fetch"))
      fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api))
      %{"v" => 1, "op" => "attached_fetch", "args" => args} = Jason.decode!(vector["body"])
      body = :attached_fetch |> WorkerWire.request_body(args) |> Jason.encode!()
      test_pid = self()

      emit = fn frame ->
        send(test_pid, {:frame, frame})
        :ok
      end

      answer =
        fixture |> AttemptFixtures.header(body) |> Crucible.Host.call(body) |> Jason.decode!()

      assert answer == %{
               "v" => 1,
               "error" => "guest_error",
               "type" => "connection_not_granted",
               "message" => Prima.Refusal.message(:connection_not_granted),
               "call_id" => args["call_id"]
             }

      # The vector's refusal is the one the host answers, and no attached
      # request is refused as anything not yet built.
      [listed] = Enum.filter(vector["refusals"], &(&1["answer"] =~ "connection_not_granted"))
      assert Jason.decode!(listed["answer"]) == answer
      refute Enum.any?(vector["refusals"], &(&1["answer"] =~ "attach_unavailable"))

      {:ok, request} = Prima.AttachedRequest.read(args)
      caller = AttemptFixtures.caller(fixture)

      assert {:error, {:guest_error, "connection_not_granted", _sentence}} =
               Crucible.Host.attached_fetch(caller, request, emit)

      refute_received {:frame, _}
      assert row(fixture).status == "running"

      # Each refusal is a recorded denial of the attempt's component, naming
      # no URL.
      {:ok, rows} = Arca.PolicyLog.list(athanor_id: fixture.athanor_id, limit: 100)
      denials = Enum.filter(rows, &(&1.component_ref == fixture.component_ref))
      assert [_, _] = denials

      for denial <- denials do
        assert denial.decision == "denied"
        assert denial.decision_reason =~ "attached: "
        refute denial.decision_reason =~ args["url"]
      end
    end

    @tag :capture_log
    test "a request-supplied policy or provenance fact does not read, and another member's is lost" do
      [vector] = Enum.filter(@vectors["calls"], &(&1["callback"] == "attached_fetch"))
      fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api))
      %{"args" => args} = Jason.decode!(vector["body"])

      # What decides is host state; a request naming a policy, a digest or
      # a node of its own is no attached request.
      for {member, value} <- [
            {"component_policy", "any"},
            {"activation_digest", "sha256:seed-openai"},
            {"node_ref", "catalyst:local.openai:1.4.0"}
          ] do
        body =
          :attached_fetch
          |> WorkerWire.request_body(Map.put(args, member, value))
          |> Jason.encode!()

        assert %{"error" => "guest_error", "type" => "invalid_request", "call_id" => id} =
                 fixture
                 |> AttemptFixtures.header(body)
                 |> Crucible.Host.call(body)
                 |> Jason.decode!()

        assert id == args["call_id"]
      end

      # A control plane that is not the member the call is addressed to
      # answers it as every host call: lost, with nothing decided.
      body = :attached_fetch |> WorkerWire.request_body(args) |> Jason.encode!()

      assert %{"v" => 1, "error" => "lost"} =
               fixture
               |> AttemptFixtures.header(body, member: "cyfr@10.0.0.9#boot_another")
               |> Crucible.Host.call(body)
               |> Jason.decode!()

      {:ok, rows} = Arca.PolicyLog.list(athanor_id: fixture.athanor_id, limit: 100)
      assert Enum.filter(rows, &(&1.component_ref == fixture.component_ref)) == []
    end

    @tag :capture_log
    test "a request carrying a credential header is refused by shape, naming its call id" do
      [vector] = Enum.filter(@vectors["calls"], &(&1["callback"] == "attached_fetch"))
      fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api))
      %{"args" => args} = Jason.decode!(vector["body"])

      for {forged, expected} <- [
            {%{args | "headers" => [["Authorization", "Bearer sk"]]},
             %{"type" => "credential_header_refused", "call_id" => args["call_id"]}},
            {%{args | "purpose" => "redirect"},
             %{"type" => "invalid_request", "call_id" => args["call_id"]}},
            {%{args | "headers" => [["Host", "evil.example"]]},
             %{
               "type" => "invalid_request",
               "call_id" => args["call_id"],
               "message" => "An attached request cannot set the Host header."
             }},
            {%{args | "headers" => [["X-Forwarded-Host", "evil.example"]]},
             %{
               "type" => "invalid_request",
               "call_id" => args["call_id"],
               "message" => "An attached request cannot set the X-Forwarded-Host header."
             }}
          ] do
        body = :attached_fetch |> WorkerWire.request_body(forged) |> Jason.encode!()

        answer =
          fixture |> AttemptFixtures.header(body) |> Crucible.Host.call(body) |> Jason.decode!()

        assert %{"v" => 1, "error" => "guest_error"} = answer
        assert Map.take(answer, Map.keys(expected)) == expected
      end

      no_call_id = Map.delete(args, "call_id")
      body = :attached_fetch |> WorkerWire.request_body(no_call_id) |> Jason.encode!()

      assert %{"v" => 1, "error" => "malformed"} =
               fixture
               |> AttemptFixtures.header(body)
               |> Crucible.Host.call(body)
               |> Jason.decode!()
    end
  end

  describe "the vectors of tests/fixtures/host_api.json" do
    @tag :capture_log
    test "every call's body reads, and its answer is written as the vector writes it" do
      calls = @vectors["calls"]

      assert Enum.map(calls, & &1["callback"]) ==
               Prima.HostAPI.callbacks()
               |> List.delete(:runner_exited)
               |> Enum.map(&Atom.to_string/1)

      for vector <- calls do
        op = vector["callback"]
        fixture = vector_fixture(op)
        %{"v" => 1, "op" => ^op, "args" => args} = Jason.decode!(vector["body"])

        body =
          op
          |> String.to_existing_atom()
          |> WorkerWire.request_body(rebound(op, args, fixture))
          |> Jason.encode!()

        before = now()
        raw = fixture |> AttemptFixtures.header(body) |> Crucible.Host.call(body)
        answer = Jason.decode!(raw)

        # The version is the answer's first member, as the vector writes it.
        # An attached request's success is its frames, never one answer.
        assert String.starts_with?(raw, ~s({"v":1,)), op

        if op == "attached_fetch",
          do: refute(Map.has_key?(vector, "answer")),
          else: assert(String.starts_with?(vector["answer"], ~s({"v":1,)), op)

        listed = for %{"answer" => refused} <- vector["refusals"], do: Jason.decode!(refused)

        case WorkerWire.read_answer(answer) do
          {:ok, _value} -> answered(op, answer, Jason.decode!(vector["answer"]), fixture, before)
          {:error, name, _fields} -> assert name in Enum.map(listed, & &1["error"]), op
        end

        assert expected(op) == answer_name(answer), op
      end
    end

    @tag :capture_log
    test "a report names its member, and one naming another member lapses nothing" do
      report = @vectors["report"]

      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), service_id: @service)

      assert %{"v" => 1, "op" => "runner_exited", "args" => args} = Jason.decode!(report["body"])
      args = %{args | "runner" => fixture.runner, "attempts" => [fixture.attempt]}

      cross = report["cross_member"]
      %{"args" => %{"member" => other}} = Jason.decode!(cross["body"])
      refute other == fixture.member

      # The report the vector's peer sends: another member than this one.
      assert Jason.decode!(~s({"v":1,"error":"#{cross["error"]}"})) ==
               report_of(fixture, %{args | "member" => other})

      assert row(fixture).status == "running"
      assert Process.alive?(fixture.pid)

      assert Jason.decode!(report["answer"]) ==
               report_of(fixture, %{args | "member" => fixture.member})

      assert {:error, "Execution terminated: runner stopped without cleanup"} =
               Dispatch.await(fixture.pid, fixture.close)
    end
  end

  describe "the connection cases of tests/fixtures/host_api.json" do
    setup do
      ctx = Sanctum.TestContext.local(:api)

      test_path =
        Path.join(System.tmp_dir!(), "host_connection_#{System.unique_integer([:positive])}")

      previous = Application.get_env(:arca, :base_path)
      Application.put_env(:arca, :base_path, test_path)
      Arca.Cache.init()

      # The registry rows this publishes are the sandbox's, but admission
      # caches what it read of them for the athanor; a later test sending
      # the vectors' reference must not find this one's.
      on_exit(fn ->
        Arca.Cache.delete_match(Arca.Cache.Keys.match_component_meta(Sanctum.Context.actor(ctx)))

        Prima.Slots.forgive_unreaped(Crucible.Slots, ctx.athanor_id)
        File.rm_rf!(test_path)

        if previous,
          do: Application.put_env(:arca, :base_path, previous),
          else: Application.delete_env(:arca, :base_path)
      end)

      wasm = File.read!(Path.expand("../support/test_wasm/math.wasm", __DIR__))

      # The formulas making the calls, and the reagent the vectors name.
      for {name, type} <- [{"connection-formula", "formula"}, {"vector", "reagent"}] do
        {:ok, _} =
          Compendium.Registry.publish_bytes(ctx, wasm, %{name: name, version: "0.1.0", type: type})
      end

      # A formula calling the one above, released apart from it: the caps
      # its manifest asks for give it its own release digest, so calling
      # the other is never a self-call.
      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, wasm, %{
          name: "connection-root",
          version: "0.1.0",
          type: "formula",
          manifest:
            Jason.encode!(%{
              "name" => "connection-root",
              "version" => "0.1.0",
              "type" => "formula",
              "description" => "calls connection-formula",
              "caps" => %{"tools" => ["execution.run"]}
            })
        })

      Cyfr.Test.Sandbox.stop_work_on_exit()
      start_supervised!({Cyfr.Test.ScriptedWorker, ref: "reagent:local.unscripted", script: []})
      {:ok, ctx: ctx}
    end

    # Each case is sent as the vector writes its args, by a formula whose
    # edge to the vectors' reagent binds no named account, and answered as
    # the vector answers it.
    @tag :capture_log
    test "the default is admitted, an account the edge lacks is refused, and the key repeated " <>
           "naming an account is invalid_request",
         %{ctx: ctx} do
      formula = "formula:local.connection-formula"
      target = "reagent:local.vector"
      limits = Prima.Test.AuthorityFixtures.limits_map()

      {:ok, blob} =
        Prima.Authority.Blob.parse(%{
          "canonical" => "jcs-1",
          "nodes" => %{
            formula => %{"limits" => limits, "edges" => %{"@ingress" => %{}, target => %{}}},
            target => %{"limits" => limits, "edges" => %{}}
          }
        })

      {:ok, authority} =
        Prima.Authority.root(
          %{
            profile_id: "prof-connection",
            consent_id: "consent-connection",
            source_ref: formula,
            kind: :owner,
            invoke_mode: :open_inert,
            activation: %{formula => Prima.Digest.sha256("connection-formula")}
          },
          blob,
          ceiling: Prima.Test.AuthorityFixtures.ceiling()
        )

      fixture =
        AttemptFixtures.attached!(
          ctx: ctx,
          authority: authority,
          component_ref: formula <> ":0.1.0",
          component_type: :formula,
          worker: Cyfr.Test.ScriptedWorker.endpoint(),
          reservation: true
        )

      cases = Map.new(@vectors["connection_cases"], &{&1["name"], &1})

      play = fn name ->
        %{"v" => 1, "op" => "admit_child", "args" => args} = Jason.decode!(cases[name]["body"])
        AttemptFixtures.call(fixture, "admit_child", args)
      end

      assert %{"v" => 1, "ok" => %{"assignment" => token}} = play.("omitted")
      {:ok, admitted} = Assignment.read(token)
      {:ok, child} = Prima.Authority.from_wire(admitted.authority)
      assert child.cursor == {:bound, target}

      for name <- ["named", "reused"] do
        assert play.(name) == Jason.decode!(cases[name]["answer"]), name
      end

      # An account the edge lacks is a grant to make, in Prima.Refusal's
      # own sentence: setup required, never a denial.
      assert %{
               "error" => "guest_error",
               "type" => "connection_not_granted",
               "message" => message
             } = play.("named")

      assert message == Prima.Refusal.message(:connection_not_granted)

      assert Prima.Refusal.classify({:guest_error, "connection_not_granted", message}).class ==
               :setup_required

      # Neither refusal admitted a child, and the key still answers the one
      # it was admitted for, with the connection it named.
      assert %{"ok" => %{"assignment" => again}} = play.("omitted")
      assert {:ok, %{execution_id: id}} = Assignment.read(again)
      assert id == admitted.execution_id
      assert [^id] = children_of(fixture)
    end

    @tag :capture_log
    test "a child admitted naming an account is answered again under its key naming it, and " <>
           "refused naming none",
         %{ctx: ctx} do
      %{root: root, target: target} = named = named_accounts!(ctx)
      fixture = connection_formula!(ctx, named.authority, root)

      args = %{
        "reference" => target <> ":0.1.0",
        "input" => %{},
        "guest_fn" => "call",
        "need" => nil,
        "child_key" => "ck_named_account",
        "connection" => "Work"
      }

      assert %{"ok" => %{"assignment" => token}} =
               AttemptFixtures.call(fixture, "admit_child", args)

      {:ok, admitted} = Assignment.read(token)
      {:ok, child} = Prima.Authority.from_wire(admitted.authority)
      assert child.resources.vault.entry_id == "vlt_work"
      assert child.resources.vault.binding_key == Blob.binding_key(root, target, "Work")

      # The same account under the key is the same child.
      assert %{"ok" => %{"assignment" => again}} =
               AttemptFixtures.call(fixture, "admit_child", args)

      assert {:ok, %{execution_id: id}} = Assignment.read(again)
      assert id == admitted.execution_id

      # Naming none under it asks for the edge's default, which is not the
      # account the child holds.
      assert %{"error" => "guest_error", "type" => "invalid_request", "message" => message} =
               AttemptFixtures.call(fixture, "admit_child", Map.delete(args, "connection"))

      assert message =~ "child_key"
      assert [^id] = children_of(fixture)
    end

    @tag :capture_log
    test "a self-call names no account, so its retry under its key is answered though its " <>
           "caller holds a named one",
         %{ctx: ctx} do
      %{root: root, target: target} = named = named_accounts!(ctx)

      # The caller is the edge's child holding the account Work.
      {:child, caller} =
        Prima.Authority.Transition.step(
          named.authority,
          :call,
          {:invoke,
           %{
             reference: target,
             need: nil,
             activation_digest: named.digests[target],
             declared_needs: [],
             connection: "Work"
           }}
        )

      assert caller.resources.vault.binding_key == Blob.binding_key(root, target, "Work")
      fixture = connection_formula!(ctx, caller, target)

      args = %{
        "reference" => target <> ":0.1.0",
        "input" => %{},
        "guest_fn" => "call",
        "need" => nil,
        "child_key" => "ck_self_call"
      }

      # The self-child holds its caller's own binding, the account Work.
      assert %{"ok" => %{"assignment" => token}} =
               AttemptFixtures.call(fixture, "admit_child", args)

      {:ok, admitted} = Assignment.read(token)
      {:ok, self_child} = Prima.Authority.from_wire(admitted.authority)
      assert self_child.cursor == caller.cursor
      assert self_child.resources.vault.binding_key == caller.resources.vault.binding_key

      # A lost answer's retry names nothing, as the call did, and is answered.
      assert %{"ok" => %{"assignment" => again}} =
               AttemptFixtures.call(fixture, "admit_child", args)

      assert {:ok, %{execution_id: id}} = Assignment.read(again)
      assert id == admitted.execution_id

      # A self-call crosses no edge, so naming an account picks none.
      assert %{"error" => "guest_error", "type" => "connection_not_granted"} =
               AttemptFixtures.call(
                 fixture,
                 "admit_child",
                 Map.merge(args, %{"child_key" => "ck_self_named", "connection" => "Work"})
               )

      assert [^id] = children_of(fixture)
    end
  end

  # The children of `fixture`'s execution, by id.
  defp children_of(fixture) do
    import Ecto.Query, only: [from: 2]

    Arca.Repo.all(
      from(e in Arca.Schemas.Execution,
        where: e.parent_execution_id == ^fixture.execution_id,
        select: e.id
      )
    )
  end

  # A root authority at `formula:local.connection-root`, pinned to a live
  # profile's head, whose edge to `formula:local.connection-formula` binds
  # a default and, beside it, the account Work. Both name only scopes, so
  # a child holding either is claimed without reading an entry.
  defp named_accounts!(ctx) do
    root = "formula:local.connection-root"
    target = "formula:local.connection-formula"

    {pinned, _entry} =
      AttemptFixtures.vault_authority!(ctx, %{kind: "api_key", fields: %{"KEY" => "k"}})

    digests =
      Map.new([root, target], fn node ->
        {:ok, _ref, _type, component} =
          Crucible.Admission.inspect_component(ctx, node <> ":0.1.0")

        {node, component["release_digest"]}
      end)

    refute digests[root] == digests[target]

    bound = fn entry_id, opts ->
      Prima.Test.AuthorityFixtures.bound_vault(
        root,
        target,
        entry_id,
        "sha256:bind-" <> entry_id,
        [projection: %{"scopes" => ["fixture.scope"]}] ++ opts
      )
    end

    vault = bound.("vlt_default", named: %{"Work" => bound.("vlt_work", name: "Work")})
    limits = Prima.Test.AuthorityFixtures.limits_map()

    {:ok, blob} =
      Blob.parse(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          root => %{
            "limits" => limits,
            "edges" => %{"@ingress" => %{}, target => %{"vault" => vault}}
          },
          target => %{"limits" => limits, "edges" => %{}}
        }
      })

    {:ok, authority} =
      Prima.Authority.root(
        %{
          profile_id: pinned.profile_id,
          consent_id: pinned.consent_id,
          source_ref: root,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: digests
        },
        blob,
        ceiling: Prima.Test.AuthorityFixtures.ceiling()
      )

    %{authority: authority, root: root, target: target, digests: digests}
  end

  # An attached attempt of the formula `node` under `authority`, whose
  # children are claimed for its runner.
  defp connection_formula!(ctx, authority, node) do
    AttemptFixtures.attached!(
      ctx: ctx,
      authority: authority,
      component_ref: node <> ":0.1.0",
      component_type: :formula,
      worker: Cyfr.Test.ScriptedWorker.endpoint(),
      reservation: true
    )
  end

  # A live attempt for the vector of `op`: attached, and holding what the
  # vector's answer needs where that is cheap to hold (its vault field, a
  # rate of one request).
  defp vector_fixture("attach") do
    AttemptFixtures.attached!(
      ctx: Sanctum.TestContext.local(:api),
      attach: false,
      vault: %{kind: "api_key", fields: %{"API_KEY" => "vector-secret-value"}}
    )
  end

  defp vector_fixture("take_rate") do
    limits = %{Prima.Limits.defaults(:catalyst) | rate_limit: %{requests: 1, window: "1m"}}
    AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), limits: limits)
  end

  # A pin's host must be in the edge's egress domains.
  defp vector_fixture("egress_pin") do
    egress = %{domains: ["*"], methods: [], schemes: [], private_ips: []}

    AttemptFixtures.attached!(
      ctx: Sanctum.TestContext.local(:api),
      authority: %{Prima.Authority.zero() | resources: %Prima.Authority.Blob.Edge{egress: egress}}
    )
  end

  defp vector_fixture(_op), do: AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api))

  # The vector's args, with the attempt and the execution they name bound to
  # the live attempt's.
  defp rebound("attach", _args, fixture), do: %{"assignment" => fixture.assignment}
  defp rebound("renew", _args, fixture), do: %{"attempts" => [fixture.attempt, "att_other"]}

  defp rebound(op, %{"outcome" => outcome}, fixture) when op in ["complete", "fail"],
    do: %{"outcome" => Map.merge(outcome, names_of(fixture))}

  defp rebound("push_deltas", %{"deltas" => deltas}, fixture),
    do: %{"deltas" => Enum.map(deltas, &Map.merge(&1, names_of(fixture)))}

  defp rebound("take_rate", _args, fixture), do: %{"bucket" => "http:" <> fixture.component_ref}

  # The address the vector's host resolves to, as a literal, so the pin
  # resolves nothing on the network (`Crucible.Host.EgressTest` resolves
  # the vectors' names through a scripted resolver).
  defp rebound("egress_pin", %{"url" => url} = args, _fixture) do
    %{"ok" => %{"ip" => ip}} = egress_answer()
    %{args | "url" => URI.to_string(%{URI.parse(url) | host: ip})}
  end

  defp rebound(_op, args, _fixture), do: args

  defp names_of(fixture) do
    %{
      "execution_id" => fixture.execution_id,
      "attempt" => fixture.attempt,
      "fence" => fixture.fence
    }
  end

  # What a live attempt holding nothing more answers each call: the
  # vector's success where the attempt can give it, and otherwise the
  # refusal of a resource it does not hold, which the vector lists.
  defp expected(op)
       when op in ~w(attach renew complete fail push_deltas take_rate record_denial egress_pin),
       do: "ok"

  defp expected("fetch_artifact"), do: "not_found"
  defp expected("release_child"), do: "lost"

  defp expected(op) when op in ~w(oauth_token storage admit_child tool_call attached_fetch),
    do: "guest_error"

  defp answer_name(%{"ok" => _value}), do: "ok"
  defp answer_name(%{"error" => name}), do: name

  defp answered(op, answer, vector, _fixture, _before)
       when op in ~w(attach complete take_rate record_denial),
       do: assert(answer == vector, op)

  defp answered("renew", %{"ok" => renewals}, %{"ok" => wire}, fixture, _before) do
    assert [%{"lease_until" => _}, "lost"] = wire |> Map.values() |> Enum.sort_by(&is_binary/1)
    assert %{"lease_until" => until} = renewals[fixture.attempt]
    assert is_integer(until) and renewals["att_other"] == "lost"
  end

  defp answered("fail", %{"ok" => message}, %{"ok" => wire}, _fixture, _before),
    do: assert(message == wire)

  defp answered("push_deltas", %{"ok" => [reply]}, %{"ok" => [wire]}, _fixture, _before) do
    assert %{"ok" => true, "sequence" => _} = Jason.decode!(reply)
    assert Map.keys(Jason.decode!(reply)) == Map.keys(Jason.decode!(wire))
  end

  defp answered("egress_pin", %{"ok" => pin}, %{"ok" => wire}, _fixture, before) do
    assert {:ok, %PinnedTarget{} = read} = PinnedTarget.read(pin)
    assert pin["host"] == wire["ip"]

    assert Map.drop(pin, ["id", "expires_at", "host"]) ==
             Map.drop(wire, ["id", "expires_at", "host"])

    window = Prima.WorkerAuth.window_ms()
    assert read.expires_at >= before + window and read.expires_at <= now() + window
  end

  defp egress_answer do
    [vector] = Enum.filter(@vectors["calls"], &(&1["callback"] == "egress_pin"))
    Jason.decode!(vector["answer"])
  end

  defp report_of(fixture, args) do
    body = :runner_exited |> WorkerWire.request_body(args) |> Jason.encode!()
    fields = %{service: fixture.service, boot: fixture.boot, ts: now(), nonce: "n_report"}
    {:ok, header} = Prima.WorkerAuth.report_header(dispatch_key(fixture.service), fields, body)
    header |> Crucible.Host.runner_exited(body) |> Jason.decode!()
  end

  defp terminal_events(fixture) do
    {:ok, rows} =
      Arca.ExecutionEvents.since(
        Prima.Actor.in_athanor(fixture.athanor_id),
        fixture.execution_id,
        0
      )

    for %{type: type} <- rows, type in Arca.ExecutionEvents.terminal_types(), do: type
  end

  defp delta(fixture, text),
    do: AttemptFixtures.delta(fixture, Jason.encode!(%{"type" => "note", "text" => text}))

  defp now, do: System.system_time(:millisecond)

  defp move_head!(profile) do
    Arca.ProfileStorage.advance_head(
      Prima.Actor.in_athanor(profile.athanor_id),
      profile.id,
      profile.head_consent_id,
      Prima.UUID7.generate_id("cons")
    )
  end

  defp child_of!(fixture) do
    {:ok, %{execution: child}} =
      Arca.Execution.admit(
        %{
          id: Prima.UUID7.execution_id(),
          reference: "reagent:local.child:0.1.0",
          user_id: fixture.ctx.user_id,
          athanor_id: fixture.athanor_id,
          component_type: "reagent",
          parent_execution_id: fixture.execution_id,
          root_execution_id: fixture.execution_id
        },
        Cyfr.Test.AttemptFixtures.standing(fixture.athanor_id)
      )

    child.id
  end
end
