# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Nudge do
  @moduledoc """
  The nudge of a quiet workspace thread and the post that reminds of one
  that waits on its person, both on the server's own clock, both after
  the one quiet period (`quiet_seconds/0`, fifteen minutes).

  ## The nudge

  A workspace thread that reads working and in which nothing has happened
  for the quiet period, in it or in a crew thread under it, gets one line
  of the server's for its own Aqua: nothing has happened here, the work is
  not finished, say where it stands. What has happened is a post, a step
  starting or ending, a card made or decided and a turn accepted or
  ended; Aqua's own silence is silence, and a page's own calls, reads,
  read marks, this process's reads, a delivery's receipt and output
  streamed and not recorded are no activity
  (`Arca.TurnStorage.nudge/3`). It goes to the thread alone, never through
  the daily thread.

  The line joins the turn that holds the thread when that turn is Aqua's
  and asks a model, whatever waits behind it, read at its next model
  round from storage on whichever member runs it, a steer that keeps that
  turn's own person, origin and restrictions; with no turn open there it
  opens one, bound to the thread's current work: the newest turn of
  Aqua's there, whose person, origin and tools it keeps, the person's
  standing asked again (`Sanctum.Tenancy.continuation/3`). While an
  opening waits for its turn, or a turn is queued with nothing holding
  the thread, that is the work and no nudge opens a turn. The tick binds
  to the turn it read, and the acceptance refuses a binding the thread's
  lock no longer finds, so authority is never borrowed from work that
  moved. Anything else open there (a page's call's turn, a turn paused
  on a card or an uncertain call) leaves it to the next tick. An
  archived thread is neither nudged nor reminded, and no line of this
  process's takes one out of the archive. No second nudge comes while one
  is unanswered: until a model round of its turn has carried it and
  closed, or its turn ended. A nudge's turn is the thread's work as
  any turn is; one that ends with no report leaves the thread working,
  and the next quiet period runs from its end.

  ## The reminder

  A workspace thread that reads needs you or error gets a post of the
  server's on its person's daily thread, saying what needs their
  attention: once the quiet period after its wait began (`waits_since`:
  when it came to read so, or the person last acted on it while it still
  waited), then once on each new day of the person's while it still
  waits, one post for each wait. It is an ordinary post that Aqua answers
  as it answers any (`Aqua.Runner.send_message/4`): sent by the server
  as the athanor's person under the `schedule` origin, since nobody is
  known to be present, with no schedule's occurrence or grants; it opens
  a turn of Aqua's, steers one of the same sender and origin, or queues,
  and a refusal leaves the wait for the next tick. Its `client_id` names
  the wait on the day (`client_id/2`), so the accepted post is the
  receipt: one post per wait per daily thread, whatever its title has
  become since. It says what was true when it was posted, and nothing
  reads it again: a wait decided or archived after it leaves the post as
  history. The report that lands on the daily thread and the count stay
  as they are.

  ## The tick

  Every minute this process reads the cell's workspace threads that read
  working, needs you or error, a page at a time
  (`Arca.TurnStorage.nudge_candidates/2`), and works each page's
  athanors in turn under each one's job claim (`Arca.JobClaims`, kind
  `aqua_nudge`, keyed by the athanor), renewed before each acceptance and
  held in each acceptance's transaction, so a claim lost lands nothing
  more. It keeps nothing between ticks: whether a thread is due is
  decided from the rows each time and decided again under the thread's
  lock as it is accepted, so a restart, a lost answer or a change of the
  claim's holder leaves the next tick to find what is due, what landed
  stays landed, and a refusal that may pass (busy, held elsewhere, the
  engine down) writes nothing and is asked again.

  `:nudge_enabled` false leaves it unstarted: under the test sandbox a
  tick would work another test's threads, so the suite turns it off and
  ticks by hand (`tick/0`).
  """

  use GenServer

  require Logger
  require Prima.TestSeam

  alias Aqua.Tape
  alias Arca.JobClaims
  alias Arca.TurnStorage

  # The quiet period: of a working thread before its nudge, and of a
  # waiting one before its first reminder.
  @quiet_seconds 15 * 60
  @tick_ms 60_000
  @lease_ms 30_000
  @page 100

  @nudge "Nothing has happened in this workspace thread for #{div(@quiet_seconds, 60)} minutes, " <>
           "and its work is not finished. Say where it stands: report it done, " <>
           "report that it needs the person, or post what you are waiting for."

  @doc "The quiet period, in seconds: the one value both the nudge and the reminder wait."
  @spec quiet_seconds() :: pos_integer()
  def quiet_seconds, do: @quiet_seconds

  @doc "The nudge's line, the server's words to the thread's Aqua."
  @spec nudge_line() :: String.t()
  def nudge_line, do: @nudge

  @doc """
  The server's post of one wait: the workspace thread's title and what it
  waits on, as they are when it is posted.
  """
  @spec reminder_post(String.t(), String.t()) :: String.t()
  def reminder_post(title, "error"),
    do:
      "Needs your attention: the workspace thread \"#{title}\" ran into an error " <>
        "and has not been looked at since."

  def reminder_post(title, _needs_you),
    do:
      "Needs your attention: the workspace thread \"#{title}\" is waiting on you " <>
        "and has not been acted on since."

  @doc """
  The `client_id` of the server's post of a wait on the daily thread of
  `day`: the workspace thread and the wait's stamp, so one wait is posted
  once on a day.
  """
  @spec client_id(%{workspace_id: String.t(), waits_since: DateTime.t()}, Date.t()) ::
          String.t()
  def client_id(%{workspace_id: id, waits_since: %DateTime{} = since}, %Date{} = day),
    do: "wait:#{id}:#{DateTime.to_iso8601(since)}:#{Date.to_iso8601(day)}"

  @doc false
  def start_link(opts \\ []) do
    if Prima.TestSeam.value(true, fn -> Application.get_env(:cyfr, :nudge_enabled, true) end) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @impl true
  def init(opts) do
    send(self(), :tick)
    {:ok, %{tick_ms: Keyword.get(opts, :tick_ms, @tick_ms)}}
  end

  @impl true
  def handle_info(:tick, state) do
    _ = tick()
    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  @doc """
  One tick: each page of candidates in turn, each athanor of it under its
  claim. Answers what each athanor's work landed, by athanor. Never
  raises.
  """
  @spec tick() :: %{String.t() => map() | :busy | {:stopped, term()}}
  def tick do
    pages(nil, %{})
  catch
    # A tick has no caller to answer to: a read that raises must not take
    # the process down, whose restart would tick again at once.
    kind, reason ->
      Logger.warning(
        "[Aqua.Nudge] tick stopped: " <> Prima.LogFilter.format_exception(kind, reason)
      )

      %{}
  end

  # The cell's candidates a page at a time, each page's athanors worked as
  # they come: what one landed stays landed whatever a later page does,
  # and a page not read ends the tick.
  defp pages(cursor, answers) do
    case TurnStorage.nudge_candidates(cursor, @page) do
      {:ok, rows} ->
        answers =
          rows
          |> Enum.chunk_by(& &1.athanor_id)
          |> Enum.reduce(answers, fn [%{athanor_id: athanor_id} | _] = threads, answers ->
            answer = athanor(athanor_id, threads)
            Map.update(answers, athanor_id, answer, &merged(&1, answer))
          end)

        case rows do
          rows when length(rows) < @page -> answers
          rows -> pages({List.last(rows).athanor_id, List.last(rows).id}, answers)
        end

      {:error, reason} ->
        Logger.warning("[Aqua.Nudge] candidates not read: #{Prima.LoggerContext.shape(reason)}")
        answers
    end
  end

  # An athanor whose candidates two pages held: both works' counts.
  defp merged(%{} = first, %{} = second), do: Map.merge(first, second, fn _k, a, b -> a + b end)
  defp merged(_first, second), do: second

  # One athanor's candidates, under its claim, given up when the work
  # ends.
  defp athanor(athanor_id, threads) do
    case JobClaims.claim("aqua_nudge", athanor_id, Prima.Boot.id(), @lease_ms) do
      {:ok, claim} ->
        {answer, last} = work(Prima.Actor.in_athanor(athanor_id), threads, claim)
        _ = JobClaims.release(last)
        answer

      {:busy, _claim} ->
        :busy

      {:error, reason} ->
        {:stopped, reason}
    end
  end

  defp work(actor, threads, claim) do
    case Arca.ControlPlane.member_slot() do
      {:ok, slot} -> work(actor, threads, claim, slot)
      {:error, reason} -> {{:stopped, reason}, claim}
    end
  end

  defp work(actor, threads, claim, slot) do
    views =
      Enum.flat_map(threads, fn %{id: id} ->
        case TurnStorage.nudge_view(actor, id, @quiet_seconds) do
          {:ok, view} -> [view]
          {:error, _} -> []
        end
      end)

    with {:ok, counts, claim} <- nudges(actor, views, claim, slot),
         {:ok, counts, claim} <- reminders(actor, views, claim, slot, counts) do
      {counts, claim}
    else
      {:stopped, reason, claim} -> {{:stopped, reason}, claim}
    end
  end

  defp nudges(actor, views, claim, slot) do
    views
    |> Enum.filter(&(&1.due? and is_map(&1.work)))
    |> Enum.reduce_while({:ok, %{}, claim}, fn view, {:ok, counts, claim} ->
      case renewed(claim) do
        {:ok, fresh} ->
          outcome =
            case bound(actor, view.work) do
              {:ok, ctx} ->
                landed(Aqua.Runner.nudge(ctx, view.id, nudge_attrs(view.work, fresh, slot)))

              {:error, _unbound} ->
                "refused"
            end

          {:cont, {:ok, count(counts, outcome), fresh}}

        {:lost, reason} ->
          {:halt, {:stopped, reason, claim}}
      end
    end)
  end

  # Each wait due, one post each on the daily thread current now, unless
  # that thread holds the wait's post already.
  defp reminders(actor, views, claim, slot, counts) do
    waits =
      for %{state: state, waits_since: %DateTime{} = since, archived?: false} = view <- views,
          state in ["needs_you", "error"],
          TurnStorage.waited?(since, @quiet_seconds) == true,
          do: %{view | waits_since: since}

    with [_ | _] <- waits,
         {:ok, ctx} <- person(actor),
         {:ok, daily} <- Aqua.Day.current(ctx) do
      Enum.reduce_while(waits, {:ok, counts, claim}, fn view, {:ok, counts, claim} ->
        wait = %{workspace_id: view.id, waits_since: view.waits_since}
        client_id = client_id(wait, daily.day)

        case Tape.accepted(ctx, daily.id, client_id) do
          {:error, :not_found} ->
            case renewed(claim) do
              {:ok, fresh} ->
                outcome = posted(ctx, daily.id, view, client_id, fresh, slot)
                {:cont, {:ok, count(counts, "reminded:" <> outcome), fresh}}

              {:lost, reason} ->
                {:halt, {:stopped, reason, claim}}
            end

          # Posted already on this day, whatever its words were then.
          {:ok, _accepted} ->
            {:cont, {:ok, counts, claim}}

          {:error, _unread} ->
            {:cont, {:ok, count(counts, "reminded:refused"), claim}}
        end
      end)
    else
      _nothing_due_or_refused -> {:ok, counts, claim}
    end
  end

  # The wait's post, through the daily thread's runner as any post: a post
  # already there under its `client_id` (`:client_id_reused`, its words
  # since changed) is that wait's on this day.
  defp posted(ctx, daily_id, view, client_id, claim, slot) do
    ctx
    |> Aqua.Runner.send_message(daily_id, reminder_post(view.title, view.state),
      client_id: client_id,
      server: true,
      sent_by: Prima.Author.system(),
      workspace_id: view.id,
      wait: %{waits_since: view.waits_since, quiet: @quiet_seconds},
      claim: %{claim: claim, slot: slot}
    )
    |> case do
      {:ok, %{replayed: true}} -> "posted"
      {:error, :client_id_reused} -> "posted"
      answer -> landed(answer)
    end
  end

  # The claim renewed before an acceptance, which holds it again in its
  # own transaction; a claim lost stops the athanor's work for this tick.
  defp renewed(claim) do
    case JobClaims.renew(claim, @lease_ms) do
      {:ok, renewed} -> {:ok, renewed}
      {:error, reason} -> {:lost, reason}
      lost -> {:lost, lost}
    end
  end

  # The nudge's turn as the thread's current work's person, under its
  # origin, the person's standing asked again.
  defp bound(%Prima.Actor{athanor_id: athanor_id}, %{person: person, origin: origin}),
    do: Sanctum.Tenancy.continuation(person, athanor_id, origin)

  # The server's post as the athanor's person, under `schedule`.
  defp person(%Prima.Actor{athanor_id: athanor_id}) do
    with {:ok, %{owner_user_id: person}} <- Sanctum.Tenancy.Athanors.get(athanor_id),
         do: Sanctum.Tenancy.continuation(person, athanor_id, Prima.Origin.to_wire(:schedule))
  end

  # What the work's turn was asked to work under: the tools it narrowed to
  # and the brain options it set.
  defp nudge_attrs(%{options: options} = work, claim, slot) do
    kept =
      case is_binary(options) && Jason.decode(options) do
        {:ok, %{} = stored} -> Map.take(stored, ["tools", "brain_options"])
        _none -> %{}
      end

    %{
      content: @nudge,
      options: kept,
      work: work.id,
      quiet: @quiet_seconds,
      claim: claim,
      slot: slot
    }
  end

  defp landed({:ok, %{joined: true}}), do: "joined"
  defp landed({:ok, %{admitted: :steer}}), do: "joined"
  defp landed({:ok, _accepted}), do: "opened"
  defp landed({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp landed({:error, _reason}), do: "refused"

  defp count(counts, outcome), do: Map.update(counts, outcome, 1, &(&1 + 1))
end
