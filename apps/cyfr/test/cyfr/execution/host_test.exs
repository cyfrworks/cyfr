# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.HostTest do
  @moduledoc """
  A runner reaches its attempt only through host calls, and each call is
  checked before it acts: the header's MAC under the attempt key, its
  generation and its window; at attach, the assignment's MAC, its claim
  deadline, that it names the header's attempt, and the claim on the row;
  on every other call, a nonce not presented before and a row still held
  by the calling runner. Anything that fails answers `lost`, or the
  specific refusal attach names.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait
  import ExUnit.CaptureLog

  alias Cyfr.Assignment
  alias Cyfr.Execution.{Attempt, Close, Keys}
  alias Cyfr.Test.AttemptFixtures

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

  defp renew(fixture, attempts \\ nil),
    do: AttemptFixtures.call(fixture, "renew", %{"attempts" => attempts || [fixture.attempt]})

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
               Attempt.await(fixture.pid, fixture.close)

      assert row(fixture).status == "failed"
    end
  end

  describe "every call" do
    test "a header signed with another key is lost" do
      fixture = AttemptFixtures.attached!()

      log =
        capture_log(fn ->
          assert %{"error" => "lost"} = renew(%{fixture | key: :crypto.strong_rand_bytes(32)})

          assert %{"error" => "lost"} =
                   push(fixture, %{"type" => "note"}, key: :crypto.strong_rand_bytes(32))
        end)

      assert log =~ "bad_mac"
    end

    test "a header from another generation is refused, though signed with that generation's key" do
      fixture = AttemptFixtures.attached!()
      generation = fixture.generation + 1
      {:ok, key} = Keys.attempt_key(%{fixture | generation: generation})
      opts = [generation: generation, key: key]

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
               Attempt.await(fixture.pid, fixture.close)

      assert row(fixture).status == "completed"
    end

    test "fail closes the row failed with the masked error" do
      fixture =
        AttemptFixtures.attached!(vault: %{kind: "api_key", fields: %{"KEY" => "sk-fixture"}})

      outcome = AttemptFixtures.outcome(fixture, "failed", %{"error" => "saw sk-fixture"})
      assert %{"ok" => true} = AttemptFixtures.call(fixture, "fail", %{"outcome" => outcome})
      assert {:error, "saw [REDACTED]"} = Attempt.await(fixture.pid, fixture.close)
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
      assert {:ok, _} = Attempt.await(fixture.pid, fixture.close)

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
          runner_id: Cyfr.Boot.id(),
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
               Attempt.await(fixture.pid, fixture.close)

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

      fixture =
        Map.merge(AttemptFixtures.current!(ctx.athanor_id, execution.id), %{
          runner: attempt.runner_id
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
      assert {:ok, _result} = Attempt.await(fixture.pid, fixture.close)

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
