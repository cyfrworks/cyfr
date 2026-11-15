# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ScheduleTurns do
  @moduledoc """
  A schedule that holds a line for Aqua: each of its fires becomes a turn
  of Aqua, as the schedule's person, in the schedule's own thread.

  ## Who can make, change and fire one

  Only a person's own signed-in session makes a schedule hold a line for
  Aqua, or changes the line (`Opus.Schedules.Provider`); a key, a
  tincture's frame and an agent's call are refused. The scheduler fires
  it as it fires any schedule, and never calls Aqua: the occurrence its
  claim writes is the record of the fire, and the claim wakes this
  consumer (`Cyfr.Bus.schedule_turns/0`).

  ## Starting a fire's turn

  On a wake-up, at boot and on a tick, this consumer reads the
  occurrences of Aqua lines its own boot holds still `claimed`
  (`Arca.CronSchedule.aqua_claims/1`): only the boot that holds a claim
  starts its turn, so the root's admission, which starts the occurrence
  only for the claiming boot (`Arca.Execution.admit/2`), can succeed, and
  a peer that hears the same wake-up writes nothing. A claim the
  scheduler's recovery takes over is the taker's from then on, and its
  own consumer starts it.

  Each is sent through the thread's runner (`Aqua.Runner.send_message/4`)
  as the schedule's person under the `schedule` origin
  (`Sanctum.Tenancy.continuation/3`), in the schedule's thread
  (`Arca.CronSchedule.thread/3`, made on the first fire and titled with
  the schedule's name), with the occurrence's id and its claimant as the
  message's `client_id`: a second send of the same claim answers the turn
  the first opened, so one claim opens one turn however often it is read.
  The turn carries the schedule and the occurrence, and its root's
  admission starts the occurrence (`Opus.TurnRoot`).

  ## What the turn may do

  Only what Aqua may do without asking, and what a standing allow already
  covers, the person's allows in the schedule's thread among them. At the
  first call that would ask, it opens no card and ends failed, saying
  what it needed and how to allow it next time (`Aqua.Loop`).

  ## Its end

  A turn's end ends its occurrence through the scheduler's one ending
  (`Opus.Schedules.Scheduler.end_turn/4`, called from `Aqua.Tape.finish/4`),
  as the turn's root row says. Here, a claim whose turn will never start
  ends `failed` with the reason: the schedule paused or deleted since its
  claim, its person or athanor no longer standing, a line that does not
  read, a thread or a turn refused for good, or a turn that ended before
  it started its occurrence. A refusal that may pass (`:busy`, a peer
  holding the thread, the store or the engine unavailable) waits for the
  next drain, and so does an athanor still being prepared.

  `:schedule_turns_enabled` false leaves it unstarted: under the test
  sandbox a drain on a tick would work another test's claims on the
  connection that test lent, so the suite turns it off and its tests
  drain by hand.
  """

  use GenServer

  require Logger
  require Prima.TestSeam

  alias Aqua.{Runner, Tape}
  alias Cyfr.Bus.ScheduleTurnDue

  @tick_ms 30_000
  @terminal ~w(completed failed cancelled uncertain)
  # Refusals no later drain changes: the claim ends failed with them.
  @for_good [
    :archived,
    :denied,
    :not_member,
    :no_origin,
    :not_addressable,
    :no_agent,
    :empty,
    :message_too_long
  ]

  @typedoc "What became of one claim in a drain."
  @type outcome :: :sent | :waiting | {:ended, String.t()} | {:wait, term()}

  @doc false
  def start_link(opts \\ []) do
    if Prima.TestSeam.value(true, fn ->
         Application.get_env(:cyfr, :schedule_turns_enabled, true)
       end) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @impl true
  def init(opts) do
    :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.schedule_turns())
    send(self(), :drain)
    {:ok, %{tick_ms: Keyword.get(opts, :tick_ms, @tick_ms)}}
  end

  @impl true
  def handle_info(%ScheduleTurnDue{}, state) do
    _ = drain()
    {:noreply, state}
  end

  def handle_info(:drain, state) do
    _ = drain()
    Process.send_after(self(), :drain, state.tick_ms)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  @doc """
  Start or end every claim `boot` (this boot by default) holds of an Aqua
  line, oldest due first, while this member holds its slot. Answers each
  occurrence's outcome by id. Never raises.
  """
  @spec drain(String.t()) :: %{String.t() => outcome()}
  def drain(boot \\ Prima.Boot.id()) do
    with true <- Arca.ControlPlane.held?(),
         {:ok, claims} <- Arca.CronSchedule.aqua_claims(boot) do
      Map.new(claims, &{&1.id, guarded(&1)})
    else
      false ->
        %{}

      {:error, reason} ->
        Logger.warning("[Aqua.ScheduleTurns] claims not read: #{inspect(reason)}")
        %{}
    end
  catch
    # The tick runs with no caller to answer to: a read that raises here
    # must not take the consumer down, since one restarted by its
    # supervisor drains again at once.
    kind, reason ->
      Logger.warning(
        "[Aqua.ScheduleTurns] claims not drained: " <>
          Prima.LogFilter.format_exception(kind, reason)
      )

      %{}
  end

  # ---- one claim --------------------------------------------------------------

  # One claim that raises waits for the next drain, and keeps none of the
  # others from theirs.
  defp guarded(claim) do
    work(claim)
  catch
    kind, reason ->
      Logger.warning(
        "[Aqua.ScheduleTurns] occurrence #{claim.id} not worked: " <>
          Prima.LogFilter.format_exception(kind, reason)
      )

      {:wait, :crashed}
  end

  defp work(%{status: "active"} = claim) do
    with {:ok, ctx} <- person(claim),
         {:ok, line} <- line(claim),
         {:ok, thread_id} <- thread(ctx, claim) do
      ctx
      |> Runner.send_message(thread_id, line,
        client_id: client_id(claim),
        schedule: %{schedule_id: claim.schedule_id, occurrence_id: claim.id}
      )
      |> sent(ctx, thread_id, claim)
    else
      {:error, reason} -> refused(claim, reason)
    end
  end

  defp work(%{status: status} = claim), do: ended(claim, "the schedule is #{status}")

  # One turn per claim: a send of the same claim answers the turn its
  # first send opened, and a claim the scheduler's recovery took over to
  # another boot is that boot's own, opening a turn of its own while the
  # first one, refused at its admission, ends failed in the thread.
  defp client_id(claim), do: "#{claim.id}:#{claim.claimed_by}"

  defp person(claim) do
    Sanctum.Tenancy.continuation(claim.user_id, claim.athanor_id, "schedule")
  end

  # The line is the schedule's input, `{"line": text}` as the row stores it.
  defp line(%{input: input}) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, %{"line" => line}} when is_binary(line) -> {:ok, line}
      _unreadable -> {:error, :no_line}
    end
  end

  defp line(_claim), do: {:error, :no_line}

  defp thread(ctx, claim) do
    Arca.CronSchedule.thread(
      Sanctum.Context.actor(ctx),
      claim.schedule_id,
      Prima.AgentRef.soul_name()
    )
  end

  # A new turn waits for its root; a turn this occurrence opened before is
  # either still to start or has ended without starting the occurrence,
  # since a turn that started it ended it on its own end.
  defp sent({:ok, %{replayed: false}}, _ctx, _thread_id, _claim), do: :sent

  defp sent({:ok, %{replayed: true, turn_id: turn_id}}, ctx, _thread_id, claim)
       when is_binary(turn_id) do
    case Tape.turn(ctx, turn_id) do
      {:ok, %{status: status} = turn} when status in @terminal ->
        if Tape.schedule_of(turn) == %{schedule_id: claim.schedule_id, occurrence_id: claim.id},
          do: ended(claim, turn.error || "the turn ended before it started"),
          else: ended(claim, "its message was taken by another")

      {:ok, _open} ->
        :waiting

      {:error, reason} ->
        {:wait, reason}
    end
  end

  defp sent({:ok, %{replayed: true}}, _ctx, _thread_id, claim),
    do: ended(claim, "its message was taken by another")

  defp sent({:error, reason}, _ctx, _thread_id, claim), do: refused(claim, reason)

  defp refused(claim, :no_line), do: ended(claim, "the schedule holds no line for Aqua")

  # Another message of the thread holds the occurrence's id: the fire's own
  # line can never land under it.
  defp refused(claim, :client_id_reused), do: ended(claim, "its message was taken by another")

  defp refused(claim, reason) do
    if for_good?(reason),
      do: ended(claim, Aqua.Ops.render_refusal(reason)),
      else: {:wait, reason}
  end

  defp for_good?(reason) when reason in @for_good, do: true
  defp for_good?({:limit_reached, _cap, _value}), do: true
  defp for_good?(_reason), do: false

  # A claim whose turn will never start ends failed, as this boot's.
  defp ended(claim, reason) when is_binary(reason) do
    actor = Prima.Actor.in_athanor(claim.athanor_id)

    case Opus.Schedules.Scheduler.end_turn(actor, claim.id, nil, reason) do
      {:ok, _state} ->
        {:ended, reason}

      {:error, refused} ->
        Logger.warning(
          "[Aqua.ScheduleTurns] occurrence #{claim.id} of #{claim.schedule_id} not ended: " <>
            inspect(refused)
        )

        {:wait, refused}
    end
  end
end
