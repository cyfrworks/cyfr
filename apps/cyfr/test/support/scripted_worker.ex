# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.ScriptedWorker do
  @moduledoc """
  A worker service (`Prima.WorkerAPI`) whose runners answer from a script
  instead of running a component. Configure it with `workers/2` inside the
  test; users are `async: false`, since the script is one named process.

  Everything but the component is real. This worker service has an id of
  its own (`service/0`) and a boot of its own, and its keys are its own: it
  never answers as the real worker service. It is served over HTTP by
  `Cyfr.Test.ScriptedWorkerListener` on a loopback port of its own, so
  `Crucible.Dispatch` reaches it through
  `Crucible.WorkerClient` exactly as it reaches Opus: `endpoint/0`
  is where. A run of a scripted reference is admitted by CYFR and
  dispatched here; `start/3` checks the assignment is addressed to this
  worker service and this boot, its input matches its digest and its
  sealed keys open as its attempt, then starts a runner. The runner
  reaches its attempt over HTTP, through a real `Crucible.HostListener`,
  as Opus's runners do: at the address its assignment names, or, for an
  assignment naming none, at the listener this worker service starts on a
  loopback port of its own (`host_url/0`). Each call's body is the
  versioned request (`Prima.WorkerWire.request_body/2`) sealed under the
  attempt's seal key, its header is signed with the attempt's call key
  over the sealed bytes, and its answer is opened and read at this wire's
  version (`Prima.WorkerWire.read_answer/1`), so every scripted run
  crosses the listener's checks before the body, the seal and the
  versioned bodies. The runner attaches with the signed assignment (the
  claim, and the unseal of the run's vault edge), records the call with
  the authority its assignment carries, pushes the script's events
  (`push_deltas`, masked by the attempt) and closes the run (`complete` or
  `fail`). A runner that exits leaving its attempt open is reported
  (`runner_exited`), plain, signed with this worker service's dispatch
  key and posted to the same listener. A report runs beside the worker
  service and is watched until it is answered: `await_reports/1` answers
  once none is in flight, and the worker service stops only once every
  report it made is answered, so a report a test's end left in flight
  lands while the test's sandbox owner still holds the connection.

  Its status counts its runners as every worker service does: `busy` while
  a run's process is alive, and `tainted` from a kill until the killed
  process has gone; it keeps no runner fresh or idle, bounds no runner's
  memory and never refuses one. Its kill is idempotent as
  `c:Prima.WorkerAPI.kill/1` says: `:ok` for an execution a runner of this
  boot holds or already ended, whether by a kill or on its own, and
  `{:error, :not_found}` only for one no runner of this boot ever held,
  which CYFR counts as nothing whose native work may still run. A reference it does
  not script never reaches it: starting it puts an
  entry for its scripted references alone ahead of the configured worker
  services in `config :cyfr, :opus_workers` (`workers/2`), so
  `Crucible.Dispatch` routes every other reference to the worker
  services configured after it, and stopping it removes that entry. Tests
  that change `:opus_workers` themselves restore it on exit as they do today.
  Started for a reference the routing did not name, it refuses the
  assignment `:malformed`.

  A script is a list consumed in order across runs. A run takes items
  until it reaches an answer:

  - `%{...}` — the `model/chat@1` data the run answers, completed as the
    envelope `%{"status" => 200, "data" => data}`.
  - `{:error, message}` — the run fails with `message`.
  - `{:refuse, %{"type", "message"}}` — the run completes with the
    contract's typed refusal as its envelope,
    `%{"status" => 429, "error" => error}`.
  - `{:emit, events}` — push the events (maps) on the run's stream before
    the next item.
  - `{:sleep, ms}` — wait before the next item.
  - `{:probe, pid}` — send `{:scripted_probe, runner, execution_id}` to
    `pid` and wait for `:continue` (5 s), so a test can inspect what the
    run holds while it runs.
  - `{:crash, :before_response}` — kill the process waiting on the run,
    once the runner has attached, and wait to be killed.
  - `{:crash, :after_persist}` — kill the process waiting on the run once
    the next answer is written, before that process can return it.
  - `:hang` — never answer.

  The process waiting on a run is the one registered under its execution
  id in `Crucible.Registry` when the run is started, as dispatch
  registers its waiter before it starts a run.

  The catalyst's answers about itself are not the script's: a run's input
  `%{"operation" => "describe"}` is answered with its description, and
  `%{"operation" => "models"}` with no models.

  Started with `lose_start_answer: true`, `start/3` starts the runner,
  waits for it to attach, and then answers `{:error, :lost}` in place of
  `:ok`: what CYFR sees of a start whose answer a transport lost after the
  worker service acted.
  """

  @behaviour Prima.WorkerAPI

  use GenServer

  require Logger

  alias Prima.{Assignment, HostAPI, WorkerAuth, WorkerWire}
  alias Crucible.{HostListener, Keys}
  alias Cyfr.Test.ScriptedWorkerListener

  @attempt_fields [:athanor_id, :execution_id, :attempt, :fence, :generation]
  @probe_wait_ms 5_000
  @attach_wait_ms 5_000
  # A report's post is bounded by its callback's timeout; this is past it.
  @report_wait_ms HostAPI.request_timeout_ms(:runner_exited) + 5_000
  @service "wrk_scripted"
  # A loopback port nothing listens on (as `config/test.exs` names the
  # registry): the endpoint of this worker service while it is not started.
  @unserved "http://127.0.0.1:19"

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      # Long enough for `terminate/2` to see every report in flight answered.
      shutdown: @report_wait_ms + 1_000
    }
  end

  @doc "This worker service's configured id."
  @spec service() :: String.t()
  def service, do: @service

  @doc """
  The base URL this worker service's listener answers on while it runs,
  and a loopback URL nothing answers on otherwise.
  """
  @spec url() :: String.t()
  def url do
    case Process.whereis(__MODULE__) do
      nil -> @unserved
      pid -> GenServer.call(pid, :url)
    end
  end

  @doc """
  The base URL of the host listener this worker service started, where a
  runner of an assignment naming no address posts its calls. Only while
  it runs.
  """
  @spec host_url() :: String.t()
  def host_url, do: GenServer.call(__MODULE__, :host_url)

  @doc """
  This worker service's endpoint (`t:Prima.WorkerAPI.endpoint/0`), running
  any reference: what a test hands an attempt as its `:worker`.
  """
  @spec endpoint() :: Prima.WorkerAPI.endpoint()
  def endpoint, do: %{id: @service, url: url(), components: nil}

  @doc """
  The `config :cyfr, :opus_workers` list that routes the scripted `refs` (any
  form `Prima.ComponentRef.to_name_ref/1` reads) to this worker service and
  every other reference to the worker services in `configured` (the list
  being replaced, with any earlier entry of this worker service dropped).
  """
  @spec workers([String.t()] | String.t(), [map()] | nil) :: [map()]
  def workers(refs, configured), do: entries(names(refs), configured, url())

  defp entries(names, configured, url) do
    others = Enum.reject(configured || [], &(is_map(&1) and &1[:id] == @service))
    [%{id: @service, url: url, components: names} | others]
  end

  defp names(refs) do
    refs
    |> List.wrap()
    |> Enum.map(fn ref ->
      {:ok, name} = Prima.ComponentRef.to_name_ref(ref)
      name
    end)
  end

  @doc """
  Start the worker service: `ref:` the scripted reference (or a list),
  `script:` its items, `window:` the context window a description answers
  for any model (default 200_000), `describe:` `{:refuse, error}` to have
  a described model refused instead, `lose_start_answer:` true to answer
  every start `{:error, :lost}` once its runner attached.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Replace the remaining script."
  def script(items) when is_list(items), do: GenServer.call(__MODULE__, {:script, items})

  @doc "Every scripted run that attached, oldest first: `%{execution_id, input, authority}`."
  def calls, do: GenServer.call(__MODULE__, :calls)

  @doc "Every execution id this worker service was asked to kill, oldest first."
  def kills, do: GenServer.call(__MODULE__, :kills)

  @doc """
  Answer once every runner exit this worker service is reporting has been
  answered by CYFR or given up on; at once when none is in flight.
  """
  @spec await_reports(timeout()) :: :ok
  def await_reports(timeout_ms \\ @report_wait_ms),
    do: GenServer.call(__MODULE__, :await_reports, timeout_ms)

  @doc """
  `ctx` moved into an athanor minted for the calling test alone: an
  active group row under an id no other test names, so the node-global
  state keyed by athanor (`Prima.Slots`'s unreaped kills, the consented
  rate windows, the slot counts) holds this test's runs and nobody
  else's. The row is written through the test's own sandbox checkout.
  """
  @spec athanor!(Sanctum.Context.t()) :: Sanctum.Context.t()
  def athanor!(%Sanctum.Context{} = ctx) do
    n = System.unique_integer([:positive])

    {:ok, %{id: athanor_id, status: "active"}} =
      Sanctum.Tenancy.Athanors.create(%{
        id: "ath_scripted_#{n}",
        kind: "group",
        name: "Scripted #{n}",
        slug: "scripted-#{n}",
        created_by: "system"
      })

    %{ctx | athanor_id: athanor_id}
  end

  @doc """
  Start the context's athanor on fresh execution limits: a fresh consented
  rate window (`Crucible.Rates`) for the pinned releases of `refs`,
  and no unreaped-kill penalty (`Prima.Slots.forgive_unreaped/2`).
  Scripted runs are admitted, and their runners killed, for real, so every
  test sharing an athanor draws on the same limits.
  """
  def fresh_limits!(%Sanctum.Context{} = ctx, refs) when is_list(refs) do
    for ref <- refs do
      {:ok, pinned, _resolution} = Compendium.Resolver.resolve(ctx, ref)
      :ok = Crucible.Rates.reset(Sanctum.Context.actor(ctx), pinned)
    end

    :ok = Prima.Slots.forgive_unreaped(Crucible.Slots, ctx.athanor_id)
  end

  # ---------------------------------------------------------------------------
  # Prima.WorkerAPI
  # ---------------------------------------------------------------------------

  @impl Prima.WorkerAPI
  def start(token, input, sealed_keys)
      when is_binary(token) and is_binary(input) and is_binary(sealed_keys) do
    case GenServer.call(__MODULE__, {:start, token, input, sealed_keys}) do
      {:ok, :answered} -> :ok
      {:ok, {:lose_once_attached, execution_id}} -> lose_once_attached(execution_id)
      {:error, :malformed} -> {:error, :malformed}
    end
  end

  @impl Prima.WorkerAPI
  def kill(execution_id) when is_binary(execution_id),
    do: GenServer.call(__MODULE__, {:kill, execution_id})

  @impl Prima.WorkerAPI
  def status, do: {:ok, GenServer.call(__MODULE__, :status)}

  # The lost answer of a start the worker service acted on: answered once
  # the runner attached, so a test sees the reconciliation and not a race.
  defp lose_once_attached(execution_id) do
    Prima.Test.Wait.wait_until(
      fn -> Enum.any?(calls(), &(&1.execution_id == execution_id)) end,
      @attach_wait_ms,
      "the runner of #{execution_id} attached"
    )

    {:error, :lost}
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    # Trapped, so a runner's exit arrives as a message and the runners go
    # with this process.
    Process.flag(:trap_exit, true)

    refs = names(Keyword.fetch!(opts, :ref))
    {:ok, listener} = ScriptedWorkerListener.start_link(worker: __MODULE__, service: @service)
    url = ScriptedWorkerListener.url(listener)

    # The host listener its runners reach CYFR at: the real one, on a port
    # of its own. Its drain is short, since the runners go first.
    %{start: {module, function, args}} = HostListener.child_spec(port: 0, drain_ms: 1_000)
    {:ok, host_listener} = apply(module, function, args)

    # Route the scripted references here and everything else to the worker
    # services configured before; `terminate/2` takes the entry out again.
    Application.put_env(
      :cyfr,
      :opus_workers,
      entries(refs, Application.get_env(:cyfr, :opus_workers), url)
    )

    {:ok,
     %{
       boot: "#{node()}#" <> Prima.UUID7.generate_id("boot"),
       listener: listener,
       url: url,
       host_listener: host_listener,
       host_url: "http://127.0.0.1:#{HostListener.port(host_listener)}",
       refs: refs,
       script: Keyword.get(opts, :script, []),
       window: Keyword.get(opts, :window, 200_000),
       describe: Keyword.get(opts, :describe, :answer),
       lose_start_answer: Keyword.get(opts, :lose_start_answer, false) == true,
       calls: [],
       kills: [],
       runners: %{},
       # The reports in flight, by monitor, and who waits for none to be.
       reports: MapSet.new(),
       report_waiters: [],
       # The executions whose runner has ended on this boot: a kill of one
       # is `:ok` again, as a real worker service answers it.
       ended: MapSet.new(),
       tainted: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:start, token, input, sealed_keys}, _from, state) do
    with {:ok, assignment} <- Assignment.read(token),
         true <- scripted?(state, assignment.component.ref),
         true <- assignment.service == @service and assignment.boot == state.boot,
         true <- Prima.Digest.sha256(input) == assignment.input_digest,
         {:ok, worker_key} <- Keys.opus_key(@service),
         {:ok, %{attempt: attempt} = keys} <-
           WorkerAuth.open_attempt_keys(WorkerAuth.dispatch_seal_key(worker_key), sealed_keys),
         true <- attempt == assignment |> Map.take(@attempt_fields) |> Map.put(:service, @service),
         {:ok, %{} = decoded} <- Jason.decode(input) do
      waiter = waiter_of(assignment.execution_id)

      runner = %{
        token: token,
        assignment: assignment,
        input: decoded,
        keys: keys,
        boot: state.boot,
        runner: Prima.UUID7.generate_id("runner"),
        host_url: assignment.host_url || state.host_url,
        waiter: waiter
      }

      pid = spawn_link(fn -> run(runner) end)

      runners =
        Map.put(state.runners, pid, %{
          execution_id: assignment.execution_id,
          attempt: assignment.attempt,
          boot: state.boot,
          member: assignment.member,
          runner: runner.runner,
          host_url: runner.host_url
        })

      answer =
        if state.lose_start_answer,
          do: {:lose_once_attached, assignment.execution_id},
          else: :answered

      {:reply, {:ok, answer}, %{state | runners: runners}}
    else
      _refused -> {:reply, {:error, :malformed}, state}
    end
  end

  def handle_call({:kill, execution_id}, _from, state) do
    state = %{state | kills: [execution_id | state.kills]}

    case Enum.find(state.runners, fn {_pid, runner} -> runner.execution_id == execution_id end) do
      {pid, _runner} ->
        # Tainted until its exit arrives: never assigned again, and counted.
        Process.exit(pid, :kill)
        {:reply, :ok, %{state | tainted: MapSet.put(state.tainted, pid)}}

      nil ->
        # A runner of this boot that already ended, by a kill or on its own,
        # is `:ok` again; only an execution no runner of this boot ever held
        # is `:not_found`.
        if MapSet.member?(state.ended, execution_id),
          do: {:reply, :ok, state},
          else: {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:status, _from, state) do
    attempts = for {_pid, runner} <- state.runners, do: runner.attempt
    tainted = MapSet.size(state.tainted)

    {:reply,
     %{
       service: @service,
       boot: state.boot,
       runners: %{
         fresh: 0,
         idle: 0,
         busy: map_size(state.runners) - tainted,
         tainted: tainted
       },
       attempts: attempts,
       memory_bytes: nil,
       refusal: nil
     }, state}
  end

  def handle_call(:url, _from, state), do: {:reply, state.url, state}
  def handle_call(:host_url, _from, state), do: {:reply, state.host_url, state}
  def handle_call({:script, items}, _from, state), do: {:reply, :ok, %{state | script: items}}
  def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}
  def handle_call(:kills, _from, state), do: {:reply, Enum.reverse(state.kills), state}

  def handle_call(:await_reports, from, state),
    do: {:noreply, reported(%{state | report_waiters: [from | state.report_waiters]})}

  def handle_call(:settings, _from, state),
    do: {:reply, Map.take(state, [:window, :describe]), state}

  def handle_call(:take, _from, %{script: []} = state), do: {:reply, nil, state}

  def handle_call(:take, _from, %{script: [item | rest]} = state),
    do: {:reply, item, %{state | script: rest}}

  def handle_call({:called, call}, _from, state),
    do: {:reply, :ok, %{state | calls: [call | state.calls]}}

  @impl true
  def handle_info({:EXIT, listener, reason}, %{listener: listener} = state),
    do: {:stop, {:listener_exited, reason}, state}

  def handle_info({:EXIT, listener, reason}, %{host_listener: listener} = state),
    do: {:stop, {:host_listener_exited, reason}, state}

  def handle_info({:EXIT, pid, reason}, state) do
    case Map.pop(state.runners, pid) do
      {nil, _runners} ->
        {:noreply, state}

      {runner, runners} ->
        state = if reason != :normal, do: report(state, runner), else: state

        {:noreply,
         %{
           state
           | runners: runners,
             ended: MapSet.put(state.ended, runner.execution_id),
             tainted: MapSet.delete(state.tainted, pid)
         }}
    end
  end

  # A report in flight has been answered, or given up on.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    if MapSet.member?(state.reports, ref),
      do: {:noreply, reported(%{state | reports: MapSet.delete(state.reports, ref)})},
      else: {:noreply, state}
  end

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    for {pid, _runner} <- state.runners, do: Process.exit(pid, :kill)

    # Every report made is answered before this worker service and its host
    # listener go: stopped at a test's end, before the test's `on_exit`
    # callbacks, it has the reports land while the sandbox owner still holds
    # the connection.
    await_in_flight(state.reports, System.monotonic_time(:millisecond) + @report_wait_ms)

    # The host listener is stopped here rather than left to the link, so
    # no call a runner had in flight is still reaching the store once this
    # worker service is gone. The worker listener, linked, goes with this
    # process.
    stop_host_listener(state.host_listener)
    configured = Application.get_env(:cyfr, :opus_workers, [])
    Application.put_env(:cyfr, :opus_workers, Enum.reject(configured, &(&1[:id] == @service)))
    :ok
  end

  defp await_in_flight(reports, deadline) do
    if MapSet.size(reports) == 0 do
      :ok
    else
      receive do
        {:DOWN, ref, :process, _pid, _reason} ->
          await_in_flight(MapSet.delete(reports, ref), deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> :ok
      end
    end
  end

  # Whoever waits for the reports in flight is answered once none is.
  defp reported(state) do
    if MapSet.size(state.reports) == 0 do
      for from <- state.report_waiters, do: GenServer.reply(from, :ok)
      %{state | report_waiters: []}
    else
      state
    end
  end

  defp stop_host_listener(listener) do
    Supervisor.stop(listener)
  catch
    :exit, _gone -> :ok
  end

  defp scripted?(state, reference) do
    case Prima.ComponentRef.to_name_ref(reference) do
      {:ok, name} -> name in state.refs
      {:error, _} -> false
    end
  end

  # The process waiting on the run: dispatch registers it under the
  # execution's id before it starts the run.
  defp waiter_of(execution_id) do
    case Registry.lookup(Crucible.Registry, execution_id) do
      [{waiter, _value}] -> waiter
      [] -> nil
    end
  end

  # A runner's exit is reported from a process of its own, over HTTP to
  # the host listener the runner reached, plain and signed with this worker
  # service's dispatch key, as Opus's worker service reports one. It is
  # watched until it ends, so `await_reports/1` and `terminate/2` can wait
  # for it.
  defp report(state, runner) do
    {_pid, ref} =
      spawn_monitor(fn ->
        body =
          :runner_exited
          |> WorkerWire.request_body(%{
            "member" => runner.member,
            "runner" => runner.runner,
            "attempts" => [runner.attempt]
          })
          |> Jason.encode!()

        fields = %{
          service: @service,
          boot: runner.boot,
          ts: System.system_time(:millisecond),
          nonce: nonce()
        }

        with {:ok, worker_key} <- Keys.opus_key(@service),
             {:ok, header} <-
               WorkerAuth.report_header(WorkerAuth.dispatch_key(worker_key), fields, body),
             {:ok, 200, raw} <- post(runner.host_url, :runner_exited, header, body),
             {:ok, true} <- read_answer(raw) do
          :ok
        else
          refused ->
            Logger.error(
              "[Cyfr.Test.ScriptedWorker] the exit of #{runner.execution_id}'s runner was not " <>
                "reported: #{Prima.LoggerContext.shape(refused)}"
            )
        end
      end)

    %{state | reports: MapSet.put(state.reports, ref)}
  end

  # ---------------------------------------------------------------------------
  # The runner
  # ---------------------------------------------------------------------------

  defp run(runner) do
    Prima.LoggerContext.set_execution_id(runner.assignment.execution_id)

    case attached(runner) do
      :normal -> :ok
      reason -> exit(reason)
    end
  end

  defp attached(runner) do
    case host(runner, :attach, %{"assignment" => runner.token}) do
      %{"ok" => %{}} ->
        case Prima.Authority.from_wire(runner.assignment.authority) do
          {:ok, authority} ->
            call = %{
              execution_id: runner.assignment.execution_id,
              input: runner.input,
              authority: authority
            }

            :ok = GenServer.call(__MODULE__, {:called, call})
            answer(runner, runner.input)

          {:error, _refusal} ->
            {:shutdown, :attempt_open}
        end

      %{"error" => "setup_required"} ->
        :normal

      _refused ->
        {:shutdown, :attempt_open}
    end
  end

  defp answer(runner, %{"operation" => "describe", "params" => params}) do
    case GenServer.call(__MODULE__, :settings) do
      %{describe: {:refuse, error}} ->
        complete(runner, %{"status" => 429, "error" => error})

      %{describe: :answer, window: window} ->
        complete(runner, %{"status" => 200, "data" => description(params, window)})
    end
  end

  defp answer(runner, %{"operation" => "models"}),
    do: complete(runner, %{"status" => 200, "data" => %{"models" => []}})

  defp answer(runner, _input), do: next(runner, false)

  defp next(runner, crash_after?) do
    case GenServer.call(__MODULE__, :take) do
      nil ->
        fail(runner, "script exhausted")

      {:emit, events} ->
        _ = host(runner, :push_deltas, %{"deltas" => Enum.map(events, &delta(runner, &1))})
        next(runner, crash_after?)

      {:sleep, ms} ->
        Process.sleep(ms)
        next(runner, crash_after?)

      {:probe, pid} ->
        send(pid, {:scripted_probe, self(), runner.assignment.execution_id})

        receive do
          :continue -> :ok
        after
          @probe_wait_ms -> :ok
        end

        next(runner, crash_after?)

      {:crash, :before_response} ->
        kill_waiter(runner)
        Process.sleep(:infinity)

      {:crash, :after_persist} ->
        next(runner, true)

      :hang ->
        Process.sleep(:infinity)

      {:error, message} ->
        fail(runner, message)

      {:refuse, %{"type" => _} = error} ->
        complete(runner, %{"status" => 429, "error" => error})

      %{} = data when crash_after? ->
        # Suspended, the waiter cannot return the answer the close sends it.
        if is_pid(runner.waiter), do: :erlang.suspend_process(runner.waiter)
        closed = complete(runner, %{"status" => 200, "data" => data})
        kill_waiter(runner)
        closed

      %{} = data ->
        complete(runner, %{"status" => 200, "data" => data})
    end
  end

  defp kill_waiter(%{waiter: waiter}) when is_pid(waiter), do: Process.exit(waiter, :kill)
  defp kill_waiter(_runner), do: :ok

  defp description(params, window) do
    model =
      case params do
        %{"model" => model} when is_binary(model) ->
          %{"model" => model, "context_window" => window}

        _ ->
          %{}
      end

    Map.merge(
      %{
        "contracts" => ["model/chat@1"],
        "provider" => "scripted",
        "tools" => true,
        "provider_tools" => [],
        "media_types" => ["image/png"],
        "streaming" => true,
        "defaults" => %{}
      },
      model
    )
  end

  defp complete(runner, output) do
    case host(runner, :complete, %{
           "outcome" => outcome(runner, "completed", %{"output" => output})
         }) do
      %{"ok" => _recorded} -> :normal
      %{"error" => "failed"} -> :normal
      _refused -> {:shutdown, :attempt_open}
    end
  end

  defp fail(runner, message) do
    fields = %{"error" => to_string(message), "abandoned" => false}

    case host(runner, :fail, %{"outcome" => outcome(runner, "failed", fields)}) do
      %{"ok" => message} when is_binary(message) -> :normal
      _refused -> {:shutdown, :attempt_open}
    end
  end

  defp outcome(runner, status, fields) do
    Map.merge(fields, %{
      "execution_id" => runner.assignment.execution_id,
      "attempt" => runner.assignment.attempt,
      "fence" => runner.assignment.fence,
      "status" => status
    })
  end

  defp delta(runner, event) do
    %{
      "execution_id" => runner.assignment.execution_id,
      "attempt" => runner.assignment.attempt,
      "fence" => runner.assignment.fence,
      "event" => Jason.encode!(event)
    }
  end

  # One host call of the runner's attempt, as Opus's host client makes it:
  # the versioned body sealed for the call, the header signed over the
  # sealed bytes, and the answer opened as the call's. A listener's own
  # refusal crosses plain. Answers the decoded answer, or a `lost` one for
  # anything that is no answer at this wire's version.
  defp host(runner, op, args) do
    fields =
      Map.merge(runner.keys.attempt, %{
        boot: runner.boot,
        runner: runner.runner,
        member: runner.assignment.member,
        ts: System.system_time(:millisecond),
        nonce: nonce()
      })

    json = op |> WorkerWire.request_body(args) |> Jason.encode!()
    {:ok, sealed} = WorkerAuth.seal_call(runner.keys.seal, :body, fields, json)
    {:ok, header} = WorkerAuth.host_call_header(runner.keys.call, fields, sealed)

    answer =
      case post(runner.host_url, op, header, sealed) do
        {:ok, 200, raw} -> WorkerAuth.open_call(runner.keys.seal, :answer, fields, raw)
        {:ok, _refused, raw} -> {:ok, raw}
        :error -> :error
      end

    with {:ok, raw} <- answer,
         {:ok, decoded} <- Jason.decode(raw),
         read when read != :lost <- WorkerWire.read_answer(decoded) do
      decoded
    else
      _lost -> %{"error" => "lost"}
    end
  end

  defp post(host_url, op, header, body) do
    case Req.request(
           method: :post,
           url: host_url <> WorkerWire.host_route(op),
           headers: [{WorkerWire.auth_header(), header}, {"content-type", "application/json"}],
           body: body,
           receive_timeout: HostAPI.request_timeout_ms(op),
           retry: false,
           redirect: false,
           decode_body: false
         ) do
      {:ok, %Req.Response{status: status, body: raw}} when is_binary(raw) -> {:ok, status, raw}
      _failed -> :error
    end
  end

  defp read_answer(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> WorkerWire.read_answer(decoded)
      {:error, _not_json} -> :lost
    end
  end

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
end
