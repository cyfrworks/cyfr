# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.HostListenerTest do
  @moduledoc """
  A runner's host calls and a worker service's reports reach
  `Cyfr.Execution.Host` over HTTP through one listener of CYFR's own, and
  the listener refuses what the header alone disproves before it reads
  the body: a wrong key, another worker service, a stale generation, a
  reused nonce, a body that is not the header's, a body over the bound, a
  boot that does not hold the control plane, and a route that is no host
  route. Nothing refused leaves a claim, an event or a terminal row, and
  the answer of a call that passes is the JSON `Host` produces.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cyfr.Execution.{Attempt, Dispatch, HostListener, Keys}
  alias Cyfr.Test.AttemptFixtures
  alias Cyfr.{WorkerAuth, WorkerWire}

  @service "wrk_listener_test"
  @auth WorkerWire.auth_header()

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    listener = start_supervised!({HostListener, port: 0})
    {:ok, url: "http://127.0.0.1:#{HostListener.port(listener)}"}
  end

  # One request to `path` on the listener at `url`, with the auth headers
  # given (none, one or several) and `body`, answered as its status and
  # decoded JSON.
  defp post(url, path, headers, body, opts \\ []) do
    response =
      Req.request!(
        url: url <> path,
        method: Keyword.get(opts, :method, :post),
        headers: Enum.map(headers, &{@auth, &1}),
        body: body,
        retry: false,
        decode_body: false
      )

    {response.status, Jason.decode!(response.body)}
  end

  # A signed host call of `op` for `fixture`, posted to `op`'s route.
  # `opts` are `Cyfr.Test.AttemptFixtures.header/3`'s, plus `:body` to
  # post another body than the one signed and `:path` for another route.
  defp call(url, fixture, op, args, opts \\ []) do
    signed = AttemptFixtures.body(op, args)
    header = AttemptFixtures.header(fixture, signed, opts)
    path = Keyword.get_lazy(opts, :path, fn -> WorkerWire.host_route(String.to_atom(op)) end)
    post(url, path, [header], Keyword.get(opts, :body, signed))
  end

  defp attach(url, fixture, opts \\ []),
    do: call(url, fixture, "attach", %{"assignment" => fixture.assignment}, opts)

  defp push(url, fixture, text, opts \\ []) do
    event = Jason.encode!(%{"type" => "note", "text" => text})

    call(
      url,
      fixture,
      "push_deltas",
      %{"deltas" => [AttemptFixtures.delta(fixture, event)]},
      opts
    )
  end

  defp renew(url, fixture, opts \\ []),
    do: call(url, fixture, "renew", %{"attempts" => [fixture.attempt]}, opts)

  # A report of the exit of `fixture`'s runner, signed with the dispatch
  # key of the service it names, or of `:signer`.
  defp report(url, fixture, opts \\ []) do
    body =
      AttemptFixtures.body("runner_exited", %{
        "runner" => fixture.runner,
        "attempts" => [fixture.attempt]
      })

    fields = %{
      service: fixture.service,
      boot: fixture.boot,
      ts: now(),
      nonce: "n_#{System.unique_integer([:positive])}"
    }

    {:ok, header} =
      WorkerAuth.report_header(dispatch_key(opts[:signer] || @service), fields, body)

    post(url, WorkerWire.host_route(:runner_exited), [header], body)
  end

  defp dispatch_key(service) do
    {:ok, worker_key} = Keys.worker_key(service)
    WorkerAuth.dispatch_key(worker_key)
  end

  defp claimed_by(fixture),
    do: Arca.Repo.get!(Arca.Schemas.ExecutionAttempt, fixture.attempt).claimed_by

  defp row(fixture), do: Arca.Repo.get!(Arca.Execution, fixture.execution_id)

  defp live_events do
    receive do
      {:execution_event, event} -> [event | live_events()]
    after
      200 -> []
    end
  end

  defp now, do: System.system_time(:millisecond)

  describe "a call that passes" do
    test "reaches Host, which answers as it does in process", %{url: url} do
      fixture =
        AttemptFixtures.attached!(
          attach: false,
          service_id: @service,
          vault: %{kind: "api_key", fields: %{"KEY" => "sk-fixture"}}
        )

      :ok = Cyfr.Execution.Events.subscribe(fixture.execution_id, fixture.ctx)

      assert {200, %{"ok" => %{"KEY" => "sk-fixture"}}} = attach(url, fixture)
      assert claimed_by(fixture) == fixture.runner

      assert {200, %{"ok" => %{} = renewals}} = renew(url, fixture)
      assert %{"lease_until" => _} = renewals[fixture.attempt]

      assert {200, %{"ok" => [_reply]}} = push(url, fixture, "over the wire")
      assert [%{type: "emit", data: %{"text" => "over the wire"}}] = live_events()

      outcome = AttemptFixtures.outcome(fixture, "completed", %{"output" => %{"said" => "done"}})

      assert {200, %{"ok" => %{"said" => "done"}}} =
               call(url, fixture, "complete", %{"outcome" => outcome})

      assert {:ok, %{status: :completed}} = Dispatch.await(fixture.pid, fixture.close)
    end

    @tag :capture_log
    test "a refusal Host answers is an answer, not a transport failure", %{url: url} do
      fixture = AttemptFixtures.attached!(attach: false, service_id: @service)
      {:ok, other} = Keys.attempt_keys(%{fixture.keys.attempt | service: "wrk_other"})

      # The boot is signed beside the service but is no key input: the
      # header verifies, and the row's boot is what refuses it, in Host. A
      # header naming another worker service, signed under that service's
      # key, verifies as that service's; the assignment's service refuses
      # it, in Host.
      assert {200, %{"error" => "lost"}} = attach(url, fixture, boot: "boot_other")

      assert {200, %{"error" => "lost"}} =
               attach(url, fixture, service: "wrk_other", call_key: other.call)

      assert claimed_by(fixture) == nil
      assert {200, %{"ok" => _}} = attach(url, fixture)
    end

    test "a report lapses the reporting service's attempts", %{url: url} do
      fixture = AttemptFixtures.attached!(service_id: @service)

      assert {200, %{"ok" => true}} = report(url, fixture)

      assert {:error, "Execution terminated: runner stopped without cleanup"} =
               Dispatch.await(fixture.pid, fixture.close)

      assert %{state: "lapsed"} = Arca.ExecutionAttempts.get(fixture.athanor_id, fixture.attempt)
    end
  end

  describe "refused by the header, before the body is read" do
    @tag :capture_log
    test "a wrong key, another service's key for this attempt, or a stale generation", %{
      url: url
    } do
      fixture = AttemptFixtures.attached!(attach: false, service_id: @service)
      {:ok, other} = Keys.attempt_keys(%{fixture.keys.attempt | service: "wrk_other"})

      {:ok, stale} =
        Keys.attempt_keys(%{fixture.keys.attempt | generation: fixture.generation + 1})

      log =
        capture_log(fn ->
          assert {401, %{"error" => "lost"}} =
                   attach(url, fixture, call_key: :crypto.strong_rand_bytes(32))

          assert {401, %{"error" => "lost"}} = attach(url, fixture, call_key: fixture.keys.seal)

          assert {401, %{"error" => "lost"}} = attach(url, fixture, call_key: other.call)

          assert {401, %{"error" => "lost"}} =
                   attach(url, fixture,
                     generation: fixture.generation + 1,
                     call_key: stale.call
                   )

          assert {401, %{"error" => "lost"}} = attach(url, fixture, ts: now() - 60_000)
        end)

      assert log =~ "bad_mac"
      assert log =~ "generation_mismatch"
      assert log =~ "outside_window"
      assert claimed_by(fixture) == nil
      assert {200, %{"ok" => _}} = attach(url, fixture)
    end

    @tag :capture_log
    test "no header, or more than one", %{url: url} do
      fixture = AttemptFixtures.attached!(attach: false, service_id: @service)
      body = AttemptFixtures.body("attach", %{"assignment" => fixture.assignment})
      header = AttemptFixtures.header(fixture, body)
      path = WorkerWire.host_route(:attach)

      assert {401, %{"error" => "lost"}} = post(url, path, [], body)
      assert {401, %{"error" => "lost"}} = post(url, path, [header, header], body)
      assert claimed_by(fixture) == nil
    end

    @tag :capture_log
    test "a reused nonce on a call that is not idempotent; an idempotent one repeats", %{url: url} do
      fixture = AttemptFixtures.attached!(service_id: @service)
      :ok = Cyfr.Execution.Events.subscribe(fixture.execution_id, fixture.ctx)

      body =
        AttemptFixtures.body("push_deltas", %{
          "deltas" => [AttemptFixtures.delta(fixture, ~s({"type":"note","text":"once"}))]
        })

      header = AttemptFixtures.header(fixture, body)
      path = WorkerWire.host_route(:push_deltas)

      assert {200, %{"ok" => [_reply]}} = post(url, path, [header], body)

      assert capture_log(fn ->
               assert {401, %{"error" => "lost"}} = post(url, path, [header], body)
             end) =~ "presented before"

      assert [%{type: "emit", data: %{"text" => "once"}}] = live_events()

      renew_body = AttemptFixtures.body("renew", %{"attempts" => [fixture.attempt]})
      renew_header = AttemptFixtures.header(fixture, renew_body)
      renew_path = WorkerWire.host_route(:renew)

      assert {200, %{"ok" => %{}}} = post(url, renew_path, [renew_header], renew_body)
      assert {200, %{"ok" => %{}}} = post(url, renew_path, [renew_header], renew_body)
      assert Process.alive?(fixture.pid)
    end

    @tag :capture_log
    test "a report signed by another worker service, or with the assign key", %{url: url} do
      fixture = AttemptFixtures.attached!(service_id: @service)

      assert {401, %{"error" => "lost"}} = report(url, fixture, signer: "wrk_other")

      body =
        AttemptFixtures.body("runner_exited", %{
          "runner" => fixture.runner,
          "attempts" => [fixture.attempt]
        })

      fields = %{service: @service, boot: fixture.boot, ts: now(), nonce: "n_forged"}
      {:ok, forged} = WorkerAuth.report_header(Keys.assign_key(), fields, body)

      assert {401, %{"error" => "lost"}} =
               post(url, WorkerWire.host_route(:runner_exited), [forged], body)

      assert %{state: "running"} = Arca.ExecutionAttempts.get(fixture.athanor_id, fixture.attempt)
      assert Process.alive?(fixture.pid)
      Attempt.refuse(fixture.pid, "not started")
    end

    @tag :capture_log
    test "a boot that does not hold the control plane refuses every route", %{url: url} do
      fixture = AttemptFixtures.attached!(attach: false, service_id: @service)
      on_exit(fn -> Cyfr.ControlPlane.mark(:unclaimed) end)
      Cyfr.ControlPlane.mark(:lost)

      assert {503, %{"error" => "lost"}} = attach(url, fixture)
      assert {503, %{"error" => "unavailable"}} = report(url, fixture)

      assert claimed_by(fixture) == nil
      assert %{status: "running"} = row(fixture)
      assert %{state: "running"} = Arca.ExecutionAttempts.get(fixture.athanor_id, fixture.attempt)
    end
  end

  describe "refused by the body" do
    @tag :capture_log
    test "a body that is not the one the header names is refused, and nothing of it is logged", %{
      url: url
    } do
      fixture = AttemptFixtures.attached!(service_id: @service)
      :ok = Cyfr.Execution.Events.subscribe(fixture.execution_id, fixture.ctx)

      tampered =
        AttemptFixtures.body("push_deltas", %{
          "deltas" => [AttemptFixtures.delta(fixture, ~s({"type":"note","text":"sk-canary"}))]
        })

      log =
        capture_log(fn ->
          assert {401, %{"error" => "lost"}} = push(url, fixture, "signed", body: tampered)
        end)

      assert log =~ "not the header's"
      refute log =~ "sk-canary"
      assert live_events() == []
      assert Process.alive?(fixture.pid)
    end

    @tag :capture_log
    test "a body over the bound is refused by its declared length, or as it streams past the bound",
         %{url: url} do
      fixture = AttemptFixtures.attached!(service_id: @service)
      :ok = Cyfr.Execution.Events.subscribe(fixture.execution_id, fixture.ctx)
      max = Cyfr.HostAPI.max_body_bytes()
      text = String.duplicate("x", max)

      body =
        AttemptFixtures.body("push_deltas", %{
          "deltas" => [
            AttemptFixtures.delta(fixture, Jason.encode!(%{"type" => "note", "text" => text}))
          ]
        })

      assert byte_size(body) > max
      header = AttemptFixtures.header(fixture, body)
      path = WorkerWire.host_route(:push_deltas)

      assert {413, %{"error" => "lost"}} = post(url, path, [header], body)

      # A refused request's nonce was presented all the same; the streamed
      # repeat is a new call.
      header = AttemptFixtures.header(fixture, body)
      chunks = for <<chunk::binary-size(65_536) <- body>>, do: chunk

      rest =
        binary_part(
          body,
          byte_size(body) - rem(byte_size(body), 65_536),
          rem(byte_size(body), 65_536)
        )

      assert {413, %{"error" => "lost"}} =
               post(url, path, [header], Stream.concat(chunks, [rest]))

      assert live_events() == []
      assert Process.alive?(fixture.pid)
    end

    @tag :capture_log
    test "a body naming another operation than its route", %{url: url} do
      fixture = AttemptFixtures.attached!(service_id: @service)
      outcome = AttemptFixtures.outcome(fixture, "completed", %{"output" => %{}})

      assert {400, %{"error" => "malformed"}} =
               call(url, fixture, "complete", %{"outcome" => outcome},
                 path: WorkerWire.host_route(:renew)
               )

      assert %{status: "running"} = row(fixture)
      assert Process.alive?(fixture.pid)
    end
  end

  describe "a route that is no host route" do
    test "is not found, whatever it carries", %{url: url} do
      fixture = AttemptFixtures.attached!(attach: false, service_id: @service)
      body = AttemptFixtures.body("attach", %{"assignment" => fixture.assignment})
      header = AttemptFixtures.header(fixture, body)

      assert {404, %{"error" => "not_found"}} = post(url, "/host/v1/nope", [header], body)

      assert {404, %{"error" => "not_found"}} =
               post(url, WorkerWire.worker_route(:start), [header], body)

      assert {404, %{"error" => "not_found"}} =
               post(url, WorkerWire.host_route(:attach), [header], body, method: :get)

      assert claimed_by(fixture) == nil
    end
  end
end
