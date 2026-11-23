# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.Test.Runners do
  @moduledoc """
  What a test reads of the worker service's runners, and waits on at its
  end, from outside the service: the runners a pool holds (`runners/1`),
  every busy runner ended and retired (`retire_busy/2`), and every runner
  exit the service reports answered (`await_reports/1`). A test's end must
  know no runner of the work it started is left, since one still running
  a subtree could make its next host call after the test moved on, and
  that no report of a runner it ended still lands after that.

  And what a test waits on before it closes a socket whose descriptor it
  gave a port: the port gone from the port table (`port_gone/1`).
  `control_gone_at_exit/2` keeps such a socket open past the test's end
  until a runner's control port has gone.
  """

  import Prima.Test.Wait

  alias Locus.Runtime.RunnerPool

  @typedoc "One runner as its pool holds it."
  @type runner :: %{
          pid: pid(),
          id: String.t(),
          state: :spawning | :fresh | :idle | :busy | :tainted | :retiring | :refused,
          athanor: String.t() | nil,
          execution_id: String.t() | nil
        }

  @doc "Every runner `pool` holds, read from its state once it has handled what it was sent."
  @spec runners(GenServer.server()) :: [runner()]
  def runners(pool) do
    for {pid, entry} <- :sys.get_state(pool).runners,
        do: entry |> Map.take([:id, :state, :athanor, :execution_id]) |> Map.put(:pid, pid)
  end

  @doc """
  Taint every busy runner of `pool` and end it at once, with no grace
  (`Locus.Runtime.RunnerPool.taint/3`), and answer once no runner is left
  being ended: each retired by its keeper or dropped at the pool's
  retirement bound. Fresh and idle runners stay pooled. Fails past
  `timeout_ms`.
  """
  @spec retire_busy(GenServer.server(), non_neg_integer()) :: :ok
  def retire_busy(pool, timeout_ms \\ 30_000) do
    for %{pid: pid, state: :busy} <- runners(pool), do: :ok = RunnerPool.taint(pool, pid, 0)

    wait_until(
      fn -> not Enum.any?(runners(pool), &(&1.state in [:tainted, :retiring])) end,
      timeout_ms,
      "every runner being ended to be retired"
    )
  end

  @doc """
  Answer once no runner exit the worker service of this VM reports is in
  flight (`reports_in_flight/0`). The service reports each exit in a
  process of its own, which ends once CYFR answers or the report gives up
  (`Locus.Runtime.HostClient.runner_exited/5` bounds it). Fails past
  `timeout_ms`.
  """
  @spec await_reports(non_neg_integer()) :: :ok
  def await_reports(timeout_ms \\ 70_000) do
    wait_until(
      fn -> reports_in_flight() == [] end,
      timeout_ms,
      "the runner exit reports in flight"
    )
  end

  @doc """
  The runner exit reports the worker service of this VM holds in flight,
  by pid. The service holds a report from the callback that starts it,
  before the report has run, until it ends, and a report ends with the
  service that started it; the read is answered between the service's
  callbacks, so it misses none.
  """
  @spec reports_in_flight() :: [pid()]
  def reports_in_flight,
    do: Map.keys(:sys.get_state(Locus.Runtime.WorkerService).reports)

  @doc """
  Keeps `socket` open past the test's end until the control port of the
  runner process `runner` has left the port table, and closes it then.
  `socket` is the one whose descriptor the test gave that runner
  (`Locus.Runtime.Runner`); the test calls this once the runner runs, and
  does not close the socket itself.

  The port polls a descriptor it does not own. A port can outlive its
  owner, writing out what it was given first, and has stopped polling only
  once it has left the port table: a descriptor closed before then is
  reused by the next test's sockets, and the port's late release takes the
  descriptor from them.

  A socket closes with the process that owns it, and the test process has
  exited before any `on_exit` callback runs: ExUnit runs them once the
  test's supervisor is down, which goes down with the test process it is
  linked to. So the socket is given to a process of this fixture's, which
  closes it when the callback has seen the port gone.
  """
  @spec control_gone_at_exit(:socket.socket(), pid()) :: :ok
  def control_gone_at_exit(socket, runner) when is_pid(runner) do
    [control] =
      for port <- Port.list(), Port.info(port, :connected) == {:connected, runner}, do: port

    keeper =
      spawn(fn ->
        receive do
          {:close, from} -> send(from, {self(), :socket.close(socket)})
        end
      end)

    :ok = :socket.setopt(socket, {:otp, :controlling_process}, keeper)

    ExUnit.Callbacks.on_exit(fn ->
      try do
        port_gone(control)
        # The descriptor was the port's alone until now.
        {:ok, _descriptor} = :socket.getopt(socket, {:otp, :fd})
      after
        send(keeper, {:close, self()})

        receive do
          {^keeper, _closed} -> :ok
        end
      end
    end)
  end

  @doc "Until `port` has left the port table, five seconds at most."
  @spec port_gone(port()) :: :ok
  def port_gone(port) when is_port(port) do
    wait_until(
      fn -> port not in Port.list() end,
      5_000,
      "#{inspect(port)} to leave the port table"
    )
  end
end
