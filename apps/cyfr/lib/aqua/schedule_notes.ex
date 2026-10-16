# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ScheduleNotes do
  @moduledoc """
  A schedule that asked to keep what it did. `keep_outcome: true` in a
  schedule's metadata (`Opus.Schedules.Provider`) files every completed
  run's output as a note in the schedule's athanor (`Aqua.Notes`) — named
  by the metadata's `note_name`, else by the schedule's id — with the
  schedule and the execution as provenance, capped so one run cannot fill
  a ledger. Each run replaces the note before it, and a note someone else
  changed since the run read it is kept as they left it.

  ## Durable delivery

  The run's finish records its outcome in the outbox in the finish's own
  transaction (`Opus.Schedules.Scheduler`, `Prima.OutboxRecord`), with
  everything the note is made of in the record's snapshot: the output as
  the run stored it, the note's name and the choice to keep it as they
  stood at the finish, the authority the run fired under, and the
  revision of the note the run read (`read_by_run/4`). Nothing here reads
  the run's payload or the schedule's metadata again, so a payload pruned
  or metadata changed since the finish changes nothing that is written.

  This consumer (`"schedule_notes"`) works an athanor's pending records
  under its job claim (`Arca.JobClaims`, kind `schedule_notes`, keyed by
  the athanor id), so of the members that hear of the same work exactly
  one does it, and a member whose claim was taken or ran out stops. It
  drains on a completion it hears (`Cyfr.Bus.schedule_completions/0`, a
  wake-up and nothing more: any member may act on it), at boot, and on a
  tick that also reaches the work a dead member's claim left behind
  once that claim's lease has lapsed. A record is worked once: the
  receipt (`Arca.ConsumerReceipts`) is written in the transaction that
  publishes the note, or alone where nothing is published, and a record
  holding one is no longer pending.

  ## What each record comes to

  The records of an athanor are worked in the order their occurrences
  were due. Each is answered with one receipt outcome:

    * `applied` — the note was published, over the revision the run read
      it at (`absent`, a run that read none, publishes over nothing), or
      over the current revision when that one is this schedule's own
      earlier outcome (`kept_by` `schedule:<id>`), so a run that reads no
      note still replaces the outcome before it. A record of a run nobody
      asked to keep is applied with nothing written.
    * `superseded` — the note already holds a later occurrence's outcome
      of this schedule, which is never written over.
    * `conflict` — the note changed since the run read it, and not by this
      schedule: it is kept as it is, and the outcome is not written.
    * `refused` — the authority the record was recorded under is gone, or
      the athanor is archived, or the note's name is not one a note may
      have.

  The note's bytes are staged outside any transaction, then published in
  one transaction under this member's live slot (`Aqua.Notes.keep_fenced/6`)
  whose `verify:` holds the job claim at its fence and checks that the
  schedule still exists, its profile is active and that profile's head
  consent is still at the snapshot's revision
  (`Arca.ScheduleOccurrences.authority/2`), and whose `also:` writes the
  `applied` receipt. A claim lost there writes nothing and stops the
  drain; authority gone writes the `refused` receipt instead. A receipt
  written alone, with no note beside it, is fenced the same way: by the
  claim and by this member's slot.

  The write runs under the server's own context, able to read and write
  storage and nothing more, refocused on the record's athanor.
  """

  use GenServer

  require Logger

  alias Arca.{ConsumerReceipts, JobClaims, ScheduleOccurrences}
  alias Cyfr.Bus.ScheduleCompleted
  alias Sanctum.Context

  @consumer "schedule_notes"
  @kind "schedule_outcome"
  @lease_ms 30_000
  @tick_ms 30_000
  @marker "\n\n[cut — the outcome was longer than 64 KiB]"
  # A note moved between the decision and the publication is decided
  # again, this many times, before the record waits for the next drain.
  @rounds 3

  @typedoc "What one drain of an athanor did."
  @type drained ::
          {:ok, %{String.t() => non_neg_integer()}}
          | :busy
          | {:stopped, term()}
          | {:error, term()}

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.schedule_completions())
    send(self(), :drain_all)
    {:ok, %{tick_ms: Keyword.get(opts, :tick_ms, @tick_ms)}}
  end

  @impl true
  def handle_info(%ScheduleCompleted{athanor_id: athanor_id}, state) do
    _ = drain(athanor_id)
    {:noreply, state}
  end

  def handle_info(:drain_all, state) do
    _ = drain_all()
    Process.send_after(self(), :drain_all, state.tick_ms)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  @doc """
  Drain every athanor holding a record this consumer has not receipted.
  Answers each athanor's drain. Never raises.
  """
  @spec drain_all(keyword()) :: %{String.t() => drained()}
  def drain_all(opts \\ []) do
    case Arca.Outbox.pending_athanors(@consumer, @kind) do
      {:ok, athanors} ->
        Map.new(athanors, &{&1, drain(&1, opts)})

      {:error, reason} ->
        Logger.warning("[ScheduleNotes] pending records not read: #{inspect(reason)}")
        %{}
    end
  catch
    # The tick runs with no caller to answer to: a read that raises here
    # (under the test sandbox, a tick between two tests holds no
    # connection owner, and `with_db_rescue` does not cover that error)
    # must not take the keeper down, since a keeper restarted by its
    # supervisor ticks again at once and the loop ends with the whole
    # tree. The next tick, or the next completion, drains.
    kind, reason ->
      Logger.warning(
        "[ScheduleNotes] pending records not read: " <>
          Prima.LogFilter.format_exception(kind, reason)
      )

      %{}
  end

  @doc """
  Work `athanor_id`'s pending records under this consumer's claim on it,
  in the order their occurrences were due. Answers the count of each
  receipt outcome written; `:busy` when another holder has the claim;
  `{:stopped, reason}` when the claim was lost, or a record could not be
  worked and waits for the next drain, after the outcomes before it. The
  claim is given up when the drain ends. Never raises.

  `opts`: `:owner` (the claim's owner, this boot by default) and
  `:lease_ms`.
  """
  @spec drain(String.t(), keyword()) :: drained()
  def drain(athanor_id, opts \\ []) when is_binary(athanor_id) and athanor_id != "" do
    owner = Keyword.get(opts, :owner, Prima.Boot.id())
    lease_ms = Keyword.get(opts, :lease_ms, @lease_ms)
    actor = Prima.Actor.in_athanor(athanor_id)

    # Asked first without the claim, so a wake with nothing to do writes
    # nothing; asked again under it, where the answer counts.
    with {:ok, [_ | _]} <- Arca.Outbox.pending(actor, @consumer, @kind),
         {:ok, claim} <- JobClaims.claim(@consumer, athanor_id, owner, lease_ms) do
      under_claim(actor, claim, lease_ms)
    else
      {:ok, []} -> {:ok, %{}}
      {:busy, _claim} -> :busy
      {:error, _} = refused -> refused
    end
  catch
    kind, reason ->
      Logger.warning(
        "[ScheduleNotes] the notes of #{athanor_id} were not drained: " <>
          Prima.LogFilter.format_exception(kind, reason)
      )

      {:error, :crashed}
  end

  # The claim this drain holds is carried forward through every renewal,
  # and the newest one is given up at the end, whatever the drain did. A
  # drain that raised gives up the claim it took; a renewal since leaves
  # that one taken, and its lease runs out by itself.
  defp under_claim(actor, claim, lease_ms) do
    {answer, last} =
      try do
        worked(actor, claim, lease_ms)
      catch
        kind, reason ->
          _ = JobClaims.release(claim)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    _ = JobClaims.release(last)
    answer
  end

  defp worked(actor, claim, lease_ms) do
    case Arca.Outbox.pending(actor, @consumer, @kind) do
      {:ok, records} ->
        records
        |> Enum.sort_by(&due/1, DateTime)
        |> Enum.reduce_while({%{}, claim}, fn record, {counts, claim} ->
          case work(record, claim) do
            {:ok, outcome} ->
              counts = Map.update(counts, outcome, 1, &(&1 + 1))

              case JobClaims.renew(claim, lease_ms) do
                {:ok, renewed} -> {:cont, {counts, renewed}}
                lost -> {:halt, {{:stopped, lost}, claim}}
              end

            {:stop, reason} ->
              {:halt, {{:stopped, reason}, claim}}
          end
        end)
        |> case do
          {%{} = counts, last} -> {{:ok, counts}, last}
          {stopped, last} -> {stopped, last}
        end

      {:error, _} = refused ->
        {refused, claim}
    end
  end

  defp due(%Prima.OutboxRecord{snapshot: %{"scheduled_for" => at}}) do
    case DateTime.from_iso8601(at || "") do
      {:ok, due, _offset} -> due
      _unreadable -> ~U[1970-01-01 00:00:00Z]
    end
  end

  # ---- one record --------------------------------------------------------------

  # `{:ok, outcome}` once its receipt is written, or `{:stop, reason}`:
  # the claim is lost, or the record could not be worked now.
  defp work(%Prima.OutboxRecord{snapshot: snapshot} = record, claim) do
    actor = Prima.Actor.in_athanor(record.athanor_id)
    name = snapshot["note_name"] || snapshot["schedule_id"]

    cond do
      snapshot["keep_outcome"] != true ->
        receipted(actor, record, claim, "applied")

      Aqua.Notes.check_name(name) != :ok or Aqua.Notes.pinned?(name) ->
        Logger.warning(
          "[ScheduleNotes] schedule #{snapshot["schedule_id"]} names a note that cannot be " <>
            "kept; its outcome is refused"
        )

        receipted(actor, record, claim, "refused")

      true ->
        case context(record.athanor_id) do
          {:ok, ctx} -> decided(ctx, actor, record, name, claim, @rounds)
          {:error, :archived} -> receipted(actor, record, claim, "refused")
          {:error, reason} -> {:stop, reason}
        end
    end
  end

  defp context(athanor_id) do
    [permissions: [:storage_read, :storage_write]]
    |> Context.internal()
    |> Context.refocus(athanor_id)
  end

  defp decided(_ctx, _actor, _record, _name, _claim, 0), do: {:stop, :note_moving}

  defp decided(ctx, actor, record, name, claim, rounds) do
    with {:ok, %{revision: current, note: note}} <- Aqua.Notes.current(ctx, name),
         {:ok, standing} <- standing(actor, record, current, note) do
      case standing do
        {:publish, over} ->
          case published(ctx, actor, record, name, over, claim) do
            :again -> decided(ctx, actor, record, name, claim, rounds - 1)
            done -> done
          end

        {:receipt, outcome} ->
          receipted(actor, record, claim, outcome)
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # What the note as it stands means for this record: publish over its
  # current revision, or answer the record without writing.
  defp standing(actor, %Prima.OutboxRecord{snapshot: snapshot} = record, current, note) do
    schedule_id = snapshot["schedule_id"]
    own? = match?(%{kept_by: "schedule:" <> ^schedule_id}, note)

    read =
      case Prima.OutboxRecord.note_revision_read(record) do
        :absent -> 0
        revision -> revision
      end

    cond do
      own? and note.execution == snapshot["execution_id"] ->
        {:ok, {:receipt, "applied"}}

      own? ->
        with {:ok, later?} <- later?(actor, record, note.execution) do
          {:ok, if(later?, do: {:receipt, "superseded"}, else: {:publish, current})}
        end

      current == read ->
        {:ok, {:publish, current}}

      true ->
        {:ok, {:receipt, "conflict"}}
    end
  end

  # Whether the note's own outcome is a later occurrence's than this
  # record's: one due after it.
  defp later?(_actor, _record, nil), do: {:ok, false}

  defp later?(actor, %Prima.OutboxRecord{snapshot: snapshot} = record, execution_id) do
    case ScheduleOccurrences.scheduled_for(actor, snapshot["schedule_id"], execution_id) do
      {:ok, landed} -> {:ok, DateTime.compare(landed, due(record)) == :gt}
      :none -> {:ok, false}
      {:error, _} = refused -> refused
    end
  end

  defp published(ctx, actor, %Prima.OutboxRecord{snapshot: snapshot} = record, name, over, claim) do
    authority = %{
      schedule_id: snapshot["schedule_id"],
      profile_id: snapshot["profile_id"],
      consent_revision: snapshot["consent_revision"]
    }

    applied = receipt(record, "applied")

    case Aqua.Notes.keep_fenced(
           ctx,
           name,
           body(snapshot),
           over,
           [kept_by: "schedule:" <> snapshot["schedule_id"], execution: snapshot["execution_id"]],
           verify: fn ->
             with :ok <- held(JobClaims.hold(claim)),
                  do: ScheduleOccurrences.authority(actor, authority)
           end,
           also: fn _revision ->
             # The claim again, on the clock read after every lock the
             # publication waited on, the member's lease row among them.
             with :ok <- held(JobClaims.hold(claim)),
                  do: ConsumerReceipts.put!(actor, applied)
           end
         ) do
      {:ok, _kept} ->
        {:ok, "applied"}

      # The note moved after it was read: decided again from what stands.
      {:error, {:conflict, _}} ->
        :again

      {:error, {:declined, :authority_gone}} ->
        receipted(actor, record, claim, "refused")

      {:error, {:declined, :receipted}} ->
        {:ok, "applied"}

      {:error, {:declined, lost}} when lost in [:taken, :lapsed] ->
        {:stop, lost}

      {:error, reason} ->
        Logger.warning(
          "[ScheduleNotes] the note of schedule #{snapshot["schedule_id"]} was not kept: " <>
            inspect(reason)
        )

        {:stop, reason}
    end
  end

  defp held({:ok, _claim}), do: :ok
  defp held(lost) when lost in [:taken, :lapsed], do: {:error, lost}

  # A receipt with nothing published beside it, under the claim and this
  # member's slot, as a publication is.
  defp receipted(actor, record, claim, outcome) do
    with {:ok, slot} <- Arca.ControlPlane.member_slot(),
         :ok <- ConsumerReceipts.record(actor, claim, slot, receipt(record, outcome)) do
      {:ok, outcome}
    else
      {:error, :receipted} -> {:ok, outcome}
      lost when lost in [:taken, :lapsed] -> {:stop, lost}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp receipt(record, outcome) do
    record
    |> Prima.OutboxRecord.source()
    |> Map.merge(%{consumer: @consumer, outcome: outcome})
  end

  defp body(snapshot) do
    case {snapshot["output"], snapshot["truncated"]} do
      {nil, _truncated} -> "null"
      {output, true} -> output <> @marker
      {output, _whole} -> output
    end
  end

  # ---- the run's read ------------------------------------------------------------

  @doc """
  Record that the run under `root_execution_id` read `name` at `revision`
  (0 for no note), when `name` is its schedule's note and the run has
  read none before: the revision its outcome is published over. A read
  that is not a scheduled run's first read of its schedule's note records
  nothing. Answers `:ok`, or `{:error, :unavailable}` when the store could
  not answer.
  """
  @spec read_by_run(Prima.Actor.t(), String.t(), String.t(), non_neg_integer()) ::
          :ok | {:error, :unavailable}
  def read_by_run(%Prima.Actor{} = actor, root_execution_id, name, revision)
      when is_binary(root_execution_id) and is_binary(name) and is_integer(revision) do
    case ScheduleOccurrences.unread(actor, root_execution_id) do
      {:ok, %{id: occurrence_id, schedule_id: schedule_id, metadata: metadata}} ->
        note_name =
          case Prima.OutboxRecord.keep_pair(metadata) do
            {:ok, {_keep?, note_name}} -> note_name
            {:error, :invalid_json} -> nil
          end

        if (note_name || schedule_id) == name do
          case ScheduleOccurrences.note_read(actor, occurrence_id, root_execution_id, revision) do
            recorded when recorded in [:ok, :unchanged] -> :ok
            {:error, _} -> {:error, :unavailable}
          end
        else
          :ok
        end

      :none ->
        :ok

      {:error, _} ->
        {:error, :unavailable}
    end
  end
end
