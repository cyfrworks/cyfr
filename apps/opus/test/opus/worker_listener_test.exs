# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.WorkerListenerTest do
  @moduledoc """
  CYFR reaches the worker service through its listener, and only with a
  request signed by this service's dispatch key: a wrong key, a missing
  or stale header, a reused nonce, a request addressed to another service
  and a body other than the one the header named are each refused before
  the request runs — the unauthenticated ones before the body is read. A
  verified request runs the callback its route names on the service and
  answers as the worker protocol spells it, and an assignment for another
  boot of this service is answered `malformed`.
  """

  use ExUnit.Case, async: false

  alias Cyfr.{WorkerAuth, WorkerWire}
  alias Opus.Test.ScriptedHost

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

    {:ok, %Req.Response{status: status, body: answer}} =
      Req.post(context.url <> path,
        headers: headers,
        body: body,
        retry: false,
        decode_body: false
      )

    {status, Jason.decode!(answer)}
  end

  defp request(callback, args \\ %{}), do: Jason.encode!(WorkerWire.request_body(callback, args))

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  test "a signed status request is answered with the service's state", context do
    assert {200, %{"ok" => status}} = post(context, :status, request(:status))

    assert %{"service" => "wrk_local", "boot" => boot, "runners" => runners, "attempts" => []} =
             status

    assert boot == context.boot
    assert %{"fresh" => 0, "idle" => 0, "busy" => 0, "tainted" => 0} = runners
  end

  test "a request under another key is refused without the body being read", context do
    # A body past the listener's bound: refused for its key, not its size,
    # so the refusal came before the body was read.
    huge = String.duplicate("x", Cyfr.HostAPI.max_body_bytes() + 1)
    stranger = ScriptedHost.dispatch_key(ScriptedHost.start!(root: :crypto.strong_rand_bytes(32)))

    assert {401, %{"error" => "bad_mac"}} = post(context, :status, huge, key: stranger)
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
    huge = String.duplicate("x", Cyfr.HostAPI.max_body_bytes() + 1)
    assert {413, %{"error" => "malformed"}} = post(context, :status, huge)
  end

  test "a body naming another callback than its route, or no callback, is refused", context do
    assert {400, %{"error" => "malformed"}} =
             post(context, :status, request(:kill, %{"execution_id" => "exec_x"}))

    assert {400, %{"error" => "malformed"}} =
             post(context, :status, ~s({"op": "attach", "args": {}}))

    assert {400, %{"error" => "malformed"}} = post(context, :status, "not json")
  end

  test "a route that is no worker route is refused", context do
    assert {404, %{"error" => "not_found"}} =
             post(context, :status, request(:status), path: "/worker/v1/attach")

    assert {404, %{"error" => "not_found"}} =
             post(context, :status, request(:status), path: "/host/v1/status")
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
