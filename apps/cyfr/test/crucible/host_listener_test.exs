# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.HostListenerTest do
  @moduledoc """
  A runner's host calls and a worker service's reports reach
  `Crucible.Host` over HTTP through one listener of CYFR's own, and
  the listener refuses what the header alone disproves before it reads
  the body: a wrong key, another worker service, a stale generation, a
  reused nonce, a runner other than the one the attempt row is claimed by
  on any call but the attach that claims it, a body that is not the
  header's, a body over the bound, a boot that does not hold the control
  plane, and a route that is no host route. A host call's body and answer cross sealed under the attempt's
  seal key, as the call the header names; a body that does not open so is
  refused. Nothing refused leaves a claim, an event or a terminal row, and
  the answer of a call that passes is the JSON `Host` produces.

  Every `pre_body_refusals` vector of `tests/fixtures/host_api.json` is
  answered at its status, in the documented order, on a connection the
  listener closes without reading the body; every `body_refusals` vector
  is refused, once opened, with the error it names.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Crucible.{Attempt, Dispatch, HostListener, Keys}
  alias Cyfr.Test.AttemptFixtures
  alias Prima.{WorkerAuth, WorkerWire}

  @service "wrk_listener_test"
  @auth WorkerWire.auth_header()

  @vectors_path Path.expand("../../../../tests/fixtures/host_api.json", __DIR__)
  @external_resource @vectors_path
  @vectors @vectors_path |> File.read!() |> Jason.decode!()

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    listener = start_supervised!({HostListener, port: 0})
    {:ok, listener: listener, url: "http://127.0.0.1:#{HostListener.port(listener)}"}
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

    if Keyword.get(opts, :raw, false),
      do: {response.status, response.body},
      else: {response.status, Jason.decode!(response.body)}
  end

  # A sealed, signed host call of `op` for `fixture`, posted to `op`'s
  # route, its answer opened. `opts` are `Cyfr.Test.AttemptFixtures.header/3`'s
  # header overrides, plus `:seal_key` (default the fixture's), `:sealed_as`
  # (the header fields the body is sealed for, default the call's own),
  # `:body` to post another body than the one signed and `:path` for
  # another route.
  defp call(url, fixture, op, args, opts \\ []) do
    fields = fields(fixture, opts)
    seal_key = Keyword.get(opts, :seal_key, fixture.keys.seal)
    json = AttemptFixtures.body(op, args)

    {:ok, sealed} =
      WorkerAuth.seal_call(seal_key, :body, Keyword.get(opts, :sealed_as, fields), json)

    key = Keyword.get(opts, :call_key, fixture.call_key)
    {:ok, header} = WorkerAuth.host_call_header(key, fields, sealed)
    path = Keyword.get_lazy(opts, :path, fn -> WorkerWire.host_route(String.to_atom(op)) end)

    {status, answer} = post(url, path, [header], Keyword.get(opts, :body, sealed), raw: true)
    {status, open_answer(seal_key, fields, answer)}
  end

  # An answer opens as the `:answer` of the call it was sealed for; a
  # listener refusal is plain JSON.
  defp open_answer(seal_key, fields, answer) do
    case WorkerAuth.open_call(seal_key, :answer, fields, answer) do
      {:ok, json} -> Jason.decode!(json)
      {:error, :unsealable} -> Jason.decode!(answer)
    end
  end

  # A host call's header fields for `fixture`, with `opts` overriding them
  # as `Cyfr.Test.AttemptFixtures.header/3` takes them.
  defp fields(fixture, opts) do
    %{
      athanor_id: fixture.athanor_id,
      execution_id: fixture.execution_id,
      attempt: fixture.attempt,
      fence: Keyword.get(opts, :fence, fixture.fence),
      generation: Keyword.get(opts, :generation, fixture.generation),
      service: Keyword.get(opts, :service, fixture.service),
      boot: Keyword.get(opts, :boot, fixture.boot),
      runner: Keyword.get(opts, :runner, fixture.runner),
      member: Keyword.get(opts, :member, fixture.member),
      ts: Keyword.get_lazy(opts, :ts, &now/0),
      nonce: Keyword.get_lazy(opts, :nonce, fn -> "n_#{System.unique_integer([:positive])}" end)
    }
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
        "member" => fixture.member,
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
    {:ok, worker_key} = Keys.opus_key(service)
    WorkerAuth.dispatch_key(worker_key)
  end

  defp claimed_by(fixture),
    do: Arca.Repo.get!(Arca.Schemas.ExecutionAttempt, fixture.attempt).claimed_by

  defp row(fixture), do: Arca.Repo.get!(Arca.Schemas.Execution, fixture.execution_id)

  defp live_events do
    receive do
      %Cyfr.Bus.ExecutionEvent{} = event -> [Cyfr.Bus.ExecutionEvent.event(event) | live_events()]
    after
      200 -> []
    end
  end

  defp now, do: System.system_time(:millisecond)

  describe "a call that passes" do
    test "reaches Host, which answers as it does in process", %{url: url} do
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          attach: false,
          service_id: @service,
          vault: %{kind: "api_key", fields: %{"KEY" => "sk-fixture"}}
        )

      :ok = Crucible.Events.subscribe(fixture.execution_id, fixture.ctx)

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
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          attach: false,
          service_id: @service
        )

      {:ok, other} = Keys.attempt_keys(%{fixture.keys.attempt | service: "wrk_other"})

      # The boot is signed beside the service but is no key input: the
      # header verifies, and the row's boot is what refuses it, in Host. A
      # header naming another worker service, signed under that service's
      # key, verifies as that service's; the assignment's service refuses
      # it, in Host.
      assert {200, %{"error" => "lost"}} = attach(url, fixture, boot: "boot_other")

      assert {200, %{"error" => "lost"}} =
               attach(url, fixture,
                 service: "wrk_other",
                 call_key: other.call,
                 seal_key: other.seal
               )

      assert claimed_by(fixture) == nil
      assert {200, %{"ok" => _}} = attach(url, fixture)
    end

    # An admitted attached request's frames stream as a chunked answer
    # (`Crucible.Host.AttachedFetchTest`, against a loopback upstream);
    # one refused before its admission is an ordinary sealed answer.
    @tag :capture_log
    test "an attached request refused before admission is one sealed answer naming its call id",
         %{url: url} do
      [vector] = Enum.filter(@vectors["calls"], &(&1["callback"] == "attached_fetch"))
      %{"args" => args} = Jason.decode!(vector["body"])

      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), service_id: @service)

      assert {200, answer} = call(url, fixture, "attached_fetch", args)

      assert answer == %{
               "v" => 1,
               "error" => "guest_error",
               "type" => "connection_not_granted",
               "message" => Prima.Refusal.message(:connection_not_granted),
               "call_id" => args["call_id"]
             }

      assert row(fixture).status == "running"
    end

    test "a report lapses the reporting service's attempts", %{url: url} do
      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), service_id: @service)

      assert {200, %{"ok" => true}} = report(url, fixture)

      assert {:error, "Execution terminated: runner stopped without cleanup"} =
               Dispatch.await(fixture.pid, fixture.close)

      assert %{state: "lapsed"} =
               Arca.ExecutionAttempts.get(
                 Prima.Actor.in_athanor(fixture.athanor_id),
                 fixture.attempt
               )
    end
  end

  describe "refused by the header, before the body is read" do
    @tag :capture_log
    test "a wrong key, another service's key for this attempt, or a stale generation", %{
      url: url
    } do
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          attach: false,
          service_id: @service
        )

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
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          attach: false,
          service_id: @service
        )

      fields = fields(fixture, [])
      json = AttemptFixtures.body("attach", %{"assignment" => fixture.assignment})
      {:ok, body} = WorkerAuth.seal_call(fixture.keys.seal, :body, fields, json)
      {:ok, header} = WorkerAuth.host_call_header(fixture.call_key, fields, body)
      path = WorkerWire.host_route(:attach)

      assert {401, %{"error" => "lost"}} = post(url, path, [], body)
      assert {401, %{"error" => "lost"}} = post(url, path, [header, header], body)
      assert claimed_by(fixture) == nil
    end

    @tag :capture_log
    test "a reused nonce on a call that is not idempotent; an idempotent one repeats", %{url: url} do
      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), service_id: @service)

      :ok = Crucible.Events.subscribe(fixture.execution_id, fixture.ctx)

      nonce = "n_reused"
      delta = AttemptFixtures.delta(fixture, ~s({"type":"note","text":"once"}))

      assert {200, %{"ok" => [_reply]}} =
               call(url, fixture, "push_deltas", %{"deltas" => [delta]}, nonce: nonce)

      assert capture_log(fn ->
               assert {401, %{"error" => "lost"}} =
                        call(url, fixture, "push_deltas", %{"deltas" => [delta]}, nonce: nonce)
             end) =~ "presented before"

      assert [%{type: "emit", data: %{"text" => "once"}}] = live_events()

      assert {200, %{"ok" => %{}}} = renew(url, fixture, nonce: nonce)
      assert {200, %{"ok" => %{}}} = renew(url, fixture, nonce: nonce)
      assert Process.alive?(fixture.pid)
    end

    @tag :capture_log
    test "a report signed by another worker service, or with the assign key", %{url: url} do
      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), service_id: @service)

      assert {401, %{"error" => "lost"}} = report(url, fixture, signer: "wrk_other")

      body =
        AttemptFixtures.body("runner_exited", %{
          "member" => fixture.member,
          "runner" => fixture.runner,
          "attempts" => [fixture.attempt]
        })

      fields = %{service: @service, boot: fixture.boot, ts: now(), nonce: "n_forged"}
      {:ok, forged} = WorkerAuth.report_header(Keys.assign_key(), fields, body)

      assert {401, %{"error" => "lost"}} =
               post(url, WorkerWire.host_route(:runner_exited), [forged], body)

      assert %{state: "running"} =
               Arca.ExecutionAttempts.get(
                 Prima.Actor.in_athanor(fixture.athanor_id),
                 fixture.attempt
               )

      assert Process.alive?(fixture.pid)
      Attempt.refuse(fixture.pid, "not started")
    end

    @tag :capture_log
    test "a boot that does not hold the control plane refuses every route", %{url: url} do
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          attach: false,
          service_id: @service
        )

      on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)
      Arca.ControlPlane.record(:lost)

      assert {503, %{"error" => "lost"}} = attach(url, fixture)
      assert {503, %{"error" => "unavailable"}} = report(url, fixture)

      assert claimed_by(fixture) == nil
      assert %{status: "running"} = row(fixture)

      assert %{state: "running"} =
               Arca.ExecutionAttempts.get(
                 Prima.Actor.in_athanor(fixture.athanor_id),
                 fixture.attempt
               )
    end
  end

  describe "the claim" do
    @tag :capture_log
    test "a call naming another runner than the attempt's claim is refused before its body is read",
         %{listener: listener, url: url} do
      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), service_id: @service)

      port = HostListener.port(listener)
      assert claimed_by(fixture) == fixture.runner

      # The header verifies: the runner is signed, never a key input. The
      # row's claim refuses it, answered `lost` as `Host` answers it,
      # sealed for the call, on a closed connection with the body unread.
      for route <- [:renew, :storage, :push_deltas, :complete] do
        opts = [runner: "runner_elsewhere", ts: now(), nonce: "n_#{route}"]

        log =
          capture_log(fn ->
            assert {200, %{"connection" => "close"}, sealed} =
                     unread_post(port, WorkerWire.host_route(route), [live_header(fixture, opts)],
                       raw: true
                     )

            assert open_answer(fixture.keys.seal, fields(fixture, opts), sealed) ==
                     %{"v" => 1, "error" => "lost"}
          end)

        assert log =~ "not claimed by the runner the header names", Atom.to_string(route)
      end

      # The claiming runner's calls go on.
      assert {200, %{"ok" => %{} = renewals}} = renew(url, fixture)
      assert %{"lease_until" => _} = renewals[fixture.attempt]
      assert claimed_by(fixture) == fixture.runner
      assert Process.alive?(fixture.pid)
    end

    @tag :capture_log
    test "attach is the claim: no call is taken before it, and the claiming runner's are after it",
         %{url: url} do
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          attach: false,
          service_id: @service
        )

      assert {200, %{"error" => "lost"}} = renew(url, fixture)
      assert {200, %{"error" => "lost"}} = push(url, fixture, "too early")
      assert claimed_by(fixture) == nil

      assert {200, %{"ok" => _}} = attach(url, fixture)
      assert claimed_by(fixture) == fixture.runner
      assert {200, %{"ok" => [_reply]}} = push(url, fixture, "claimed")

      assert {200, %{"error" => "lost"}} =
               push(url, fixture, "another runner", runner: "runner_elsewhere")
    end

    @tag :capture_log
    test "a call on an attempt no longer running is refused before its body", %{url: url} do
      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), service_id: @service)

      assert {200, %{"ok" => true}} = report(url, fixture)

      assert {:error, "Execution terminated: runner stopped without cleanup"} =
               Dispatch.await(fixture.pid, fixture.close)

      assert {200, %{"error" => "lost"}} = push(url, fixture, "after the lapse")
    end
  end

  describe "the seal" do
    test "a call's body opens as the header's call, and its answer is sealed for it", %{
      url: url
    } do
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          attach: false,
          service_id: @service,
          vault: %{kind: "api_key", fields: %{"KEY" => "sk-fixture"}}
        )

      fields = fields(fixture, [])
      json = AttemptFixtures.body("attach", %{"assignment" => fixture.assignment})
      {:ok, body} = WorkerAuth.seal_call(fixture.keys.seal, :body, fields, json)
      {:ok, header} = WorkerAuth.host_call_header(fixture.call_key, fields, body)

      assert {200, sealed} = post(url, WorkerWire.host_route(:attach), [header], body, raw: true)

      assert {:error, :unsealable} =
               WorkerAuth.open_call(fixture.keys.seal, :body, fields, sealed)

      assert {:ok, answer} = WorkerAuth.open_call(fixture.keys.seal, :answer, fields, sealed)
      assert %{"ok" => %{"KEY" => "sk-fixture"}} = Jason.decode!(answer)
      refute sealed =~ "sk-fixture"
      assert claimed_by(fixture) == fixture.runner
    end

    @tag :capture_log
    test "a body that does not open under the attempt's seal key is refused, and nothing of it is logged",
         %{url: url} do
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          attach: false,
          service_id: @service
        )

      log =
        capture_log(fn ->
          assert {401, %{"error" => "lost"}} =
                   attach(url, fixture, seal_key: :crypto.strong_rand_bytes(32))

          assert {401, %{"error" => "lost"}} =
                   post(
                     url,
                     WorkerWire.host_route(:attach),
                     [AttemptFixtures.header(fixture, "not sealed at all")],
                     "not sealed at all"
                   )
        end)

      assert log =~ "does not open"
      refute log =~ fixture.assignment
      assert claimed_by(fixture) == nil
      assert {200, %{"ok" => _}} = attach(url, fixture)
    end

    @tag :capture_log
    test "a body sealed for another call than the header's is refused", %{url: url} do
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          attach: false,
          service_id: @service
        )

      other = fields(fixture, nonce: "n_other")

      assert {401, %{"error" => "lost"}} = attach(url, fixture, sealed_as: other)

      assert {401, %{"error" => "lost"}} =
               attach(url, fixture, sealed_as: %{other | runner: "r2"})

      assert claimed_by(fixture) == nil
    end
  end

  describe "refused by the body" do
    @tag :capture_log
    test "a body that is not the one the header names is refused, and nothing of it is logged", %{
      url: url
    } do
      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), service_id: @service)

      :ok = Crucible.Events.subscribe(fixture.execution_id, fixture.ctx)

      {:ok, tampered} =
        WorkerAuth.seal_call(
          fixture.keys.seal,
          :body,
          fields(fixture, []),
          AttemptFixtures.body("push_deltas", %{
            "deltas" => [AttemptFixtures.delta(fixture, ~s({"type":"note","text":"sk-canary"}))]
          })
        )

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
      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), service_id: @service)

      :ok = Crucible.Events.subscribe(fixture.execution_id, fixture.ctx)
      max = Prima.HostAPI.max_body_bytes()
      text = String.duplicate("x", max)

      json =
        AttemptFixtures.body("push_deltas", %{
          "deltas" => [
            AttemptFixtures.delta(fixture, Jason.encode!(%{"type" => "note", "text" => text}))
          ]
        })

      fields = fields(fixture, [])
      {:ok, body} = WorkerAuth.seal_call(fixture.keys.seal, :body, fields, json)
      assert byte_size(body) > max
      {:ok, header} = WorkerAuth.host_call_header(fixture.call_key, fields, body)
      path = WorkerWire.host_route(:push_deltas)

      assert {413, %{"error" => "lost"}} = post(url, path, [header], body)

      # A refused request's nonce was presented all the same; the streamed
      # repeat is a new call, sealed for it.
      fields = fields(fixture, [])
      {:ok, body} = WorkerAuth.seal_call(fixture.keys.seal, :body, fields, json)
      {:ok, header} = WorkerAuth.host_call_header(fixture.call_key, fields, body)
      chunks = for <<chunk::binary-size(65_536) <- body>>, do: chunk

      rest =
        binary_part(
          body,
          byte_size(body) - rem(byte_size(body), 65_536),
          rem(byte_size(body), 65_536)
        )

      # The listener answers and closes with the rest unread, so a client
      # still sending may find the connection closed before it reads the
      # answer. Either way nothing of the call is taken.
      streamed =
        try do
          post(url, path, [header], Stream.concat(chunks, [rest]))
        rescue
          error in Req.TransportError -> {:closed, error.reason}
        end

      case streamed do
        {413, %{"error" => "lost"}} -> :ok
        {:closed, reason} when reason in [:closed, :econnreset, :epipe] -> :ok
        other -> flunk("the streamed body was not refused: #{inspect(other)}")
      end

      assert live_events() == []
      assert Process.alive?(fixture.pid)
    end

    @tag :capture_log
    test "a body naming another operation than its route", %{url: url} do
      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), service_id: @service)

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
      fixture =
        AttemptFixtures.attached!(
          ctx: Sanctum.TestContext.local(:api),
          attach: false,
          service_id: @service
        )

      fields = fields(fixture, [])
      json = AttemptFixtures.body("attach", %{"assignment" => fixture.assignment})
      {:ok, body} = WorkerAuth.seal_call(fixture.keys.seal, :body, fields, json)
      {:ok, header} = WorkerAuth.host_call_header(fixture.call_key, fields, body)

      assert {404, %{"error" => "not_found"}} = post(url, "/host/v1/nope", [header], body)

      assert {404, %{"error" => "not_found"}} =
               post(url, WorkerWire.worker_route(:start), [header], body)

      assert {404, %{"error" => "not_found"}} =
               post(url, WorkerWire.host_route(:attach), [header], body, method: :get)

      assert claimed_by(fixture) == nil
    end
  end

  describe "the drain" do
    # The Bandit server is started with the drain as its
    # `shutdown_timeout`: on shutdown it stops accepting and lets the
    # calls already open finish for that long.
    test "reaches the server's options, 5 s unless the supervisor names another", %{
      listener: listener
    } do
      drained = start_supervised!({HostListener, port: 0, drain_ms: 1_234}, id: :drained)

      assert drain(listener) == 5_000
      assert drain(drained) == 1_234
    end
  end

  describe "the vectors of tests/fixtures/host_api.json" do
    @tag :capture_log
    test "every pre-body refusal is answered at its status, closed, with the body unread", %{
      listener: listener,
      url: url
    } do
      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), service_id: @service)

      port = HostListener.port(listener)
      vectors = @vectors["pre_body_refusals"]

      assert Enum.map(vectors, & &1["name"]) ==
               ~w(unknown_version malformed outside_window bad_mac other_generation
                  other_member reused_nonce)

      for vector <- vectors do
        headers = pre_body_header(vector, fixture, url)

        log =
          capture_log(fn ->
            {status, response_headers, answer} =
              unread_post(port, WorkerWire.host_route(pre_body_route(vector)), headers)

            assert status == vector["status"], vector["name"]
            assert response_headers["connection"] == "close", vector["name"]

            # A peer at another version is told so; every other header is
            # refused as lost, its reason logged.
            name = if vector["error"] == "unknown_version", do: "unknown_version", else: "lost"
            assert answer == %{"v" => 1, "error" => name}, vector["name"]
          end)

        assert log =~ vector["error"], vector["name"]
      end

      assert claimed_by(fixture) == fixture.runner
      assert Process.alive?(fixture.pid)
    end

    @tag :capture_log
    test "a header failing two checks is refused by the earlier, before the body", %{
      listener: listener,
      url: url
    } do
      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), service_id: @service)

      port = HostListener.port(listener)
      renew = WorkerWire.host_route(:renew)

      {:ok, stale} =
        Keys.attempt_keys(%{fixture.keys.attempt | generation: fixture.generation + 1})

      bad_key = :crypto.strong_rand_bytes(32)

      refused = fn path, headers, reason ->
        log = capture_log(fn -> send(self(), {:answer, unread_post(port, path, headers)}) end)
        assert_received {:answer, {_status, %{"connection" => "close"}, answer}}
        assert log =~ reason, reason
        answer
      end

      # The route before the plane, the plane before the header count.
      on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)
      Arca.ControlPlane.record(:lost)

      assert %{"error" => "not_found"} = refused.("/host/v1/nope", [], "")
      assert %{"error" => "lost"} = refused.(renew, [], "does not hold the control plane")
      Arca.ControlPlane.record(:unclaimed)

      # The header count before its version, its version before its shape.
      assert %{"error" => "lost"} = refused.(renew, ["v2 x", "v2 x"], "2 x-cyfr-auth headers")

      assert %{"error" => "unknown_version"} =
               refused.(renew, ["v2 kind=call"], "unknown_version")

      # The window before the MAC, the MAC before the generation, the
      # generation before the member.
      assert %{"error" => "lost"} =
               refused.(
                 renew,
                 [live_header(fixture, ts: now() - 60_000, call_key: bad_key)],
                 "outside_window"
               )

      assert %{"error" => "lost"} =
               refused.(
                 renew,
                 [live_header(fixture, generation: fixture.generation + 1, call_key: bad_key)],
                 "bad_mac"
               )

      assert %{"error" => "lost"} =
               refused.(
                 renew,
                 [
                   live_header(fixture,
                     generation: fixture.generation + 1,
                     call_key: stale.call,
                     member: "cyfr@elsewhere#boot_other"
                   )
                 ],
                 "generation_mismatch"
               )

      # The member before the nonce: a call presented with a nonce already
      # seen, to another member, is refused as misrouted.
      storage = WorkerWire.host_route(:storage)
      {header, body} = storage_call(fixture, nonce: "n_order")
      assert {200, _sealed} = post(url, storage, [header], body, raw: true)

      {misrouted, _body} =
        storage_call(fixture, nonce: "n_order", member: "cyfr@elsewhere#boot_other")

      assert %{"error" => "lost"} = refused.(storage, [misrouted], "member_mismatch")

      # The nonce before the body.
      assert %{"error" => "lost"} = refused.(storage, [header], "replayed")
    end

    @tag :capture_log
    test "every body refusal is answered once the body is opened, before its op is read", %{
      url: url
    } do
      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), service_id: @service)

      vectors = @vectors["body_refusals"]

      assert Enum.map(vectors, & &1["error"]) ==
               ~w(unknown_version unknown_version unknown_version malformed malformed malformed
                  malformed)

      for %{"name" => name, "body" => json, "error" => error} <- vectors do
        fields = fields(fixture, [])
        {:ok, sealed} = WorkerAuth.seal_call(fixture.keys.seal, :body, fields, json)
        {:ok, header} = WorkerAuth.host_call_header(fixture.call_key, fields, sealed)

        assert {400, %{"v" => 1, "error" => ^error}} =
                 post(url, WorkerWire.host_route(:renew), [header], sealed),
               name
      end

      assert %{state: "running"} =
               Arca.ExecutionAttempts.get(
                 Prima.Actor.in_athanor(fixture.athanor_id),
                 fixture.attempt
               )

      assert Process.alive?(fixture.pid)
    end

    test "a call's answer and a report's carry the wire's version first", %{url: url} do
      fixture =
        AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api), service_id: @service)

      fields = fields(fixture, [])

      json =
        WorkerWire.request_body(:renew, %{"attempts" => [fixture.attempt]}) |> Jason.encode!()

      {:ok, sealed} = WorkerAuth.seal_call(fixture.keys.seal, :body, fields, json)
      {:ok, header} = WorkerAuth.host_call_header(fixture.call_key, fields, sealed)

      assert {200, raw} = post(url, WorkerWire.host_route(:renew), [header], sealed, raw: true)
      assert {:ok, answer} = WorkerAuth.open_call(fixture.keys.seal, :answer, fields, raw)
      assert String.starts_with?(answer, ~s({"v":1,"ok":))

      assert {200, %{"v" => 1, "ok" => true}} = report(url, fixture)
    end
  end

  # The live header carrying the defect a pre-body vector names. A vector
  # whose header decides its refusal on its own (a version token, a shape,
  # a timestamp long past) is posted as it is; the rest are made against
  # the live attempt, whose keys and standing the vector's cannot be.
  defp pre_body_header(%{"error" => error, "header" => header}, _fixture, _url)
       when error in ~w(unknown_version malformed outside_window),
       do: [header]

  defp pre_body_header(%{"error" => "bad_mac"}, fixture, _url),
    do: [live_header(fixture, call_key: :crypto.strong_rand_bytes(32))]

  defp pre_body_header(%{"error" => "generation_mismatch"}, fixture, _url) do
    {:ok, keys} = Keys.attempt_keys(%{fixture.keys.attempt | generation: fixture.generation + 1})
    [live_header(fixture, generation: fixture.generation + 1, call_key: keys.call)]
  end

  defp pre_body_header(%{"error" => "member_mismatch"}, fixture, _url),
    do: [live_header(fixture, member: "cyfr@10.0.0.2#boot_01a09fee-6e8f-7091-a2b3-c4d5e6f70819")]

  # A storage call is never retried: its nonce, once presented, is replayed.
  defp pre_body_header(%{"error" => "replayed"}, fixture, url) do
    {header, body} = storage_call(fixture, [])
    assert {200, _sealed} = post(url, WorkerWire.host_route(:storage), [header], body, raw: true)
    [header]
  end

  defp pre_body_route(%{"error" => "replayed"}), do: :storage
  defp pre_body_route(_vector), do: :renew

  # A renew header for `fixture`, over a body never sent.
  defp live_header(fixture, opts) do
    {:ok, header} =
      WorkerAuth.host_call_header(
        Keyword.get(opts, :call_key, fixture.call_key),
        fields(fixture, opts),
        "a body never sent"
      )

    header
  end

  defp storage_call(fixture, opts) do
    fields = fields(fixture, opts)

    json =
      WorkerWire.request_body(:storage, %{"action" => "exists", "path" => "notes/a.txt"})
      |> Jason.encode!()

    {:ok, sealed} = WorkerAuth.seal_call(fixture.keys.seal, :body, fields, json)
    {:ok, header} = WorkerAuth.host_call_header(fixture.call_key, fields, sealed)
    {header, sealed}
  end

  # A request whose headers declare a body that is never sent: an answer
  # that arrives is one given without reading it. Answers the status, the
  # response headers and the decoded answer, once the listener has closed
  # the connection; a listener that kept it open to read the body fails
  # the read's deadline.
  defp unread_post(port, path, auth_headers, opts \\ []) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 5_000)

    request = [
      "POST ",
      path,
      " HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-type: application/json\r\n",
      "content-length: 1024\r\n",
      Enum.map(auth_headers, &[@auth, ": ", &1, "\r\n"]),
      "\r\n"
    ]

    :ok = :gen_tcp.send(socket, request)
    {:ok, response} = read_until_closed(socket, "")
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    ["HTTP/1.1 " <> status_line | header_lines] = String.split(head, "\r\n")
    {status, _reason} = Integer.parse(status_line)

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    {status, headers, if(Keyword.get(opts, :raw, false), do: body, else: Jason.decode!(body))}
  end

  defp read_until_closed(socket, read) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, more} -> read_until_closed(socket, read <> more)
      {:error, :closed} -> {:ok, read}
      {:error, :timeout} -> {:still_open, read}
    end
  end

  defp drain(listener) do
    {:ok, %{start: {Bandit, :start_link, [options]}}} =
      :supervisor.get_childspec(listener, :server)

    options |> Keyword.fetch!(:thousand_island_options) |> Keyword.fetch!(:shutdown_timeout)
  end
end
