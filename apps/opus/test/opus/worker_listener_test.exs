# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.WorkerListenerTest do
  @moduledoc """
  CYFR reaches the worker service through its listener, and only with a
  request signed by this service's dispatch key: a wrong key, a missing
  or stale header, a header at another version, a reused nonce, a request
  addressed to another service and a body other than the one the header
  named are each refused before the request runs — the unauthenticated
  ones before the body is read, on a connection that is then closed. A
  body without the wire's version, or at another, is `unknown_version`
  before its callback is read. A verified request runs the callback its
  route names on the service and answers as the worker protocol spells
  it, versioned and plain, and an assignment for another boot of this
  service is answered `malformed`. Every request of
  `tests/fixtures/worker_api.json` is read as its callback and answered
  as the vector or one of its refusals, byte for byte.
  """

  use ExUnit.Case, async: false

  alias Prima.{WorkerAPI, WorkerAuth, WorkerWire}
  alias Opus.Test.ScriptedHost

  # Read as this module compiles, so a checkout without the file fails
  # here, naming it, rather than running without the vectors.
  @worker_api Path.expand("../../../../tests/fixtures/worker_api.json", __DIR__)
              |> File.read!()
              |> Jason.decode!()

  setup do
    host = ScriptedHost.start!()
    boot = ScriptedHost.serve!(host)

    server =
      start_supervised!(
        {Bandit, plug: Opus.WorkerListener, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    {:ok,
     host: host, boot: boot, url: "http://127.0.0.1:#{port}", key: ScriptedHost.dispatch_key(host)}
  end

  # Post `body` to `callback`'s route with a request header signed by `key`
  # over the fields (`:service`, `:boot`, `:ts`, `:nonce` overridable), or
  # with `:header` verbatim. Answers the status and the decoded body.
  defp post(context, callback, body, opts \\ []) do
    %Req.Response{status: status, body: answer} = response(context, callback, body, opts)
    {status, Jason.decode!(answer)}
  end

  # As `post/4`, answering the whole response, its body as sent.
  defp response(context, callback, body, opts \\ []) do
    header =
      Keyword.get_lazy(opts, :header, fn ->
        request = %{
          service: Keyword.get(opts, :service, "wrk_local"),
          boot: Keyword.get(opts, :boot, context.boot),
          ts: Keyword.get_lazy(opts, :ts, fn -> System.system_time(:millisecond) end),
          nonce: Keyword.get_lazy(opts, :nonce, &nonce/0)
        }

        {:ok, header} =
          WorkerAuth.request_header(Keyword.get(opts, :key, context.key), request, body)

        header
      end)

    headers = if header, do: [{WorkerWire.auth_header(), header}], else: []
    path = Keyword.get(opts, :path, WorkerWire.worker_route(callback))

    {:ok, %Req.Response{} = response} =
      Req.post(context.url <> path,
        headers: headers,
        body: body,
        retry: false,
        decode_body: false
      )

    response
  end

  defp closed?(%Req.Response{} = response),
    do: Req.Response.get_header(response, "connection") == ["close"]

  defp request(callback, args \\ %{}), do: Jason.encode!(WorkerWire.request_body(callback, args))

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  test "a signed status request is answered with the service's state", context do
    assert {200, %{"v" => 1, "ok" => status} = answer} = post(context, :status, request(:status))
    assert map_size(answer) == 2

    assert %{"service" => "wrk_local", "boot" => boot, "runners" => runners, "attempts" => []} =
             status

    assert boot == context.boot
    assert %{"fresh" => _, "idle" => 0, "busy" => 0, "tainted" => 0} = runners

    # The answer is the contract's wire form of the service's own status.
    assert {:ok, read} = Prima.WorkerAPI.read_status(status)
    {:ok, own} = Opus.WorkerService.status()
    assert Map.drop(read, [:runners]) == Map.drop(own, [:runners])
  end

  test "a request under another key is refused without the body being read", context do
    # A body past the listener's bound: refused for its key, not its size,
    # so the refusal came before the body was read.
    huge = String.duplicate("x", Prima.HostAPI.max_body_bytes() + 1)
    stranger = ScriptedHost.dispatch_key(ScriptedHost.start!(root: :crypto.strong_rand_bytes(32)))

    response = response(context, :status, huge, key: stranger)
    assert response.status == 401
    assert response.body == ~s({"v":1,"error":"bad_mac"})
    assert closed?(response)
  end

  test "a header at another version of the wire is refused before the body is read", context do
    huge = String.duplicate("x", Prima.HostAPI.max_body_bytes() + 1)

    {:ok, header} =
      WorkerAuth.request_header(
        context.key,
        %{
          service: "wrk_local",
          boot: context.boot,
          ts: System.system_time(:millisecond),
          nonce: nonce()
        },
        huge
      )

    "v1 " <> rest = header
    response = response(context, :status, huge, header: "v2 " <> rest)

    assert response.status == 401
    assert response.body == ~s({"v":1,"error":"unknown_version"})
    assert closed?(response)
  end

  test "a body without the wire's version, or at another, is unknown_version before its op",
       context do
    for body <- [
          ~s({"op":"status","args":{}}),
          ~s({"v":2,"op":"status","args":{}}),
          ~s({"v":"1","op":"status","args":{}}),
          ~s({"v":2,"op":"no such callback"})
        ] do
      assert {400, %{"v" => 1, "error" => "unknown_version"}} = post(context, :status, body)
    end

    # At this version, the callback is read: a body naming another is malformed.
    assert {400, %{"v" => 1, "error" => "malformed"}} =
             post(context, :status, ~s({"v":1,"op":"kill","args":{}}))
  end

  test "a missing, malformed or stale header is refused", context do
    assert {401, %{"error" => "malformed"}} =
             post(context, :status, request(:status), header: nil)

    assert {401, %{"error" => "malformed"}} =
             post(context, :status, request(:status), header: "v1 kind=request mac=x")

    stale = System.system_time(:millisecond) - 2 * WorkerAuth.window_ms()

    assert {401, %{"error" => "outside_window"}} =
             post(context, :status, request(:status), ts: stale)
  end

  test "a nonce presented before is refused", context do
    nonce = nonce()
    assert {200, %{"ok" => _}} = post(context, :status, request(:status), nonce: nonce)

    assert {401, %{"error" => "replayed"}} =
             post(context, :status, request(:status), nonce: nonce)
  end

  test "a request addressed to another service is refused", context do
    assert {401, %{"error" => "malformed"}} =
             post(context, :status, request(:status), service: "wrk_other")
  end

  test "a body other than the one the header named is refused", context do
    {:ok, header} =
      WorkerAuth.request_header(
        context.key,
        %{
          service: "wrk_local",
          boot: context.boot,
          ts: System.system_time(:millisecond),
          nonce: nonce()
        },
        request(:status)
      )

    assert {401, %{"error" => "bad_mac"}} =
             post(context, :status, request(:kill, %{"execution_id" => "exec_x"}), header: header)
  end

  test "a body past the listener's bound is refused once the header verifies", context do
    huge = String.duplicate("x", Prima.HostAPI.max_body_bytes() + 1)
    assert {413, %{"error" => "malformed"}} = post(context, :status, huge)
  end

  test "a body naming another callback than its route, or no callback, is refused", context do
    assert {400, %{"error" => "malformed"}} =
             post(context, :status, request(:kill, %{"execution_id" => "exec_x"}))

    assert {400, %{"error" => "malformed"}} =
             post(context, :status, ~s({"v": 1, "op": "attach", "args": {}}))

    assert {400, %{"error" => "malformed"}} = post(context, :status, "not json")
  end

  test "a route that is no worker route is refused", context do
    response = response(context, :status, request(:status), path: "/worker/v1/attach")
    assert response.status == 404
    assert response.body == ~s({"v":1,"error":"not_found"})
    assert closed?(response)

    assert {404, %{"error" => "not_found"}} =
             post(context, :status, request(:status), path: "/host/v1/status")
  end

  describe "the worker_api.json vectors" do
    test "every request is read as its callback, and answered as its vector or a refusal of it",
         context do
      requests = @worker_api["requests"]
      assert Enum.map(requests, & &1["callback"]) == ~w(start kill status)

      for vector <- requests do
        callback = String.to_existing_atom(vector["callback"])
        assert {:ok, ^callback, _args} = WorkerWire.read_request_body(WorkerAPI, decode(vector))

        # The vector's body, as CYFR would send it to this service and boot.
        response = response(context, callback, vector["body"])

        answers =
          [{200, vector["answer"]}] ++ for r <- vector["refusals"], do: {r["status"], r["answer"]}

        case callback do
          # This service's own status, in the vector's shape.
          :status ->
            assert response.status == 200
            %{"v" => 1, "ok" => wire} = Jason.decode!(response.body)
            %{"v" => 1, "ok" => expected} = Jason.decode!(vector["answer"])
            assert Enum.sort(Map.keys(wire)) == Enum.sort(Map.keys(expected))
            assert {:ok, _status} = WorkerAPI.read_status(wire)

          # The vector's assignment is for another service, and its
          # execution runs on none of this boot's runners: each is refused
          # as its vector lists, byte for byte.
          _ ->
            assert {response.status, response.body} in answers, vector["callback"]
        end

        # The header refusals each vector lists, as this listener answers them.
        for %{"status" => 401, "answer" => answer} <- vector["refusals"] do
          %{"error" => reason} = Jason.decode!(answer)
          refused = header_refusal(context, callback, vector["body"], reason)
          assert {refused.status, refused.body} == {401, answer}, reason
          assert closed?(refused)
        end

        # A start refused 503 is written as the listener writes it: a
        # sentence names a definite refusal, and without one the answer is lost.
        for %{"status" => 503, "answer" => answer} <- vector["refusals"] do
          fields = answer |> Jason.decode!() |> Map.drop(["v", "error"])
          assert Jason.encode!(WorkerWire.error(:unavailable, fields)) == answer
        end
      end
    end

    test "every status vector is the wire the listener writes for its status" do
      %{"valid" => valid, "invalid" => invalid} = @worker_api["status"]

      for %{"wire" => wire} <- valid do
        assert {:ok, status} = WorkerAPI.read_status(wire)
        answer = status |> WorkerAPI.status_to_wire() |> WorkerWire.ok()
        assert answer |> Jason.encode!() |> Jason.decode!() == %{"v" => 1, "ok" => wire}
      end

      for %{"wire" => wire, "why" => why} <- invalid,
          do: assert(:error == WorkerAPI.read_status(wire), why)
    end
  end

  defp decode(vector), do: Jason.decode!(vector["body"])

  # A request of `body` refused by its header for `reason`.
  defp header_refusal(context, callback, body, "bad_mac") do
    stranger = ScriptedHost.dispatch_key(ScriptedHost.start!(root: :crypto.strong_rand_bytes(32)))
    response(context, callback, body, key: stranger)
  end

  defp header_refusal(context, callback, body, "unknown_version") do
    {:ok, header} =
      WorkerAuth.request_header(
        context.key,
        %{
          service: "wrk_local",
          boot: context.boot,
          ts: System.system_time(:millisecond),
          nonce: nonce()
        },
        body
      )

    "v1 " <> rest = header
    response(context, callback, body, header: "v2 " <> rest)
  end

  defp header_refusal(context, callback, body, "replayed") do
    nonce = nonce()
    # The first is answered; its nonce is then spent.
    _ = response(context, callback, request(:status), nonce: nonce, path: "/worker/v1/status")
    response(context, callback, body, nonce: nonce)
  end

  test "a kill of an execution no runner runs answers not_found", context do
    assert {200, %{"error" => "not_found"}} =
             post(context, :kill, request(:kill, %{"execution_id" => "exec_none"}))
  end

  test "a start for another boot of this service is refused malformed, and starts nothing",
       context do
    attempt = ScriptedHost.attempt!(context.host, boot: "boot_other")

    args = %{
      "assignment" => attempt.assignment,
      "input" => attempt.input,
      "sealed_keys" => attempt.sealed_keys
    }

    assert {200, %{"error" => "malformed"}} = post(context, :start, request(:start, args))
    assert {200, %{"ok" => %{"attempts" => []}}} = post(context, :status, request(:status))
    assert ScriptedHost.requests(context.host) == []
  end

  test "a start for this boot runs a runner that reaches the host over the wire", context do
    attempt = ScriptedHost.attempt!(context.host, boot: context.boot)

    args = %{
      "assignment" => attempt.assignment,
      "input" => attempt.input,
      "sealed_keys" => attempt.sealed_keys
    }

    assert {200, %{"ok" => true}} = post(context, :start, request(:start, args))

    # The runner attaches, asks for its artifact (which this host has none
    # of) and closes the attempt failed, all as signed host calls.
    Opus.Test.Wait.wait_until(fn -> ScriptedHost.requests(context.host, "fail") != [] end, 10_000)

    ops = for %{op: op} <- ScriptedHost.requests(context.host), do: op
    assert ops == ["attach", "fetch_artifact", "fail"]

    for %{caller: caller} <- ScriptedHost.requests(context.host) do
      assert caller.execution_id == attempt.execution_id
      assert caller.boot == context.boot
      assert caller.service == "wrk_local"
    end

    [%{args: %{"outcome" => outcome}}] = ScriptedHost.requests(context.host, "fail")
    assert outcome["error"] =~ "could not be fetched"
  end
end
