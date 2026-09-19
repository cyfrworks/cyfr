# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.WorkerServicePoolTest do
  @moduledoc """
  The worker service over a pool whose runners a scripted keeper hands the
  test, in place of the running service's tree, reached through its
  listener where the wire is the point.

  A kill reaches only what a runner of this boot holds: the root of a
  runner's subtree ends that runner; a child its runner said it started
  is cancelled in that runner alone; an execution no runner holds or held
  is `:not_found` however busy the runners are, and an execution a runner
  of this boot ended, root or child, is `:ok` again. A runner that ends
  without an `exit` is reported holding its root and every child it said
  it started.

  A keeper that refuses every runner makes the status report the
  refusal, with the keeper's reason and the sentence naming what the
  deployment lacks, beside the bound every runner would run under, and
  count no runner; a start is refused `503` `unavailable` with that
  sentence, and nothing of it is reported as a runner's exit, since no
  runner was given it.
  """

  use ExUnit.Case, async: false

  import Opus.Test.Wait

  alias Cyfr.{RunnerControl, WorkerAPI, WorkerAuth, WorkerWire}
  alias Opus.Test.{ScriptedHost, ScriptedKeeper}
  alias Opus.WorkerService

  @bound 402_653_184

  setup tags do
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
    if tags[:refusing], do: :ok = ScriptedKeeper.refuse(keeper, :memory_unavailable)
    {:ok, settings} = Opus.Settings.pool([keeper: :direct, pool_size: 1], %{})

    start_supervised!({DynamicSupervisor, name: Opus.RunnerPool.Runners, strategy: :one_for_one})

    start_supervised!(
      {Opus.RunnerPool,
       settings: settings,
       keeper: ScriptedKeeper,
       keeper_opts: [memory_bytes: @bound],
       supervisor: Opus.RunnerPool.Runners,
       command: %{argv: ["runner"], env: %{"KEEPER" => Atom.to_string(keeper)}}}
    )

    start_supervised!(WorkerService)

    server =
      start_supervised!(
        {Bandit, plug: Opus.WorkerListener, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, %{boot: boot}} = WorkerService.status()

    {:ok, host: host, boot: boot, keeper: keeper, url: "http://127.0.0.1:#{port}"}
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

  defp start_args(attempt) do
    %{
      "assignment" => attempt.assignment,
      "input" => attempt.input,
      "sealed_keys" => attempt.sealed_keys
    }
  end

  # A subtree started on a runner of the scripted keeper: the attempt and
  # the runner's spawn, whose channel the test writes and reads.
  defp started!(context) do
    attempt = ScriptedHost.attempt!(context.host, boot: context.boot)
    assert {200, %{"ok" => true}} = post(context, :start, start_args(attempt))

    spawn =
      Enum.find(ScriptedKeeper.spawns(context.keeper), fn spawn ->
        String.contains?(ScriptedKeeper.read(spawn), attempt.assignment)
      end)

    {attempt, spawn}
  end

  defp write(spawn, message), do: ScriptedKeeper.write(spawn, RunnerControl.encode(message))

  defp cancels(spawn) do
    for line <- String.split(ScriptedKeeper.read(spawn), "\n", trim: true),
        {:ok, %{type: :cancel_child, execution_id: id}} <- [RunnerControl.decode(line)],
        do: id
  end

  describe "a kill" do
    test "reaches the runner holding a child alone, and finds nothing no runner holds", context do
      {root, runner} = started!(context)
      {_other, other_runner} = started!(context)

      write(runner, %{type: :child, execution_id: "exec_child", attempt: "att_child"})
      wait_until(fn -> "att_child" in elem(WorkerService.status(), 1).attempts end)

      # A child its runner said it started: that runner, and only it, is told.
      assert {200, %{"ok" => true}} =
               post(context, :kill, %{"execution_id" => "exec_child"})

      wait_until(fn -> cancels(runner) == ["exec_child"] end)
      assert cancels(other_runner) == []

      # Nobody's: not found, busy as the runners are.
      assert {200, %{"error" => "not_found"}} =
               post(context, :kill, %{"execution_id" => "exec_nobody_ran"})

      # Once the subtree completes, root and child are ended for this boot.
      write(runner, %{type: :complete, execution_id: root.execution_id, clean: false})
      wait_until(fn -> "att_child" not in elem(WorkerService.status(), 1).attempts end)

      for id <- [root.execution_id, "exec_child"] do
        assert {200, %{"ok" => true}} = post(context, :kill, %{"execution_id" => id})
      end

      assert {200, %{"error" => "not_found"}} =
               post(context, :kill, %{"execution_id" => "exec_nobody_ran"})
    end

    test "a runner that ends without an exit is reported holding its root and its children",
         context do
      {root, runner} = started!(context)
      write(runner, %{type: :child, execution_id: "exec_child", attempt: "att_child"})
      wait_until(fn -> "att_child" in elem(WorkerService.status(), 1).attempts end)

      ScriptedKeeper.exit(runner, 137)

      wait_until(fn -> ScriptedHost.requests(context.host, "runner_exited") != [] end, 5_000)

      assert [%{args: %{"attempts" => held}}] =
               ScriptedHost.requests(context.host, "runner_exited")

      assert Enum.sort(held) == Enum.sort([root.attempt, "att_child"])
    end
  end

  @tag :refusing
  test "a keeper that refuses runners: the status says why, and a start is refused 503 naming it",
       context do
    wait_until(fn -> match?({:ok, %{refusal: %{}}}, WorkerService.status()) end, 5_000)

    assert {200, %{"ok" => wire}} = post(context, :status, %{})

    assert {:ok,
            %{
              runners: %{fresh: 0, idle: 0, busy: 0, tainted: 0},
              memory_bytes: @bound,
              refusal: %{reason: "memory_unavailable", message: message},
              attempts: []
            }} = WorkerAPI.read_status(wire)

    attempt = ScriptedHost.attempt!(context.host, boot: context.boot)

    assert {503, %{"error" => "unavailable", "message" => ^message}} =
             post(context, :start, start_args(attempt))

    assert {200, %{"ok" => %{"attempts" => [], "runners" => %{"tainted" => 0}}}} =
             post(context, :status, %{})

    assert ScriptedHost.requests(context.host) == []
  end
end
