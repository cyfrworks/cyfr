# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.KeeperRefusalTest do
  @moduledoc """
  A worker service whose keeper refuses every runner, reached through its
  listener: its status reports the refusal, with the keeper's reason and
  the sentence naming what the deployment lacks, beside the bound every
  runner would run under, and counts no runner; a start is refused `503`
  `unavailable` with that sentence, and nothing of it is reported as a
  runner's exit, since no runner was given it. The service's pool runs on
  a scripted keeper, in place of the running service's tree.
  """

  use ExUnit.Case, async: false

  import Opus.Test.Wait

  alias Cyfr.{WorkerAPI, WorkerAuth, WorkerWire}
  alias Opus.Test.{ScriptedHost, ScriptedKeeper}

  @bound 402_653_184

  setup do
    host = ScriptedHost.start!()
    previous = Map.new([:keeper, :host_url], &{&1, Application.fetch_env(:opus, &1)})

    # The running service's tree gives way to one whose pool this test's
    # keeper serves, and comes back when the test ends.
    :ok = Supervisor.terminate_child(Opus.Supervisor, Opus.WorkerService.Tree)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:opus, key, value)
          :error -> Application.delete_env(:opus, key)
        end
      end

      {:ok, _pid} = Supervisor.restart_child(Opus.Supervisor, Opus.WorkerService.Tree)
    end)

    Application.put_env(:opus, :keeper, :direct)
    Application.put_env(:opus, :host_url, host.url)

    keeper = ScriptedKeeper.start!()
    :ok = ScriptedKeeper.refuse(keeper, :memory_unavailable)
    {:ok, settings} = Opus.Settings.pool([keeper: :direct], %{})

    start_supervised!({DynamicSupervisor, name: Opus.RunnerPool.Runners, strategy: :one_for_one})

    start_supervised!(
      {Opus.RunnerPool,
       settings: settings,
       keeper: ScriptedKeeper,
       keeper_opts: [memory_bytes: @bound],
       supervisor: Opus.RunnerPool.Runners,
       command: %{argv: ["runner"], env: %{"KEEPER" => Atom.to_string(keeper)}}}
    )

    start_supervised!(Opus.WorkerService)

    server =
      start_supervised!(
        {Bandit, plug: Opus.WorkerListener, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, %{boot: boot}} = Opus.WorkerService.status()

    {:ok, host: host, boot: boot, url: "http://127.0.0.1:#{port}"}
  end

  defp post(context, callback, args) do
    body = Jason.encode!(WorkerWire.request_body(callback, args))

    request = %{
      service: "wrk_local",
      boot: context.boot,
      ts: System.system_time(:millisecond),
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    }

    {:ok, header} =
      WorkerAuth.request_header(ScriptedHost.dispatch_key(context.host), request, body)

    {:ok, %Req.Response{status: status, body: answer}} =
      Req.post(context.url <> WorkerWire.worker_route(callback),
        headers: [{WorkerWire.auth_header(), header}],
        body: body,
        retry: false,
        decode_body: false
      )

    {status, Jason.decode!(answer)}
  end

  test "the status reports the refusal and the bound, and a start is refused 503 naming why",
       context do
    wait_until(fn -> match?({:ok, %{refusal: %{}}}, Opus.WorkerService.status()) end, 5_000)

    assert {200, %{"ok" => wire}} = post(context, :status, %{})

    assert {:ok,
            %{
              runners: %{fresh: 0, idle: 0, busy: 0, tainted: 0},
              memory_bytes: @bound,
              refusal: %{reason: "memory_unavailable", message: message},
              attempts: []
            }} = WorkerAPI.read_status(wire)

    attempt = ScriptedHost.attempt!(context.host, boot: context.boot)

    args = %{
      "assignment" => attempt.assignment,
      "input" => attempt.input,
      "sealed_keys" => attempt.sealed_keys
    }

    assert {503, %{"error" => "unavailable", "message" => ^message}} =
             post(context, :start, args)

    assert {200, %{"ok" => %{"attempts" => [], "runners" => %{"tainted" => 0}}}} =
             post(context, :status, %{})

    assert ScriptedHost.requests(context.host) == []
  end
end
