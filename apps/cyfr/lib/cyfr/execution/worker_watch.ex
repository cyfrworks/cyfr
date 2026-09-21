# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.WorkerWatch do
  @moduledoc """
  Hears from each configured worker service, and lapses what a boot it
  stopped hearing from, or saw replaced, was running.

  Every poll interval (`config :cyfr, :worker_watch`, `poll_ms`, 5 s by
  default) the watch asks each worker service of `config :cyfr, :workers`
  for its status (`Cyfr.Execution.WorkerClient.status/1`), every entry at
  once, each poll bounded by the client. A status of the contract's shape
  (`Cyfr.WorkerAPI.valid_status?/1`) that names the entry's configured id
  is heard: it records the boot the status names and the attempts the
  boot's runners hold, and clears the entry's misses. Anything else is a
  miss for the entry: an answer the transport lost, a worker service it
  could not reach, a refusal, a status of another shape or one naming
  another service.

  A boot is gone in one of two ways. Misses in a row up to the configured
  count (`misses`, three by default) mean the service is not answering:
  the running attempts of the boot last heard from are lapsed
  (`Cyfr.Execution.Lapse.boot/3`), and the attempt process open for each
  is stopped without closing its run
  (`Cyfr.Execution.Attempt.stop_unclosed/2`), so its waiter answers the
  lapsed row. Further misses lapse nothing more until a status names a
  boot again. A status naming a boot other than the one recorded means
  the service restarted: the old boot's running attempts are lapsed once,
  and then the new boot is recorded; the same status again lapses nothing.
  The attempts a lapse is asked over are those the boot's last status
  reported together with those open on this boot
  (`Cyfr.Execution.Attempt`); the lapse narrows them to the ones
  dispatched to that service on that boot and still running, whichever
  runner claimed them, so an attempt started since the last status is
  covered and an attempt of another boot is never touched. A lapse the
  store could not perform is tried again on the next miss, or on the next
  status naming the new boot.

  The boot heard within the last poll interval is published for
  `Cyfr.Execution.Dispatch` (`fresh_boot/2`): a start addressed to it
  needs no status of its own first. A miss withdraws it, as does a boot
  change until the old boot's attempts are lapsed.

  A tick polls only while this boot owns the control plane
  (`Arca.ControlPlane.held?/0`), and an answer landing after ownership
  lapsed counts for nothing: the rows are the holder's to settle.

  Started by `Cyfr.Application` with no options, the watch reads its
  worker services from `config :cyfr, :workers` and its bounds from
  `config :cyfr, :worker_watch` (`poll_ms` and `misses`, positive
  integers; any other value refuses the start with the reason), and
  starts only when `config :cyfr, :worker_watch_enabled` is true. That
  key defaults to `config :cyfr, :execution_sweeper_enabled` (itself true
  by default): both are timer-driven detectors that write rows, and a
  configuration that turns off one turns off the other. Started with
  `:workers`, as a test starts it, the watch polls those endpoints
  whatever the gate says; `:poll_ms`, `:misses` and `:name` (an atom, the
  process's and its table's) override the rest.
  """

  use GenServer

  require Logger

  alias Cyfr.Execution.{Attempt, Lapse, WorkerClient}
  alias Cyfr.WorkerAPI

  @defaults [poll_ms: 5_000, misses: 3]

  @typedoc """
  The watch's view of one worker service: the boot last heard from (nil
  before any), the attempts its runners held at the last status, the
  misses since, and whether the boot's attempts were lapsed.
  """
  @type seen :: %{
          boot: String.t() | nil,
          attempts: [String.t()],
          misses: non_neg_integer(),
          lapsed: boolean()
        }

  @doc """
  Start the watch. `opts`: `:workers` (the endpoints to poll; default
  `config :cyfr, :workers`, and then only when the watch is enabled),
  `:poll_ms` and `:misses` (default `config :cyfr, :worker_watch`, then
  5 000 and 3) and `:name` (default this module). `{:error, reason}` names
  the setting that refused the start.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    opts = Keyword.put_new(opts, :name, __MODULE__)

    # Timer-driven DB writes from a permanent process poison the test
    # sandbox, the sweeper's reason for its gate; a test starts the watch
    # with the endpoints it serves.
    if Keyword.has_key?(opts, :workers) or enabled?() do
      case settings(opts) do
        {:ok, settings} -> GenServer.start_link(__MODULE__, settings, name: settings.name)
        {:error, _reason} = refused -> refused
      end
    else
      :ignore
    end
  end

  @doc """
  The boot of the worker service at `endpoint` as the watch `name` heard
  it within the last poll interval, or `:unknown`: no watch runs under
  that name, it has not heard from that endpoint, the endpoint's last
  answer was a miss, its boot changed, or the boot it heard is older than
  one interval.
  """
  @spec fresh_boot(WorkerAPI.endpoint(), atom()) :: {:ok, String.t()} | :unknown
  def fresh_boot(%{id: id, url: url}, name \\ __MODULE__) when is_atom(name) do
    case :ets.lookup(name, id) do
      [{^id, ^url, boot, heard_at, poll_ms}] ->
        if System.monotonic_time(:millisecond) - heard_at <= poll_ms,
          do: {:ok, boot},
          else: :unknown

      _other ->
        :unknown
    end
  rescue
    ArgumentError -> :unknown
  end

  @doc "The watch's view of each configured worker service (`t:seen/0`), by its id."
  @spec seen(GenServer.server()) :: %{optional(String.t()) => seen()}
  def seen(name \\ __MODULE__), do: GenServer.call(name, :seen)

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(settings) do
    # Read by dispatch without a call, so a lapse in progress delays no
    # start; owned here, it goes with the watch.
    :ets.new(settings.name, [:named_table, :protected, :set, read_concurrency: true])
    send(self(), :poll)

    {:ok,
     Map.merge(settings, %{
       seen: Map.new(settings.workers, fn {id, _endpoint} -> {id, unheard()} end),
       polls: %{}
     })}
  end

  @impl true
  def handle_call(:seen, _from, state), do: {:reply, state.seen, state}

  @impl true
  def handle_info(:poll, state) do
    state = if Arca.ControlPlane.held?(), do: poll(state), else: state
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, state}
  end

  def handle_info({:polled, poller, answer}, state) do
    case Map.pop(state.polls, poller) do
      {nil, _polls} -> {:noreply, state}
      {id, polls} -> {:noreply, landed(%{state | polls: polls}, id, answer)}
    end
  end

  # A poller's exit follows its answer; one still in flight crashed.
  def handle_info({:DOWN, _ref, :process, poller, reason}, state) do
    case Map.pop(state.polls, poller) do
      {nil, _polls} ->
        {:noreply, state}

      {id, polls} ->
        Logger.error("[Cyfr.Execution.WorkerWatch] the poll of #{id} crashed: #{inspect(reason)}")

        {:noreply, landed(%{state | polls: polls}, id, {:error, :crashed})}
    end
  end

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Polling
  # ---------------------------------------------------------------------------

  # One poller per worker service, in a process of its own so a service
  # that answers slowly delays no other; none for a service whose last poll
  # is still in flight, since the client bounds it and it lands on its own.
  defp poll(state) do
    in_flight = state.polls |> Map.values() |> MapSet.new()
    watch = self()

    Enum.reduce(state.workers, state, fn {id, endpoint}, acc ->
      if MapSet.member?(in_flight, id) do
        acc
      else
        {poller, _monitor} =
          spawn_monitor(fn -> send(watch, {:polled, self(), WorkerClient.status(endpoint)}) end)

        %{acc | polls: Map.put(acc.polls, poller, id)}
      end
    end)
  end

  defp landed(state, id, answer) do
    cond do
      not Arca.ControlPlane.held?() -> state
      heard?(answer, id) -> heard(state, id, elem(answer, 1))
      true -> missed(state, id)
    end
  end

  defp heard?({:ok, status}, id), do: WorkerAPI.valid_status?(status) and status.service == id
  defp heard?(_answer, _id), do: false

  defp heard(state, id, %{boot: boot, attempts: attempts}) do
    seen = Map.fetch!(state.seen, id)

    case seen do
      %{boot: ^boot} ->
        record(state, id, %{seen | attempts: attempts, misses: 0, lapsed: false})

      %{boot: nil} ->
        record(state, id, %{seen | boot: boot, attempts: attempts, misses: 0, lapsed: false})

      %{boot: old} ->
        # The service restarted. Its old boot's attempts lapse before the
        # new boot is recorded; a lapse the store refused leaves the old
        # boot recorded, so the next status tries again, and no start is
        # addressed to either boot meanwhile.
        state = withdraw(state, id)

        if seen.lapsed or lapse_boot(id, seen, "was replaced by #{boot}"),
          do: record(state, id, %{boot: boot, attempts: attempts, misses: 0, lapsed: false}),
          else: put_seen(state, id, %{seen | boot: old, misses: 0})
    end
  end

  defp missed(state, id) do
    state = withdraw(state, id)
    seen = Map.fetch!(state.seen, id)
    seen = %{seen | misses: seen.misses + 1}

    lapsed =
      seen.lapsed or
        (seen.misses >= state.misses and is_binary(seen.boot) and
           lapse_boot(id, seen, "answered no status in #{seen.misses} polls"))

    put_seen(state, id, %{seen | lapsed: lapsed})
  end

  # Lapse the running attempts of `seen.boot`, and stop the attempt process
  # open for each. Answers whether they were lapsed.
  defp lapse_boot(id, %{boot: boot, attempts: reported}, why) do
    case Lapse.boot(id, boot, Enum.uniq(reported ++ open_attempts())) do
      {:ok, lapsed} ->
        holder = %{service_id: id, boot_id: boot, runner: nil}
        Enum.each(lapsed, &Attempt.stop_unclosed(&1.attempt, holder))

        Logger.warning(
          "[Cyfr.Execution.WorkerWatch] #{id}: boot #{boot} #{why}; " <>
            "#{length(lapsed)} running attempt(s) lapsed"
        )

        true

      {:error, :unavailable} ->
        Logger.error(
          "[Cyfr.Execution.WorkerWatch] #{id}: boot #{boot} #{why}; its running attempts " <>
            "could not be lapsed"
        )

        false
    end
  end

  # The attempts open on this boot: `Cyfr.Execution.Attempt` registers each
  # under its execution's id, with the attempt's id as the value.
  defp open_attempts do
    Attempt.Registry
    |> Registry.select([{{:_, :_, :"$1"}, [], [:"$1"]}])
    |> Enum.filter(&is_binary/1)
  end

  defp record(state, id, seen) do
    %{url: url} = Map.fetch!(state.workers, id)

    :ets.insert(
      state.name,
      {id, url, seen.boot, System.monotonic_time(:millisecond), state.poll_ms}
    )

    put_seen(state, id, seen)
  end

  defp withdraw(state, id) do
    :ets.delete(state.name, id)
    state
  end

  defp put_seen(state, id, seen), do: %{state | seen: Map.put(state.seen, id, seen)}

  defp unheard, do: %{boot: nil, attempts: [], misses: 0, lapsed: false}

  # ---------------------------------------------------------------------------
  # Settings
  # ---------------------------------------------------------------------------

  defp enabled? do
    Application.get_env(
      :cyfr,
      :worker_watch_enabled,
      Application.get_env(:cyfr, :execution_sweeper_enabled, true)
    )
  end

  defp settings(opts) do
    with {:ok, name} <- name(Keyword.fetch!(opts, :name)),
         {:ok, configured} <- configured_bounds(),
         bounds = Keyword.merge(configured, Keyword.take(opts, [:poll_ms, :misses])),
         {:ok, poll_ms} <- bound(bounds, :poll_ms),
         {:ok, misses} <- bound(bounds, :misses),
         {:ok, workers} <-
           workers(
             Keyword.get_lazy(opts, :workers, fn -> Application.get_env(:cyfr, :workers, []) end)
           ) do
      {:ok, %{name: name, poll_ms: poll_ms, misses: misses, workers: workers}}
    end
  end

  defp name(name) when is_atom(name) and not is_nil(name), do: {:ok, name}
  defp name(other), do: {:error, "worker watch: the name must be an atom, got #{inspect(other)}"}

  defp configured_bounds do
    case Application.get_env(:cyfr, :worker_watch, []) do
      bounds when is_list(bounds) ->
        if Keyword.keyword?(bounds),
          do: {:ok, bounds},
          else: {:error, "worker watch: config :cyfr, :worker_watch must be a keyword list"}

      other ->
        {:error,
         "worker watch: config :cyfr, :worker_watch must be a keyword list, got #{inspect(other)}"}
    end
  end

  defp bound(bounds, key) do
    case Keyword.get(bounds, key, Keyword.fetch!(@defaults, key)) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      other ->
        {:error, "worker watch: #{key} must be a positive integer, got #{inspect(other)}"}
    end
  end

  # The endpoints by id, each as `Cyfr.Execution.Dispatch` reads it.
  defp workers(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      %{id: id, url: url} = entry, {:ok, acc} when is_binary(id) and is_binary(url) ->
        if Map.has_key?(acc, id),
          do: {:halt, {:error, "worker watch: two worker entries name the service #{id}"}},
          else: {:cont, {:ok, Map.put(acc, id, Map.put_new(entry, :components, nil))}}

      other, _acc ->
        {:halt, {:error, "worker watch: a worker entry is not an endpoint: #{inspect(other)}"}}
    end)
  end

  defp workers(other),
    do: {:error, "worker watch: the worker list must be a list, got #{inspect(other)}"}
end
