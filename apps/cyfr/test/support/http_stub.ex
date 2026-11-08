# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.HTTPStub do
  @moduledoc """
  An HTTP server a test scripts, on a free loopback port. Test-only.

  `open/0` listens on 127.0.0.1 (`port`) and registers an `on_exit` check
  that fails the test unless every expectation held:

    * `expect_once/2,4`: exactly one request; another is answered 500 and
      fails the test.
    * `expect/2,4`: one request or more.
    * `stub/4`: any number, none included.

  The four-argument forms answer one method at one path, matched whole and
  literally; the two-argument forms answer every request no route matches.
  Setting a route again replaces it. A request nothing answers is answered
  500 and fails the test, as does a function that raises or whose process
  dies mid-request. `pass/1` makes the check pass whatever the requests
  did. `down/1` stops the listener once the requests in flight have ended,
  so every later connection is refused.

  The check waits for the requests in flight, then stops the server. It
  runs after the test process has exited and after the test's later
  `on_exit` callbacks, and a sweep of the test's own processes may run
  before it (`Cyfr.Test.Sandbox`), so each server runs under the suite's
  supervisor (`serve!/0`, from the test helper) rather than the test's
  lineage, and stays up for them.

  One module plays both parts: this process holds the expectations, and
  Bandit serves this module as its plug, whose `init/1` takes the
  process's pid and whose `call/2` asks it what each request is owed.
  """

  use GenServer, restart: :temporary

  @supervisor Cyfr.Test.HTTPStub.Supervisor

  @enforce_keys [:server, :port]
  defstruct [:server, :port]

  @type t :: %__MODULE__{server: pid(), port: :inet.port_number()}
  @type answer :: (Plug.Conn.t() -> Plug.Conn.t())

  @doc "Start the suite's supervisor of the servers `open/0` starts, once, from the test helper."
  @spec serve!() :: :ok
  def serve! do
    {:ok, _supervisor} = DynamicSupervisor.start_link(name: @supervisor, strategy: :one_for_one)
    :ok
  end

  @doc false
  def start_link(:listen), do: GenServer.start_link(__MODULE__, :listen)

  @spec open() :: t()
  def open do
    {:ok, server} = DynamicSupervisor.start_child(@supervisor, {__MODULE__, :listen})
    stub = %__MODULE__{server: server, port: GenServer.call(server, :port)}
    ExUnit.Callbacks.on_exit({__MODULE__, server}, fn -> verify!(server) end)
    stub
  end

  @spec expect_once(t(), answer()) :: :ok
  def expect_once(%__MODULE__{} = stub, fun), do: put_route(stub, :any, :once, fun)

  @spec expect_once(t(), String.t(), String.t(), answer()) :: :ok
  def expect_once(%__MODULE__{} = stub, method, path, fun),
    do: put_route(stub, {method, path}, :once, fun)

  @spec expect(t(), answer()) :: :ok
  def expect(%__MODULE__{} = stub, fun), do: put_route(stub, :any, :once_or_more, fun)

  @spec expect(t(), String.t(), String.t(), answer()) :: :ok
  def expect(%__MODULE__{} = stub, method, path, fun),
    do: put_route(stub, {method, path}, :once_or_more, fun)

  @spec stub(t(), String.t(), String.t(), answer()) :: :ok
  def stub(%__MODULE__{} = stub, method, path, fun),
    do: put_route(stub, {method, path}, :any_number, fun)

  @spec pass(t()) :: :ok
  def pass(%__MODULE__{server: server}), do: GenServer.call(server, :pass)

  @spec down(t()) :: :ok
  def down(%__MODULE__{server: server}), do: GenServer.call(server, :down, :infinity)

  defp put_route(%__MODULE__{server: server}, route, expected, fun)
       when is_function(fun, 1),
       do: GenServer.call(server, {:route, route, expected, fun})

  defp verify!(server) do
    case GenServer.call(server, :verify, :infinity) do
      :ok -> :ok
      {:error, message} -> raise ExUnit.AssertionError, message: message
      {:raised, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  # The plug: Bandit's `init/1` is handed the server's pid.

  @impl GenServer
  def init(server) when is_pid(server), do: server

  def init(:listen) do
    {:ok, listener} =
      Bandit.start_link(
        plug: {__MODULE__, self()},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false,
        http_options: [compress: false]
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)

    {:ok,
     %{
       listener: listener,
       port: port,
       routes: %{},
       in_flight: %{},
       pass: false,
       unexpected: nil,
       awaiting_down: [],
       awaiting_verify: []
     }}
  end

  def call(conn, server) do
    conn = Plug.Conn.fetch_query_params(conn)

    case GenServer.call(server, {:request, conn.method, conn.request_path}, :infinity) do
      {:ok, ref, fun} ->
        try do
          fun.(conn)
        else
          conn ->
            GenServer.cast(server, {:result, ref, :ok})
            conn
        catch
          kind, reason ->
            GenServer.cast(server, {:result, ref, {:raised, kind, reason, __STACKTRACE__}})
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      :refused ->
        Plug.Conn.send_resp(conn, 500, "")
    end
  end

  # The server.

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call({:route, route, expected, fun}, _from, state) do
    entry = %{fun: fun, expected: expected, count: 0, results: []}
    {:reply, :ok, put_in(state.routes[route], entry)}
  end

  def handle_call({:request, method, path}, {caller, _tag}, state) do
    route = if Map.has_key?(state.routes, {method, path}), do: {method, path}, else: :any

    case state.routes do
      %{^route => %{expected: :once, count: count}} when count > 0 ->
        problem = {:error, "expected one request at #{describe(route)}, got another"}

        state =
          update_in(
            state.routes[route],
            &%{&1 | count: &1.count + 1, results: [problem | &1.results]}
          )

        {:reply, :refused, state}

      %{^route => %{fun: fun}} ->
        ref = Process.monitor(caller)
        state = update_in(state.routes[route], &%{&1 | count: &1.count + 1})
        {:reply, {:ok, ref, fun}, put_in(state.in_flight[ref], route)}

      %{} ->
        problem = {:error, "got a request at #{method} #{path} but expected none there"}
        {:reply, :refused, %{state | unexpected: state.unexpected || problem}}
    end
  end

  def handle_call(:pass, _from, state) do
    for {ref, _route} <- state.in_flight, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, settle(%{state | pass: true, in_flight: %{}})}
  end

  def handle_call(:down, from, state),
    do: settle(%{state | awaiting_down: [from | state.awaiting_down]}) |> after_settle()

  def handle_call(:verify, from, state),
    do: settle(%{state | awaiting_verify: [from | state.awaiting_verify]}) |> after_settle()

  @impl GenServer
  def handle_cast({:result, ref, result}, state) do
    Process.demonitor(ref, [:flush])
    state |> record(ref, result) |> settle() |> after_settle()
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, state),
    do: state |> record(ref, {:raised, :exit, reason, []}) |> settle() |> after_settle()

  defp record(state, ref, result) do
    case Map.pop(state.in_flight, ref) do
      {nil, _} ->
        state

      {route, in_flight} ->
        state = %{state | in_flight: in_flight}

        if Map.has_key?(state.routes, route),
          do: update_in(state.routes[route].results, &[result | &1]),
          else: state
    end
  end

  # Once nothing is in flight, the listener stops for each `down/1` waiting
  # and the check answers each `verify` waiting.
  defp settle(%{in_flight: in_flight} = state) when map_size(in_flight) > 0, do: state

  defp settle(state) do
    state =
      case state.awaiting_down do
        [] ->
          state

        callers ->
          state = stop_listener(state)
          Enum.each(callers, &GenServer.reply(&1, :ok))
          %{state | awaiting_down: []}
      end

    case state.awaiting_verify do
      [] ->
        state

      callers ->
        state = stop_listener(state)
        result = verdict(state)
        Enum.each(callers, &GenServer.reply(&1, result))
        %{state | awaiting_verify: :answered}
    end
  end

  defp after_settle(%{awaiting_verify: :answered} = state), do: {:stop, :normal, state}
  defp after_settle(state), do: {:noreply, state}

  # Stopping the listener closes its socket and its connections before it
  # returns, so a connection after it is refused.
  defp stop_listener(%{listener: nil} = state), do: state

  defp stop_listener(%{listener: listener} = state) do
    :ok = ThousandIsland.stop(listener)
    %{state | listener: nil}
  end

  defp verdict(%{pass: true}), do: :ok
  defp verdict(%{unexpected: {:error, _} = problem}), do: problem

  defp verdict(state) do
    uncalled =
      Enum.find(state.routes, fn {_route, entry} ->
        entry.expected != :any_number and entry.results == []
      end)

    case uncalled do
      {route, _entry} ->
        {:error, "expected a request at #{describe(route)}, got none"}

      nil ->
        Enum.find_value(state.routes, :ok, fn {_route, entry} ->
          Enum.find(entry.results, &(&1 != :ok))
        end)
    end
  end

  defp describe(:any), do: "any route"
  defp describe({method, path}), do: "#{method} #{path}"
end
