defmodule Opus.CronScheduler do
  @moduledoc """
  OTP-native cron scheduler for recurring WASM component execution.

  Uses `Process.send_after/3` for timer management. Skips missed runs on
  restart — only computes next future run. Prevents overlapping executions
  of the same schedule.
  """

  use GenServer
  require Logger

  @max_timer_ms 60 * 60 * 1_000
  @pubsub_topic "schedules"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Public API

  def add(schedule_id), do: GenServer.cast(__MODULE__, {:add, schedule_id})
  def remove(schedule_id), do: GenServer.cast(__MODULE__, {:remove, schedule_id})
  def pause(schedule_id), do: GenServer.cast(__MODULE__, {:pause, schedule_id})
  def resume(schedule_id), do: GenServer.cast(__MODULE__, {:resume, schedule_id})

  def update(schedule_id) do
    GenServer.cast(__MODULE__, {:update, schedule_id})
  end

  def reload, do: GenServer.cast(__MODULE__, :reload)

  # GenServer callbacks

  @impl true
  def init(_opts) do
    state = %{timers: %{}, running: MapSet.new(), tasks: %{}}
    {:ok, state, {:continue, :load_schedules}}
  end

  @impl true
  def handle_continue(:load_schedules, state) do
    state = load_all_schedules(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:add, schedule_id}, state) do
    {:noreply, schedule_timer(schedule_id, state)}
  end

  def handle_cast({:remove, schedule_id}, state) do
    {:noreply, cancel_timer(schedule_id, state)}
  end

  def handle_cast({:pause, schedule_id}, state) do
    {:noreply, cancel_timer(schedule_id, state)}
  end

  def handle_cast({:resume, schedule_id}, state) do
    {:noreply, schedule_timer(schedule_id, state)}
  end

  def handle_cast({:update, schedule_id}, state) do
    state = cancel_timer(schedule_id, state)
    {:noreply, schedule_timer(schedule_id, state)}
  end

  def handle_cast(:reload, state) do
    state = cancel_all_timers(state)
    state = load_all_schedules(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:fire, schedule_id}, state) do
    state = %{state | timers: Map.delete(state.timers, schedule_id)}

    if MapSet.member?(state.running, schedule_id) do
      Logger.debug("CronScheduler: skipping #{schedule_id} (already running)")
      {:noreply, schedule_timer(schedule_id, state)}
    else
      state = fire_schedule(schedule_id, state)
      {:noreply, state}
    end
  end

  def handle_info({:recheck, schedule_id}, state) do
    state = %{state | timers: Map.delete(state.timers, schedule_id)}
    {:noreply, schedule_timer(schedule_id, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.tasks, fn {_id, task_ref} -> task_ref == ref end) do
      {schedule_id, _} ->
        state = %{state | running: MapSet.delete(state.running, schedule_id), tasks: Map.delete(state.tasks, schedule_id)}

        if reason != :normal do
          Logger.warning("CronScheduler: schedule #{schedule_id} execution failed: #{inspect(reason)}")
          Arca.CronSchedule.record_error(schedule_id, inspect(reason))
        end

        broadcast_update()
        {:noreply, schedule_timer(schedule_id, state)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private helpers

  defp load_all_schedules(state) do
    schedules = Arca.CronSchedule.active_schedules()
    Logger.info("CronScheduler: loading #{length(schedules)} active schedule(s)")

    Enum.reduce(schedules, state, fn schedule, acc ->
      # Recompute next_run from now (skip missed runs)
      case compute_next_run(schedule.cron_expression) do
        {:ok, next_run} ->
          Arca.CronSchedule.update(schedule.id, %{next_run_at: next_run})
          schedule_timer(schedule.id, acc)

        {:error, reason} ->
          Logger.warning("CronScheduler: invalid cron for schedule #{schedule.id}: #{reason}")
          acc
      end
    end)
  end

  defp fire_schedule(schedule_id, state) do
    case Arca.CronSchedule.get(schedule_id) do
      nil ->
        state

      %{status: "active"} = schedule ->
        ctx = Sanctum.Context.for_scheduled(schedule.user_id)
        input = decode_json(schedule.input)
        execution_id = Opus.ExecutionRecord.generate_id()

        # Record execution start on schedule
        Arca.CronSchedule.record_run(schedule_id, execution_id)

        # Compute and persist next_run_at
        case compute_next_run(schedule.cron_expression) do
          {:ok, next_run} -> Arca.CronSchedule.update(schedule_id, %{next_run_at: next_run})
          _ -> :ok
        end

        # Spawn monitored task
        {:ok, pid} =
          Task.start(fn ->
            Registry.register(Opus.ExecutionRegistry, execution_id, :running)

            case Opus.run(ctx, schedule.reference, input, execution_id: execution_id) do
              {:ok, _result} ->
                Logger.debug("CronScheduler: schedule #{schedule_id} completed (#{execution_id})")

              {:error, reason} ->
                Logger.warning("CronScheduler: schedule #{schedule_id} failed: #{inspect(reason)}")
                Arca.CronSchedule.record_error(schedule_id, inspect(reason))
            end
          end)

        ref = Process.monitor(pid)

        broadcast_update()

        %{state |
          running: MapSet.put(state.running, schedule_id),
          tasks: Map.put(state.tasks, schedule_id, ref)
        }

      _not_active ->
        state
    end
  end

  defp schedule_timer(schedule_id, state) do
    # Cancel existing timer if any
    state = cancel_timer(schedule_id, state)

    case Arca.CronSchedule.get(schedule_id) do
      %{status: "active"} = schedule ->
        case compute_next_run(schedule.cron_expression) do
          {:ok, next_run} ->
            delay_ms = max(DateTime.diff(next_run, DateTime.utc_now(), :millisecond), 1_000)

            if delay_ms > @max_timer_ms do
              # Too far out — set a recheck timer
              timer_ref = Process.send_after(self(), {:recheck, schedule_id}, @max_timer_ms)
              %{state | timers: Map.put(state.timers, schedule_id, timer_ref)}
            else
              timer_ref = Process.send_after(self(), {:fire, schedule_id}, delay_ms)
              %{state | timers: Map.put(state.timers, schedule_id, timer_ref)}
            end

          {:error, reason} ->
            Logger.warning("CronScheduler: cannot schedule #{schedule_id}: #{reason}")
            state
        end

      _ ->
        state
    end
  end

  defp cancel_timer(schedule_id, state) do
    case Map.get(state.timers, schedule_id) do
      nil -> state
      timer_ref ->
        Process.cancel_timer(timer_ref)
        %{state | timers: Map.delete(state.timers, schedule_id)}
    end
  end

  defp cancel_all_timers(state) do
    Enum.each(state.timers, fn {_id, ref} -> Process.cancel_timer(ref) end)
    %{state | timers: %{}}
  end

  defp compute_next_run(cron_expression) do
    case Opus.CronParser.parse(cron_expression) do
      {:ok, parsed} -> Opus.CronParser.next_run(parsed, DateTime.utc_now())
      error -> error
    end
  end

  defp decode_json(nil), do: %{}
  defp decode_json(""), do: %{}

  defp decode_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp broadcast_update do
    Phoenix.PubSub.broadcast(Emissary.PubSub, @pubsub_topic, :schedules_updated)
  end
end
