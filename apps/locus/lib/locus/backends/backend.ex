# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.Backend do
  @moduledoc """
  One stdio MCP backend of one owner (an athanor's server row at a
  generation and epoch): its process, started through a `Locus.Launcher`,
  and the calls it answers.

  ## Starting

  The backend's command runs as `["/bin/sh", "-c", command]` in the uid
  pool `backends`, its environment the definition's `env` block alone
  (the launcher adds its own `HOME`, `TMPDIR`, `USER`, `LOGNAME` and
  `PATH`). Once spawned it is initialized at protocol revision
  `2025-03-26`, told `notifications/initialized`, and asked `tools/list`;
  its answer is the backend's tools and the backend is `ready`. Until
  then it is `starting`. A handshake refused or not answered within its
  bound ends the process, whose exit is then a crash.

  ## Crashes

  A process that exits, or that a launcher refuses, is a crash: its tools
  are withdrawn, every call awaiting it fails, and it is started again
  after the next wait of `Prima.LocusBackends.restart_backoff_ms/0`,
  `starting` meanwhile with the crash as its `error`. The
  `max_crashes/0`-th crash within `crash_window_ms/0` marks it `failed`,
  and it is not started again. A stdout line longer than
  `max_frame_bytes/0` kills the process; that exit is a crash like any
  other.

  ## Idle

  `retire_idle/1` ends a `ready` backend with no call awaiting it: its
  process is released with the stop grace, its tools stay listed, and it
  is `idle`. The next call wakes it: the process is started again once
  the last one is retired, and every call that arrives meanwhile shares
  that one start, then goes to the backend once it is ready.

  ## Stopping

  `stop/2` releases the process with a grace, fails every call awaiting
  it and answers once the launcher reports the process retired, or the
  grace and the release bound pass. A stopped backend stays `stopped`.

  ## Calls

  `call_tool/4` writes a `tools/call` under an id the backend's relay
  (`Locus.Backends.Relay`) minted, and answers the result, the backend's
  own error, or a refusal once the call's timeout passes. At most
  `max_in_flight/0` calls await one backend. The backend's own requests
  are answered `-32601` and never answer a call. A backend that is
  `failed`, `stopped` or still `starting` refuses a call, in the MCP
  bridge's words.

  ## Masking

  Everything this process answers — a result, an error, a refusal, the
  tools, the stderr tail — passes through `Prima.LocusBackends.mask/2`
  with the owner's secret values: every value of its environment but
  those `literal_env_names/0` names, unless the owner hands its own.
  Nothing of a backend's stdout or stderr is logged.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Locus.Backends.Relay
  alias Prima.LocusBackends

  @protocol_version "2025-03-26"
  @pool "backends"

  @defaults %{
    rpc_timeout_ms: 30_000,
    init_timeout_ms: 15_000,
    spawn_timeout_ms: 15_000,
    stop_grace_ms: 2_000,
    release_timeout_ms: 15_000
  }

  # A call's answer arrives within its own timeout, or a wake's and its
  # own; the caller's wait covers both and the retirement a wake follows.
  @call_margin_ms 60_000

  @typedoc "The owner a backend runs for."
  @type owner :: %{athanor: String.t(), server: String.t(), g: pos_integer(), e: pos_integer()}

  @typedoc "A backend as its sync defines it, its environment resolved."
  @type definition :: %{
          name: String.t(),
          command: String.t(),
          env: %{optional(String.t()) => String.t()}
        }

  @type status :: :starting | :ready | :idle | :failed | :stopped

  @typedoc "What `status/1` answers, masked."
  @type report :: %{
          status: status(),
          restarts: non_neg_integer(),
          tools: non_neg_integer(),
          error: String.t() | nil,
          stderr_tail: String.t()
        }

  @doc """
  Starts a backend. Options:

    * `:owner` (`t:owner/0`) and `:definition` (`t:definition/0`), required;
    * `:secrets`, the owner's secret values, every backend's; by default
      the values of this backend's `env` but the literal ones;
    * `:launcher`, a `Locus.Launcher` (default `Locus.Executor.launcher/0`'s),
      and `:launcher_server`, the server it is reached at (default the
      module's registered name);
    * `:memory_bytes`, the bound each process is spawned under, if any;
    * `:bounds`, overriding `Prima.LocusBackends.bounds/0` by name;
    * `:rpc_timeout_ms` (30 s), `:init_timeout_ms` (15 s),
      `:spawn_timeout_ms` (15 s), `:stop_grace_ms` (2 s),
      `:release_timeout_ms` (15 s);
    * `:name`.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "The backend's state, masked."
  @spec status(GenServer.server()) :: report()
  def status(server), do: GenServer.call(server, :status)

  @doc "The tools the backend last listed, as it listed them, masked."
  @spec list_tools(GenServer.server()) :: [map()]
  def list_tools(server), do: GenServer.call(server, :list_tools)

  @doc """
  Calls the backend's tool `tool` with `arguments`, waking it first when
  it is idle. Options: `:timeout_ms`, the call's own bound (the
  backend's `:rpc_timeout_ms` by default). A refusal is
  `{:error, {:tool_error, sentence}}`, answered as a tool's error.
  """
  @spec call_tool(GenServer.server(), String.t(), map() | nil, keyword()) ::
          {:ok, term()} | {:error, {:tool_error, String.t()}}
  def call_tool(server, tool, arguments, opts \\ []) when is_binary(tool) do
    timeout = Keyword.get(opts, :timeout_ms)

    GenServer.call(
      server,
      {:call_tool, tool, arguments || %{}, timeout},
      (timeout || @defaults.rpc_timeout_ms) + @call_margin_ms
    )
  end

  @doc """
  Retires a `ready` backend no call awaits: its process is released with
  the stop grace and it is `idle`, its tools kept. `{:error, :busy}` when
  a call awaits it; `{:error, status}` when it is not `ready`.
  """
  @spec retire_idle(GenServer.server()) :: :ok | {:error, :busy | status()}
  def retire_idle(server), do: GenServer.call(server, :retire_idle)

  @doc """
  Stops the backend: its process released with `grace_ms`, answered once
  it is retired or its bound passes.
  """
  @spec stop(GenServer.server(), non_neg_integer()) :: :ok
  def stop(server, grace_ms) when is_integer(grace_ms) and grace_ms >= 0,
    do: GenServer.call(server, {:stop, grace_ms}, grace_ms + @call_margin_ms)

  # ————— the server —————

  @impl GenServer
  def init(opts) do
    %{name: name, command: command, env: env} = Keyword.fetch!(opts, :definition)
    %{athanor: _, server: _, g: _, e: _} = owner = Keyword.fetch!(opts, :owner)

    case launcher(opts) do
      {:ok, launcher} ->
        bounds = Map.merge(LocusBackends.bounds(), Map.new(Keyword.get(opts, :bounds, [])))

        state = %{
          owner: owner,
          name: name,
          command: command,
          env: env,
          secrets: Keyword.get_lazy(opts, :secrets, fn -> secret_values(env) end),
          launcher: launcher,
          launcher_server: Keyword.get(opts, :launcher_server, launcher),
          memory_bytes: Keyword.get(opts, :memory_bytes),
          bounds: bounds,
          timeouts: Map.merge(@defaults, Map.new(Keyword.take(opts, Map.keys(@defaults)))),
          status: :starting,
          phase: :spawning,
          handle: nil,
          retiring: %{},
          relay: Relay.new(Map.take(bounds, [:max_frame_bytes, :stderr_tail_bytes])),
          relay_dead: false,
          tools: [],
          error: nil,
          init_error: nil,
          restarts: 0,
          crashes: [],
          restart_timer: nil,
          waking: false,
          waiters: [],
          wake_timer: nil,
          stoppers: []
        }

        {:ok, state, {:continue, :spawn}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp launcher(opts) do
    case Keyword.fetch(opts, :launcher) do
      {:ok, launcher} -> {:ok, launcher}
      :error -> Locus.Executor.launcher()
    end
  end

  defp secret_values(env) do
    literal = LocusBackends.literal_env_names()
    for {name, value} <- env, name not in literal, do: value
  end

  @impl GenServer
  def handle_continue(:spawn, state), do: {:noreply, spawn_process(state)}

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       status: state.status,
       restarts: state.restarts,
       tools: length(state.tools),
       error: mask(state.error, state),
       stderr_tail: Relay.stderr_tail(state.relay, state.secrets)
     }, state}
  end

  def handle_call(:list_tools, _from, state), do: {:reply, mask(state.tools, state), state}

  def handle_call({:call_tool, tool, arguments, timeout}, from, state) do
    call = %{from: from, tool: tool, arguments: arguments, timeout: timeout}

    cond do
      state.status == :idle or state.waking -> {:noreply, wake(state, call)}
      state.status == :ready -> {:noreply, send_call(state, call)}
      true -> {:reply, refusal(state, not_ready(state)), state}
    end
  end

  def handle_call(:retire_idle, _from, %{status: :ready} = state) do
    if state.waking or Relay.pending_count(state.relay) > 0,
      do: {:reply, {:error, :busy}, state},
      else: {:reply, :ok, retire_idle_process(state)}
  end

  def handle_call(:retire_idle, _from, state), do: {:reply, {:error, state.status}, state}

  def handle_call({:stop, grace_ms}, from, state) do
    state = stop_backend(state, grace_ms)

    if map_size(state.retiring) == 0,
      do: {:reply, :ok, state},
      else: {:noreply, %{state | stoppers: [from | state.stoppers]}}
  end

  @impl GenServer
  def handle_info({launcher, ref, event}, %{launcher: launcher} = state) do
    cond do
      state.handle != nil and ref == state.handle.ref -> {:noreply, on_event(state, event)}
      is_map_key(state.retiring, ref) -> {:noreply, on_retiring_event(state, ref, event)}
      true -> {:noreply, state}
    end
  end

  def handle_info({:rpc_timeout, ref, id}, %{handle: %{ref: ref}} = state) do
    case Relay.cancel(state.relay, id) do
      {nil, _relay} -> {:noreply, state}
      {tag, relay} -> {:noreply, timed_out(%{state | relay: relay}, tag)}
    end
  end

  def handle_info({:rpc_timeout, _ref, _id}, state), do: {:noreply, state}

  def handle_info({:restart, timer}, %{restart_timer: timer} = state) do
    {:noreply, spawn_process(%{state | restart_timer: nil, restarts: state.restarts + 1})}
  end

  def handle_info({:restart, _timer}, state), do: {:noreply, state}

  def handle_info({:wake_timeout, timer}, %{wake_timer: timer} = state) do
    {:noreply, fail_waiters(%{state | wake_timer: nil}, &did_not_start/1)}
  end

  def handle_info({:wake_timeout, _timer}, state), do: {:noreply, state}

  # A retirement the launcher never reported within its bound is taken as
  # done, as the bridge takes one.
  def handle_info({:retire_timeout, ref}, state) do
    if is_map_key(state.retiring, ref),
      do: {:noreply, retired(state, ref)},
      else: {:noreply, state}
  end

  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  # The environment and the owner's secrets are credentials, and a call's
  # arguments and the backend's stderr may carry one: no status or crash
  # report shows more of them than their size, and the debug log, which
  # holds them, is left out.
  @impl GenServer
  def format_status(status) do
    Map.new(status, fn
      {:state, %{env: env, secrets: secrets, relay: relay, waiters: waiters} = state} ->
        {:state,
         %{
           state
           | env: Map.new(env, fn {name, value} -> {name, {:redacted, byte_size(value)}} end),
             secrets: {:redacted, length(secrets)},
             relay: %{
               pending: Relay.pending_count(relay),
               dropped: Relay.dropped(relay),
               stderr: {:redacted, byte_size(relay.stderr)}
             },
             waiters: length(waiters)
         }}

      {:message, {:call_tool, tool, _arguments, timeout}} ->
        {:message, {:call_tool, tool, :redacted, timeout}}

      {:message, {launcher, ref, {stream, bytes}}} when stream in [:stdout, :stderr] ->
        {:message, {launcher, ref, {stream, {:redacted, byte_size(bytes)}}}}

      {:log, _log} ->
        {:log, []}

      other ->
        other
    end)
  end

  # ————— the process —————

  defp spawn_process(state) do
    spec =
      %{argv: ["/bin/sh", "-c", state.command], env: state.env, pool: @pool}
      |> then(
        &if state.memory_bytes, do: Map.put(&1, :memory_bytes, state.memory_bytes), else: &1
      )

    state = %{
      state
      | status: :starting,
        phase: :spawning,
        relay: Relay.restart(state.relay),
        relay_dead: false
    }

    case state.launcher.spawn(state.launcher_server, spec) do
      {:ok, handle} ->
        initialize(%{state | handle: handle, phase: :initializing})

      {:error, reason} ->
        crashed(%{state | handle: nil}, "spawn refused: #{refusal_code(reason)}")
    end
  end

  defp refusal_code({:refused, code}) when is_binary(code), do: code
  defp refusal_code({kind, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  defp refusal_code(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp refusal_code(_reason), do: "spawn_failed"

  defp initialize(state) do
    params = %{
      protocolVersion: @protocol_version,
      capabilities: %{},
      clientInfo: %{name: "cyfr-locus", version: version()}
    }

    rpc(state, "initialize", params, {:init, "initialize"}, state.timeouts.init_timeout_ms)
  end

  defp version do
    case Application.spec(:locus, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  # Writes a call under a newly minted id, pending until its answer or its
  # timeout; a call the process cannot be written to fails at once.
  defp rpc(state, method, params, tag, timeout_ms) do
    {line, id, relay} = Relay.request(state.relay, method, params, tag)
    Process.send_after(self(), {:rpc_timeout, state.handle.ref, id}, timeout_ms)
    state = %{state | relay: relay}

    case state.launcher.send(state.handle, line) do
      :ok ->
        state

      {:error, _reason} ->
        {tag, relay} = Relay.cancel(state.relay, id)
        failed_write(%{state | relay: relay}, tag, method)
    end
  end

  defp failed_write(state, {:init, _method} = tag, method),
    do: init_failed(state, tag, "backend stdin unavailable: #{method}")

  defp failed_write(state, {:call, call}, method) do
    reply(call, refusal(state, call_failed(state, "backend stdin unavailable: #{method}")))
    state
  end

  defp on_event(state, :attached), do: state

  defp on_event(state, {:stdout, _bytes}) when state.relay_dead, do: state

  defp on_event(state, {:stdout, bytes}) do
    case Relay.stdout(state.relay, bytes) do
      {:ok, events, relay} -> Enum.reduce(events, %{state | relay: relay}, &on_message/2)
      {:error, :frame_too_large} -> overflow(state)
    end
  end

  defp on_event(state, {:stderr, bytes}), do: %{state | relay: Relay.stderr(state.relay, bytes)}

  defp on_event(state, {:exited, code, signal}) do
    handle = state.handle

    state
    |> retiring(handle.ref)
    |> Map.put(:handle, nil)
    |> crashed("exited code=#{spelled(code)} signal=#{spelled(signal)}")
  end

  # Released without an exit: the launcher retired every spawn it held.
  defp on_event(state, :released),
    do: crashed(%{state | handle: nil}, "exited code=null signal=null")

  defp on_event(state, _event), do: state

  defp spelled(nil), do: "null"
  defp spelled(value), do: to_string(value)

  # A retired process's stderr still belongs to the backend's tail; the
  # rest of what it says is past.
  defp on_retiring_event(state, _ref, {:stderr, bytes}),
    do: %{state | relay: Relay.stderr(state.relay, bytes)}

  defp on_retiring_event(state, ref, :released), do: retired(state, ref)
  defp on_retiring_event(state, _ref, _event), do: state

  defp overflow(state) do
    Logger.error(
      "[Locus.Backends.Backend] #{label(state)}: a stdout frame exceeded " <>
        "#{state.bounds.max_frame_bytes} bytes; killing the backend"
    )

    _ = state.launcher.signal(state.handle, "SIGKILL")
    %{state | relay_dead: true, error: "stdout frame overflow"}
  end

  # The backend's own request is answered as one this side does not
  # serve; its notification is not answered.
  defp on_message({:child, nil, _method}, state), do: state

  defp on_message({:child, id, method}, state) do
    line = Relay.reply_error(id, -32_601, "method not supported by bridge: #{method}")
    _ = state.launcher.send(state.handle, line)
    state
  end

  defp on_message({:answer, {:init, "initialize"}, {:result, _result}}, state) do
    _ = state.launcher.send(state.handle, Relay.notification("notifications/initialized"))
    rpc(state, "tools/list", nil, {:init, "tools/list"}, state.timeouts.init_timeout_ms)
  end

  defp on_message({:answer, {:init, "tools/list"}, {:result, result}}, state) do
    tools =
      case result do
        %{"tools" => tools} when is_list(tools) -> tools
        _ -> []
      end

    ready(%{state | tools: tools})
  end

  defp on_message({:answer, {:init, _method} = tag, {:error, error}}, state),
    do: init_failed(state, tag, "initialize refused: #{error_text(error)}")

  defp on_message({:answer, {:call, call}, {:result, result}}, state) do
    reply(call, {:ok, mask(result, state)})
    state
  end

  defp on_message({:answer, {:call, call}, {:error, error}}, state) do
    reply(call, refusal(state, error_text(error)))
    state
  end

  defp timed_out(state, {:init, method} = tag), do: init_failed(state, tag, "timeout: #{method}")

  defp timed_out(state, {:call, call}) do
    reply(call, refusal(state, call_failed(state, "timeout: tools/call")))
    state
  end

  # A handshake that did not finish ends the process; its exit is the
  # crash, and names why.
  defp init_failed(%{phase: :initializing, handle: handle} = state, _tag, text)
       when handle != nil do
    Logger.error("[Locus.Backends.Backend] #{label(state)}: initialize failed")
    :ok = state.launcher.release(state.launcher_server, handle, 0)
    %{state | init_error: text, phase: :ending}
  end

  defp init_failed(state, _tag, _text), do: state

  defp ready(state) do
    Logger.info("[Locus.Backends.Backend] #{label(state)}: ready, #{length(state.tools)} tools")
    state = %{state | status: :ready, phase: nil, error: nil}

    calls = Enum.reverse(state.waiters)
    state = %{state | waking: false, waiters: [], wake_timer: nil}
    Enum.reduce(calls, state, &send_call(&2, &1))
  end

  defp crashed(%{status: status} = state, _reason) when status in [:stopped, :failed],
    do: fail_pending(state, "backend stopped")

  defp crashed(state, reason) do
    error = if state.init_error, do: "#{state.init_error}; #{reason}", else: reason

    state =
      %{state | error: error, init_error: nil, tools: [], phase: :crashed}
      |> fail_pending(reason)
      |> fail_waiters(&did_not_start/1)

    now = System.monotonic_time(:millisecond)
    crashes = [now | Enum.filter(state.crashes, &(now - &1 < state.bounds.crash_window_ms))]
    state = %{state | crashes: crashes}

    if length(crashes) >= state.bounds.max_crashes do
      Logger.error(
        "[Locus.Backends.Backend] #{label(state)}: failed after #{length(crashes)} crashes"
      )

      %{state | status: :failed, phase: nil}
    else
      backoff = state.bounds.restart_backoff_ms
      delay = Enum.at(backoff, min(length(crashes), length(backoff)) - 1)

      Logger.error("[Locus.Backends.Backend] #{label(state)}: crashed; restarting in #{delay} ms")

      timer = make_ref()
      Process.send_after(self(), {:restart, timer}, delay)
      %{state | status: :starting, phase: :backoff, restart_timer: timer}
    end
  end

  # ————— idle, wake and stop —————

  defp retire_idle_process(state) do
    Logger.info("[Locus.Backends.Backend] #{label(state)}: idle; retiring until its next call")

    :ok =
      state.launcher.release(state.launcher_server, state.handle, state.timeouts.stop_grace_ms)

    state
    |> retiring(state.handle.ref)
    |> Map.merge(%{handle: nil, status: :idle, phase: nil})
  end

  # Every call that finds the backend idle, or waking, waits on one start,
  # made once the process it replaces is retired.
  defp wake(%{waking: true} = state, call), do: %{state | waiters: [call | state.waiters]}

  defp wake(state, call) do
    state = %{state | waking: true, waiters: [call]}
    if map_size(state.retiring) == 0, do: start_wake(state), else: state
  end

  defp start_wake(state) do
    Logger.info("[Locus.Backends.Backend] #{label(state)}: starting for a call")
    timer = make_ref()
    wake_ms = state.timeouts.spawn_timeout_ms + state.timeouts.init_timeout_ms
    Process.send_after(self(), {:wake_timeout, timer}, wake_ms)
    spawn_process(%{state | wake_timer: timer})
  end

  defp stop_backend(state, grace_ms) do
    state =
      %{state | status: :stopped, phase: nil, restart_timer: nil, tools: []}
      |> fail_pending("backend stopped")
      |> fail_waiters(&did_not_start/1)

    case state.handle do
      nil ->
        state

      handle ->
        :ok = state.launcher.release(state.launcher_server, handle, grace_ms)
        state |> retiring(handle.ref, grace_ms) |> Map.put(:handle, nil)
    end
  end

  # A released process holds its uid until the launcher reports it retired,
  # or its bound passes.
  defp retiring(state, ref, grace_ms \\ nil) do
    grace_ms = grace_ms || state.timeouts.stop_grace_ms

    Process.send_after(
      self(),
      {:retire_timeout, ref},
      grace_ms + state.timeouts.release_timeout_ms
    )

    %{state | retiring: Map.put(state.retiring, ref, true)}
  end

  defp retired(state, ref) do
    state = %{state | retiring: Map.delete(state.retiring, ref)}

    cond do
      map_size(state.retiring) > 0 ->
        state

      state.stoppers != [] ->
        Enum.each(state.stoppers, &GenServer.reply(&1, :ok))
        %{state | stoppers: []}

      state.waking and state.status == :idle and state.wake_timer == nil ->
        start_wake(state)

      true ->
        state
    end
  end

  # ————— calls —————

  defp send_call(state, call) do
    in_flight = Relay.pending_count(state.relay)

    if in_flight >= state.bounds.max_in_flight do
      reply(call, refusal(state, "backend busy: #{in_flight} calls in flight"))
      state
    else
      timeout = call.timeout || state.timeouts.rpc_timeout_ms
      params = %{name: call.tool, arguments: call.arguments}
      rpc(state, "tools/call", params, {:call, call}, timeout)
    end
  end

  defp fail_pending(state, reason) do
    {tags, relay} = Relay.take_pending(state.relay)

    for {:call, call} <- tags,
        do: reply(call, refusal(state, call_failed(state, reason)))

    %{state | relay: relay}
  end

  defp fail_waiters(%{waiters: []} = state, _sentence), do: %{state | waking: false}

  defp fail_waiters(state, sentence) do
    text = sentence.(state)
    for call <- state.waiters, do: reply(call, refusal(state, text))
    %{state | waking: false, waiters: [], wake_timer: nil}
  end

  defp reply(%{from: from}, answer), do: GenServer.reply(from, answer)

  # ————— the bridge's sentences —————

  defp not_ready(state), do: "backend '#{state.name}' not ready: #{state.error || state.status}"

  defp did_not_start(state),
    do: "backend '#{state.name}' did not start: #{state.error || state.status}"

  defp call_failed(state, reason), do: "backend '#{state.name}' call failed: #{reason}"

  defp refusal(state, text), do: {:error, {:tool_error, mask(text, state)}}

  defp error_text(%{"message" => message}) when is_binary(message), do: message
  defp error_text(error), do: Jason.encode!(error)

  defp mask(value, state), do: LocusBackends.mask(value, state.secrets)

  defp label(state), do: "#{state.owner.athanor}/#{state.owner.server} #{state.name}"
end
