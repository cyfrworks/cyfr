# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Nudge do
  @moduledoc """
  The nudge of a quiet workspace thread and the reminder of one that waits
  on its person, both on the server's own clock, both after the one quiet
  period (`quiet_seconds/0`, fifteen minutes).

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
  and asks a model, read at its next model round from storage on
  whichever member runs it; with no turn open there it opens one, bound to
  the thread's current work: the newest turn of Aqua's there, whose
  person, origin and tools it keeps, the person's standing asked again
  (`Sanctum.Tenancy.continuation/3`); while an opening waits for its turn
  the opening is the work and no nudge opens a turn. Anything else open
  there (a page's call's turn, a turn paused on a card or an uncertain
  call, a queued one) leaves it to the next tick. An archived thread is
  neither nudged nor reminded, and no line of this process's takes one
  out of the archive. No second nudge comes while one is unanswered: until a model round of its turn has carried it
  and closed, or its turn ended. A nudge's turn is the thread's work as
  any turn is; one that ends with no report leaves the thread working,
  and the next quiet period runs from its end.

  ## The reminder

  A workspace thread that reads needs you or error has its daily
  thread's Aqua remind the person in a post: once the quiet period after
  its wait began (`waits_since`: when it came to read so, or the person
  last acted on it while it still waited), then once on each new day of
  the person's while it still waits. Each day's reminder is one turn of
  the daily thread current then, one row of the server's for each wait
  it names, naming its workspace thread, as the person under the
  `schedule` origin, since nobody is known to be present: it opens no
  card and borrows no schedule's occurrence or grants. A daily thread
  reminds of a wait at most once (`Arca.TurnStorage.remind/3`). The report
  that lands on the daily thread and the count stay as they are.

  ## The tick

  Every minute this process reads the cell's workspace threads that read
  working, needs you or error a page at a time
  (`Arca.TurnStorage.nudge_candidates/2`) and works each athanor's under
  its job claim (`Arca.JobClaims`, kind `aqua_nudge`, keyed by the
  athanor), renewed before each acceptance and held in each acceptance's
  transaction, so a claim lost lands nothing more. It keeps nothing
  between ticks: whether a thread is due is decided from the rows each
  time and decided again under the thread's lock as it is accepted, so a
  restart, a lost notice or a change of the claim's holder leaves the
  next tick to find what is due, and a refusal that may pass (busy, held
  elsewhere, the engine down) writes nothing and is asked again.

  `:nudge_enabled` false leaves it unstarted: under the test sandbox a
  tick would work another test's threads, so the suite turns it off and
  ticks by hand (`tick/0`).
  """

  use GenServer

  require Logger
  require Prima.TestSeam

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
  A reminder's line for one wait: the workspace thread's title and what
  it waits on.
  """
  @spec reminder_line(String.t(), String.t()) :: String.t()
  def reminder_line(title, "error"),
    do:
      "The workspace thread \"#{title}\" is in error: Aqua could not run it, " <>
        "and the person has not acted on it. Remind them of it in your post."

  def reminder_line(title, _needs_you),
    do:
      "The workspace thread \"#{title}\" needs the person, " <>
        "and they have not acted on it. Remind them of it in your post."

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
  One tick: every page of candidates, each athanor's under its claim.
  Answers what each athanor's work landed, by athanor. Never raises.
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

  defp pages(cursor, done) do
    case TurnStorage.nudge_candidates(cursor, @page) do
      {:ok, []} ->
        done

      {:ok, rows} ->
        done =
          rows
          |> Enum.chunk_by(& &1.athanor_id)
          |> Enum.reduce(done, fn [%{athanor_id: athanor_id} | _] = threads, done ->
            worked = athanor(athanor_id, threads)
            Map.update(done, athanor_id, worked, &merge(&1, worked))
          end)

        last = List.last(rows)
        if length(rows) < @page, do: done, else: pages({last.athanor_id, last.id}, done)

      {:error, reason} ->
        Logger.warning("[Aqua.Nudge] candidates not read: #{inspect(reason)}")
        done
    end
  end

  defp merge(%{} = a, %{} = b), do: Map.merge(a, b, fn _k, x, y -> x + y end)
  defp merge(_a, b), do: b

  # One athanor's candidates of one page, under its claim, given up when
  # the work ends.
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

  defp reminders(actor, views, claim, slot, counts) do
    waits =
      for %{state: state, waits_since: %DateTime{} = since, archived?: false} = view <- views,
          state in ["needs_you", "error"],
          TurnStorage.waited?(since, @quiet_seconds) == true,
          do: %{
            workspace_id: view.id,
            waits_since: since,
            content: reminder_line(view.title, state)
          }

    with [_ | _] <- waits,
         {:ok, ctx} <- person(actor),
         {:ok, [_ | _] = due} <- TurnStorage.unreminded(actor, Aqua.Day.today(ctx), waits),
         {:ok, daily} <- Aqua.Day.current(ctx) do
      case renewed(claim) do
        {:ok, fresh} ->
          attrs = %{waits: due, claim: fresh, slot: slot}
          outcome = landed(Aqua.Runner.remind(ctx, daily.id, attrs))
          {:ok, count(counts, "reminded:" <> outcome), fresh}

        {:lost, reason} ->
          {:stopped, reason, claim}
      end
    else
      _nothing_due_or_refused -> {:ok, counts, claim}
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

  # The reminder's turn as the athanor's person, under `schedule`.
  defp person(%Prima.Actor{athanor_id: athanor_id}) do
    with {:ok, %{owner_user_id: person}} <- Sanctum.Tenancy.Athanors.get(athanor_id),
         do: Sanctum.Tenancy.continuation(person, athanor_id, Prima.Origin.to_wire(:schedule))
  end

  # What the work's turn was asked to work under: the tools it narrowed to
  # and the brain options it set.
  defp nudge_attrs(%{options: options}, claim, slot) do
    kept =
      case is_binary(options) && Jason.decode(options) do
        {:ok, %{} = stored} -> Map.take(stored, ["tools", "brain_options"])
        _none -> %{}
      end

    %{content: @nudge, options: kept, quiet: @quiet_seconds, claim: claim, slot: slot}
  end

  defp landed({:ok, %{joined: true}}), do: "joined"
  defp landed({:ok, _accepted}), do: "opened"
  defp landed({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp landed({:error, _reason}), do: "refused"

  defp count(counts, outcome), do: Map.update(counts, outcome, 1, &(&1 + 1))
end
