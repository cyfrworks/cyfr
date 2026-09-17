# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.ScriptedWorker do
  @moduledoc """
  A worker service (`Cyfr.WorkerAPI`) whose runners answer from a script
  instead of running a component. Configure it with `workers/2` inside the
  test; users are `async: false`, since the script is one named process.

  Everything but the component is real. This worker service has an id of
  its own (`service/0`) and a boot of its own, and its keys are its own: it
  never answers as the real worker service. A run of a scripted reference
  is admitted by CYFR and dispatched here; `start/3` checks the assignment
  is addressed to this worker service and this boot, its input matches its
  digest and its sealed keys open as its attempt, then starts a runner.
  The runner reaches its attempt only through `Cyfr.Execution.Host`,
  signing each call with the attempt's call key: it attaches with the
  signed assignment (the claim, and the unseal of the run's vault edge),
  records the call with the authority its assignment carries, pushes the
  script's events (`push_deltas`, masked by the attempt) and closes the run
  (`complete` or `fail`). A runner that exits leaving its attempt open is
  reported (`Cyfr.Execution.Host.runner_exited/2`), signed with this
  worker service's dispatch key.

  A reference it does not script never reaches it: starting it puts an
  entry for its scripted references alone ahead of the configured worker
  services in `config :cyfr, :workers` (`workers/2`), so
  `Cyfr.Execution.Dispatch` routes every other reference to the real
  worker service when one is configured, and stopping it removes that
  entry. Tests that change `:workers` themselves restore it on exit as they
  do today. Started for a reference the routing did not name, it refuses
  the assignment `:malformed`.

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

  The catalyst's answers about itself are not the script's: a run's input
  `%{"operation" => "describe"}` is answered with its description, and
  `%{"operation" => "models"}` with no models.
  """

  @behaviour Cyfr.WorkerAPI

  use GenServer

  require Logger

  alias Cyfr.{Assignment, WorkerAuth}
  alias Cyfr.Execution.{Host, Keys}

  @attempt_fields [:athanor_id, :execution_id, :attempt, :fence, :generation]
  @probe_wait_ms 5_000
  @service "wrk_scripted"

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc "This worker service's configured id."
  @spec service() :: String.t()
  def service, do: @service

  @doc """
  The `config :cyfr, :workers` list that routes the scripted `refs` (any
  form `Cyfr.ComponentRef.to_name_ref/1` reads) to this worker service and
  every other reference to the worker services in `configured` (the list
  being replaced, with any earlier entry of this worker service dropped).
  """
  @spec workers([String.t()] | String.t(), [map()] | nil) :: [map()]
  def workers(refs, configured) do
    names =
      refs
      |> List.wrap()
      |> Enum.map(fn ref ->
        {:ok, name} = Cyfr.ComponentRef.to_name_ref(ref)
        name
      end)

    others = Enum.reject(configured || [], &(is_map(&1) and &1[:module] == __MODULE__))
    [%{id: @service, module: __MODULE__, components: names} | others]
  end

  @doc """
  Start the worker service: `ref:` the scripted reference (or a list),
  `script:` its items, `window:` the context window a description answers
  for any model (default 200_000), `describe:` `{:refuse, error}` to have
  a described model refused instead.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Replace the remaining script."
  def script(items) when is_list(items), do: GenServer.call(__MODULE__, {:script, items})

  @doc "Every scripted run that attached, oldest first: `%{execution_id, input, authority}`."
  def calls, do: GenServer.call(__MODULE__, :calls)

  @doc "Every execution id this worker service was asked to kill, oldest first."
  def kills, do: GenServer.call(__MODULE__, :kills)

  @doc """
  Start the context's athanor on fresh execution limits: a fresh consented
  rate window (`Cyfr.Execution.Rates`) for the pinned releases of `refs`,
  and no unreaped-kill penalty (`Cyfr.Execution.Semaphore.forgive_unreaped/1`).
  Scripted runs are admitted, and their runners killed, for real, so every
  test sharing an athanor draws on the same limits.
  """
  def fresh_limits!(%Sanctum.Context{} = ctx, refs) when is_list(refs) do
    for ref <- refs do
      {:ok, pinned, _resolution} = Compendium.Resolver.resolve(ctx, ref)
      :ok = Cyfr.Execution.Rates.reset(ctx.athanor_id, pinned)
    end

    :ok = Cyfr.Execution.Semaphore.forgive_unreaped(ctx.athanor_id)
  end

  # ---------------------------------------------------------------------------
  # Cyfr.WorkerAPI
  # ---------------------------------------------------------------------------

  @impl Cyfr.WorkerAPI
  def start(token, input, sealed_keys)
      when is_binary(token) and is_binary(input) and is_binary(sealed_keys) do
    caller = %{
      callers: [self() | Process.get(:"$callers", [])],
      logger: Cyfr.LoggerContext.capture()
    }

    GenServer.call(__MODULE__, {:start, token, input, sealed_keys, caller})
  end

  @impl Cyfr.WorkerAPI
  def kill(execution_id) when is_binary(execution_id),
    do: GenServer.call(__MODULE__, {:kill, execution_id})

  @impl Cyfr.WorkerAPI
  def status, do: {:ok, GenServer.call(__MODULE__, :status)}

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    # Trapped, so a runner's exit arrives as a message and the runners go
    # with this process.
    Process.flag(:trap_exit, true)

    refs =
      opts
      |> Keyword.fetch!(:ref)
      |> List.wrap()
      |> Enum.map(fn ref ->
        {:ok, name} = Cyfr.ComponentRef.to_name_ref(ref)
        name
      end)

    # Route the scripted references here and everything else to the worker
    # services configured before; `terminate/2` takes the entry out again.
    Application.put_env(:cyfr, :workers, workers(refs, Application.get_env(:cyfr, :workers)))

    {:ok,
     %{
       boot: "#{node()}#" <> Cyfr.UUID7.generate_id("boot"),
       refs: refs,
       script: Keyword.get(opts, :script, []),
       window: Keyword.get(opts, :window, 200_000),
       describe: Keyword.get(opts, :describe, :answer),
       calls: [],
       kills: [],
       runners: %{}
     }}
  end

  @impl true
  def handle_call({:start, token, input, sealed_keys, caller}, _from, state) do
    with {:ok, assignment} <- Assignment.read(token),
         true <- scripted?(state, assignment.component.ref),
         true <- assignment.service == @service and assignment.boot == state.boot,
         true <- Cyfr.Digest.sha256(input) == assignment.input_digest,
         {:ok, worker_key} <- Keys.worker_key(@service),
         {:ok, %{attempt: attempt} = keys} <-
           WorkerAuth.open_attempt_keys(WorkerAuth.dispatch_seal_key(worker_key), sealed_keys),
         true <- attempt == assignment |> Map.take(@attempt_fields) |> Map.put(:service, @service),
         {:ok, %{} = decoded} <- Jason.decode(input) do
      runner = %{
        token: token,
        assignment: assignment,
        input: decoded,
        keys: keys,
        boot: state.boot,
        runner: Cyfr.UUID7.generate_id("runner"),
        waiter: hd(caller.callers),
        callers: caller.callers,
        logger: caller.logger
      }

      pid = spawn_link(fn -> run(runner) end)

      runners =
        Map.put(state.runners, pid, %{
          execution_id: assignment.execution_id,
          attempt: assignment.attempt,
          boot: state.boot,
          runner: runner.runner,
          callers: caller.callers,
          logger: caller.logger
        })

      {:reply, :ok, %{state | runners: runners}}
    else
      _refused -> {:reply, {:error, :malformed}, state}
    end
  end

  def handle_call({:kill, execution_id}, _from, state) do
    state = %{state | kills: [execution_id | state.kills]}

    case Enum.find(state.runners, fn {_pid, runner} -> runner.execution_id == execution_id end) do
      {pid, _runner} ->
        Process.exit(pid, :kill)
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:status, _from, state) do
    attempts = for {_pid, runner} <- state.runners, do: runner.attempt

    {:reply,
     %{
       service: @service,
       boot: state.boot,
       runners: %{fresh: 0, idle: 0, busy: map_size(state.runners)},
       attempts: attempts
     }, state}
  end

  def handle_call({:script, items}, _from, state), do: {:reply, :ok, %{state | script: items}}
  def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}
  def handle_call(:kills, _from, state), do: {:reply, Enum.reverse(state.kills), state}

  def handle_call(:settings, _from, state),
    do: {:reply, Map.take(state, [:window, :describe]), state}

  def handle_call(:take, _from, %{script: []} = state), do: {:reply, nil, state}

  def handle_call(:take, _from, %{script: [item | rest]} = state),
    do: {:reply, item, %{state | script: rest}}

  def handle_call({:called, call}, _from, state),
    do: {:reply, :ok, %{state | calls: [call | state.calls]}}

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    case Map.pop(state.runners, pid) do
      {nil, _runners} ->
        {:noreply, state}

      {runner, runners} ->
        if reason != :normal, do: report(runner)
        {:noreply, %{state | runners: runners}}
    end
  end

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    for {pid, _runner} <- state.runners, do: Process.exit(pid, :kill)

    configured = Application.get_env(:cyfr, :workers, [])
    Application.put_env(:cyfr, :workers, Enum.reject(configured, &(&1[:module] == __MODULE__)))
    :ok
  end

  defp scripted?(state, reference) do
    case Cyfr.ComponentRef.to_name_ref(reference) do
      {:ok, name} -> name in state.refs
      {:error, _} -> false
    end
  end

  # A runner's exit is reported from a process of its own, as the caller
  # that started it, so its writes run under that caller's sandbox.
  defp report(runner) do
    spawn(fn ->
      Process.put(:"$callers", runner.callers)
      Cyfr.LoggerContext.restore(runner.logger)

      body =
        Jason.encode!(%{
          "op" => "runner_exited",
          "args" => %{"runner" => runner.runner, "attempts" => [runner.attempt]}
        })

      fields = %{
        service: @service,
        boot: runner.boot,
        ts: System.system_time(:millisecond),
        nonce: nonce()
      }

      with {:ok, worker_key} <- Keys.worker_key(@service),
           {:ok, header} <-
             WorkerAuth.report_header(WorkerAuth.dispatch_key(worker_key), fields, body),
           %{"ok" => true} <- header |> Host.runner_exited(body) |> Jason.decode!() do
        :ok
      else
        refused ->
          Logger.error(
            "[Cyfr.Test.ScriptedWorker] the exit of #{runner.execution_id}'s runner was not " <>
              "reported: #{inspect(refused)}"
          )
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # The runner
  # ---------------------------------------------------------------------------

  defp run(runner) do
    Process.put(:"$callers", runner.callers)
    Cyfr.LoggerContext.restore(runner.logger)
    Cyfr.LoggerContext.set_execution_id(runner.assignment.execution_id)

    case attached(runner) do
      :normal -> :ok
      reason -> exit(reason)
    end
  end

  defp attached(runner) do
    case host(runner, "attach", %{"assignment" => runner.token}) do
      %{"ok" => %{}} ->
        case Cyfr.Authority.from_wire(runner.assignment.authority) do
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
        _ = host(runner, "push_deltas", %{"deltas" => Enum.map(events, &delta(runner, &1))})
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
        Process.exit(runner.waiter, :kill)
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
        :erlang.suspend_process(runner.waiter)
        closed = complete(runner, %{"status" => 200, "data" => data})
        Process.exit(runner.waiter, :kill)
        closed

      %{} = data ->
        complete(runner, %{"status" => 200, "data" => data})
    end
  end

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
    case host(runner, "complete", %{
           "outcome" => outcome(runner, "completed", %{"output" => output})
         }) do
      %{"ok" => _recorded} -> :normal
      %{"error" => "failed"} -> :normal
      _refused -> {:shutdown, :attempt_open}
    end
  end

  defp fail(runner, message) do
    fields = %{"error" => to_string(message), "abandoned" => false}

    case host(runner, "fail", %{"outcome" => outcome(runner, "failed", fields)}) do
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

  defp host(runner, op, args) do
    body = Jason.encode!(%{"op" => op, "args" => args})
    runner |> header(body) |> Host.call(body) |> Jason.decode!()
  end

  defp header(runner, body) do
    fields =
      Map.merge(runner.keys.attempt, %{
        boot: runner.boot,
        runner: runner.runner,
        ts: System.system_time(:millisecond),
        nonce: nonce()
      })

    {:ok, header} = WorkerAuth.host_call_header(runner.keys.call, fields, body)
    header
  end

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
end
