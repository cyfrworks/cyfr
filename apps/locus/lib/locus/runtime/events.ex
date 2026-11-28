# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.Events do
  @moduledoc """
  The forwarder of the runners' operator events: every runner's handle
  (`Locus.Runtime.RunnerProcess`) hands it each `event` frame its runner
  sent, read by `Prima.RunnerControl`'s roster, and it posts them to CYFR
  in batches (`Locus.Runtime.HostClient.report_events/3`), where the
  control plane emits them (`c:Prima.HostAPI.report_events/2`). A runner
  emits no telemetry of its own: it is a process apart from the one an
  operator attaches to.

  One queue holds every runner's events in the order they arrived. A
  batch of at most `Prima.HostAPI.max_report_events/0` is sent once that
  many are queued or a second after the first of them arrived, so one
  event from a runner that then idles reaches CYFR within a second and
  its call; one batch is in flight at a time, posted from a process of
  its own, so the forwarder never waits on CYFR. A batch whose answer
  was lost is not sent again: it may have arrived, and an event counted
  twice misleads more than one missed. A batch that reached no
  connection stays at the head of the queue and is sent again a second
  later. The queue holds at most #{1_024} events while CYFR cannot be
  reached, the oldest dropped first, and the forwarder logs once, when a
  batch reaches CYFR again, how many it dropped.

  The worker service tells it which service and boot it posts for, and
  with which credentials (`serve/3`), as it starts; nothing is posted
  before. Nothing an event carries is logged.
  """

  use GenServer

  require Logger

  alias Locus.Runtime.HostClient

  @max_batch Prima.HostAPI.max_report_events()
  @max_held 1_024
  @flush_ms 1_000

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc """
  Start the forwarder. Options: `:post` (how a batch is posted, default
  `Locus.Runtime.HostClient.report_events/3`), `:flush_ms` (how long the
  first event of a batch waits for the rest, default #{@flush_ms}), `:name`
  (default `#{inspect(__MODULE__)}`).
  """
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Post for the worker service `credentials` name on its boot `boot`."
  @spec serve(GenServer.server(), Locus.Runtime.Credentials.t(), String.t()) :: :ok
  def serve(forwarder \\ __MODULE__, credentials, boot) when is_binary(boot),
    do: GenServer.call(forwarder, {:serve, credentials, boot})

  @doc "Queue one `event` a runner sent (`t:Prima.RunnerControl.event/0`), without waiting."
  @spec forward(GenServer.server(), Prima.RunnerControl.event()) :: :ok
  def forward(forwarder \\ __MODULE__, %{type: :event} = event),
    do: GenServer.cast(forwarder, {:event, event})

  @impl true
  def init(opts) do
    # A batch's post is linked to this process: its failure is its
    # answer's (`:DOWN` below), never the forwarder's end, which would end
    # the node for an operator's event.
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       post: Keyword.get(opts, :post, &HostClient.report_events/3),
       flush_ms: Keyword.get(opts, :flush_ms, @flush_ms),
       credentials: nil,
       boot: nil,
       queue: :queue.new(),
       held: 0,
       # The batch in flight, out of the queue until its answer says
       # whether it was sent: its sender's ref and its events.
       sending: nil,
       timer: nil,
       # Events dropped since a batch last reached CYFR.
       dropped: 0
     }}
  end

  @impl true
  def handle_call({:serve, credentials, boot}, _from, state),
    do: {:reply, :ok, flush(%{state | credentials: credentials, boot: boot})}

  @impl true
  def handle_cast({:event, event}, state) do
    state = %{state | queue: :queue.in(event, state.queue), held: state.held + 1}
    {:noreply, state |> within_bound() |> due()}
  end

  @impl true
  def handle_info(:flush, state), do: {:noreply, flush(%{state | timer: nil})}

  def handle_info({ref, outcome}, %{sending: {ref, batch}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, sent(%{state | sending: nil}, batch, outcome)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{sending: {ref, batch}} = state) do
    Logger.error(
      "[Locus.Runtime.Events] a batch's post ended before it answered: " <>
        Prima.LogFilter.inspect_reason(reason)
    )

    {:noreply, sent(%{state | sending: nil}, batch, {:error, :post_down})}
  end

  def handle_info({:EXIT, _post, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  # The credentials hold the service's keys, and the queue what runners
  # did: a status or crash report shows neither, only how many are held.
  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn state ->
      state
      |> Map.delete(:credentials)
      |> Map.replace_lazy(:queue, &:queue.len/1)
      |> Map.replace_lazy(:sending, fn
        {_ref, batch} -> {:sending, :queue.len(batch)}
        nil -> nil
      end)
    end)
  end

  # Past the bound, the oldest event queued goes first.
  defp within_bound(%{held: held} = state) when held <= @max_held, do: state

  defp within_bound(state) do
    {_oldest, queue} = :queue.out(state.queue)
    within_bound(%{state | queue: queue, held: state.held - 1, dropped: state.dropped + 1})
  end

  # A full batch goes now, and the first event of one waits for the rest.
  defp due(%{held: held} = state) when held >= @max_batch, do: flush(state)

  defp due(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :flush, state.flush_ms)}

  defp due(state), do: state

  # One batch in flight at a time, out of the queue until its answer, and
  # none before the service has said what to post for.
  defp flush(%{credentials: nil} = state), do: state
  defp flush(%{sending: {_ref, _batch}} = state), do: state
  defp flush(%{held: 0} = state), do: state

  defp flush(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {batch, queue} = :queue.split(min(state.held, @max_batch), state.queue)
    %{post: post, credentials: credentials, boot: boot} = state
    events = :queue.to_list(batch)
    task = Task.async(fn -> posted(post, credentials, boot, events) end)
    %{state | sending: {task.ref, batch}, queue: queue, held: :queue.len(queue), timer: nil}
  end

  # A batch that reached no connection goes back to the queue's head,
  # under the bound, and goes again after the wait. One that reached CYFR,
  # or whose answer was lost, is done: it is never sent again. Events
  # dropped while CYFR could not be reached are said once, as a batch
  # reaches it again.
  defp sent(state, batch, {:error, :unsent}) do
    queue = :queue.join(batch, state.queue)
    state = within_bound(%{state | queue: queue, held: :queue.len(queue)})
    %{state | timer: Process.send_after(self(), :flush, state.flush_ms)}
  end

  defp sent(state, batch, outcome) do
    if outcome != :ok do
      Logger.warning(
        "[Locus.Runtime.Events] a batch of #{:queue.len(batch)} runner events was not " <>
          "reported (#{Prima.LogFilter.inspect_reason(outcome)}); it is not sent again"
      )
    end

    state =
      if state.dropped > 0 do
        Logger.warning(
          "[Locus.Runtime.Events] #{state.dropped} runner events were dropped while " <>
            "CYFR could not be reached"
        )

        %{state | dropped: 0}
      else
        state
      end

    if state.held >= @max_batch, do: flush(state), else: rearm(state)
  end

  # A post that raises reached CYFR or not: it is answered as a lost
  # answer is, and never sent again.
  defp posted(post, credentials, boot, events) do
    post.(credentials, boot, events)
  rescue
    _exception -> {:error, :post_raised}
  end

  defp rearm(%{held: 0} = state), do: state
  defp rearm(state), do: due(state)
end
