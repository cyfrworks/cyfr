# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ScheduleNotesTest.Between do
  @moduledoc false
  # A storage cap that runs, once, what the test planted in the asking
  # process: `Arca.Storage.stage/3` asks it after the outcome's note was
  # read and before it is published.
  @behaviour Prima.Caps

  @impl Prima.Caps
  def check_counted(%Prima.Actor{}, _key, _count), do: :ok

  @impl Prima.Caps
  def check_storage(%Prima.Actor{}, _incoming) do
    case Process.delete(__MODULE__) do
      nil -> :ok
      between -> between.()
    end

    :ok
  end
end

defmodule Aqua.ScheduleNotesTest do
  # A schedule that asked to keep its outcome: the finish records the
  # outcome in the outbox in its own transaction, and the consumer files
  # the note from that record alone, once, under its job claim, over the
  # revision the run read — keeping a person's change, never writing over
  # a later outcome, and writing nothing once the authority is gone.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Arca.{ConsumerReceipts, ControlPlane, CronSchedule, ScheduleOccurrences}
  alias Aqua.ScheduleNotes
  alias Cyfr.Bus.ScheduleCompleted
  alias Opus.Schedules.Scheduler
  alias Sanctum.Test.ConsentFixtures

  @reference "reagent:local.notes"

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_path =
      Path.join(System.tmp_dir!(), "schedule_notes_#{System.unique_integer([:positive])}")

    original = Application.get_env(:arca, :base_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    Application.put_env(:arca, :base_path, test_path)
    on_exit(fn -> ControlPlane.record(:unclaimed) end)

    # The suite starts no keeper (`:schedule_notes_enabled`): a case drains
    # by hand, and a case about the process starts its own.
    previous = Application.fetch_env(:cyfr, :schedule_notes_enabled)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:cyfr, :schedule_notes_enabled, value)
        :error -> Application.delete_env(:cyfr, :schedule_notes_enabled)
      end
    end)

    Application.put_env(:cyfr, :schedule_notes_enabled, true)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    n = System.unique_integer([:positive])
    user = "local|idp|sched-#{n}"
    {:ok, athanor} = Sanctum.Tenancy.Athanors.create_group(user, "Ops #{n}")
    ctx = %{Sanctum.TestContext.local() | user_id: user, athanor_id: athanor.id}
    profile_id = "prof_notes_#{n}"
    :ok = granted!(ctx, profile_id)

    {:ok, user: user, athanor: athanor, ctx: ctx, profile_id: profile_id}
  end

  # This case's keeper, under the test's supervisor, which restarts it as
  # the member's restarts its own. Its tick is an hour away unless the case
  # asks for another; its boot drain has run when it is answered.
  defp keeper!(opts \\ []) do
    keeper = start_supervised!({ScheduleNotes, Keyword.put_new(opts, :tick_ms, :timer.hours(1))})
    :sys.get_state(keeper)
    keeper
  end

  # The profile a schedule fires under, with a head consent at revision 1.
  defp granted!(ctx, profile_id) do
    ConsentFixtures.seed_head!(
      ctx,
      %{id: profile_id, kind: :owner, source_ref: @reference, label: "default", status: :active},
      %{
        id: "consent-#{profile_id}",
        revision: 1,
        scope: :versionless,
        pinned_version: "",
        invoke_mode: :open_inert,
        shape_digest: "sha256:shape-#{profile_id}",
        commit_digest: "sha256:commit-#{profile_id}",
        resolved_policy: Jason.encode!(%{"canonical" => "jcs-1", "nodes" => %{}}),
        activation: %{},
        admitted_origins: [:schedule],
        vault_refs: []
      }
    )
  end

  defp schedule!(%{ctx: ctx, profile_id: profile_id}, metadata) do
    {:ok, schedule} =
      CronSchedule.create(Sanctum.Context.actor(ctx), %{
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        name: "sched-#{System.unique_integer([:positive])}",
        cron_expression: "0 * * * *",
        reference: @reference <> ":1.0.0",
        resolved_reference: @reference <> ":1.0.0",
        profile_id: profile_id,
        metadata: metadata,
        next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        cap: 1_000
      })

    schedule
  end

  defp keeping(context, name \\ nil) do
    metadata =
      if name,
        do: Jason.encode!(%{"keep_outcome" => true, "note_name" => name}),
        else: Jason.encode!(%{"keep_outcome" => true})

    schedule!(context, metadata)
  end

  # Occurrences of it may overlap, so an earlier one can finish last.
  defp overlapping!(schedule) do
    {1, _} =
      Arca.Repo.update_all(
        from(s in Arca.Schemas.CronSchedule, where: s.id == ^schedule.id),
        set: [concurrency: "allow"]
      )

    schedule
  end

  # One occurrence of `schedule`, due `seconds_ago`, claimed and started
  # under a fresh execution as an admission starts it.
  defp started!(schedule, seconds_ago) do
    due = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

    {1, _} =
      Arca.Repo.update_all(
        from(s in Arca.Schemas.CronSchedule, where: s.id == ^schedule.id),
        set: [next_run_at: due]
      )

    cadence = %{next_after: &{:ok, DateTime.add(&1, 3600, :second)}, missed_bound_ms: 600_000}

    {:ok, occurrence} =
      ScheduleOccurrences.claim(%{schedule | next_run_at: due}, Prima.Boot.id(), cadence)

    execution_id = Prima.UUID7.execution_id()
    actor = Prima.Actor.in_athanor(schedule.athanor_id)

    {:ok, 1} =
      Arca.Repo.transaction(fn ->
        ScheduleOccurrences.start!(actor, occurrence.id, Prima.Boot.id(), execution_id)
      end)

    # The schedule row as the scheduler reads it before the run.
    {:ok, read_before} = CronSchedule.get(actor, schedule.id)
    {Map.put(occurrence, :read_before, read_before), execution_id}
  end

  defp finished!({occurrence, execution_id}, output) do
    {:ok, 1} =
      Scheduler.complete(occurrence.read_before, occurrence, execution_id, output)

    {occurrence, execution_id}
  end

  defp ran!(schedule, seconds_ago, output),
    do: schedule |> started!(seconds_ago) |> finished!(output)

  # The run's read of its note, as the notes tool makes it in its chain.
  defp read_by_run(ctx, {_occurrence, execution_id}, name),
    do: Aqua.Notes.read(ctx, name, "athanor", root_execution_id: execution_id)

  # The outcome record the occurrence's finish wrote, by its source.
  defp source({occurrence, _execution_id}, _schedule) do
    Arca.Repo.one!(
      from(r in Arca.Schemas.OutboxRecord,
        where: r.source_kind == "schedule_occurrence" and r.source_id == ^occurrence.id,
        select: %{
          source_kind: r.source_kind,
          source_id: r.source_id,
          source_revision: r.source_revision
        }
      )
    )
  end

  defp outcome(athanor, source),
    do: ConsumerReceipts.outcome(Prima.Actor.in_athanor(athanor.id), "schedule_notes", source)

  defp drain(athanor), do: ScheduleNotes.drain(athanor.id)

  defp note(ctx, name), do: Aqua.Notes.current(ctx, name)

  defp plant(between), do: Process.put(Aqua.ScheduleNotesTest.Between, between)

  defp with_between(context) do
    installed = Prima.Caps.impl!()
    on_exit(fn -> Prima.Caps.install!(installed) end)
    Prima.Caps.install!(Aqua.ScheduleNotesTest.Between)
    context
  end

  describe "delivery" do
    setup :with_between

    test "a finished run's note is written once from its record, after its metadata changed and its payload was pruned, by a consumer restarted without the bus",
         %{athanor: athanor, ctx: ctx} = context do
      schedule = keeping(context, "nightly")
      run = ran!(schedule, 60, %{"summary" => "42 rows reconciled"})

      # What the note would be built from now says something else entirely.
      {:ok, _} =
        CronSchedule.update(Sanctum.Context.actor(ctx), schedule.id, %{
          metadata: Jason.encode!(%{"keep_outcome" => false, "note_name" => "elsewhere"})
        })

      assert {:ok, _} =
               Arca.Retention.cleanup(Sanctum.Context.actor(ctx), "schedule_payload_days",
                 value: 1
               )

      source = source(run, schedule)

      # The consumer starts after the completion was published, so it
      # never hears it: its boot drain finds the record.
      keeper = keeper!()
      assert {:ok, "applied"} = outcome(athanor, source)
      :ok = :sys.suspend(keeper)

      assert {:ok, %{revision: 1, note: note}} = note(ctx, "nightly")
      assert note.content =~ "42 rows reconciled"
      assert note.kept_by == "schedule:" <> schedule.id
      assert note.execution == elem(run, 1)
      assert {:ok, %{revision: 0}} = note(ctx, "elsewhere")
      assert {:ok, %{}} = drain(athanor)
      assert {:ok, %{revision: 1}} = note(ctx, "nightly")
    end

    test "the same record delivered twice keeps one note, once",
         %{athanor: athanor, ctx: ctx} = context do
      schedule = keeping(context)
      run = ran!(schedule, 60, "first")
      source = source(run, schedule)

      # Two drains at once under two owners: one holds the claim.
      answers =
        [
          Task.async(fn -> ScheduleNotes.drain(athanor.id, owner: "owner_a") end),
          Task.async(fn -> ScheduleNotes.drain(athanor.id, owner: "owner_b") end)
        ]
        |> Task.await_many(15_000)

      assert Enum.count(answers, &match?({:ok, %{"applied" => 1}}, &1)) == 1

      assert {:ok, %{}} = drain(athanor)
      assert {:ok, "applied"} = outcome(athanor, source)
      assert {:ok, %{revision: 1, note: %{content: "first"}}} = note(ctx, schedule.id)
    end

    test "a person's edit after the run read the note is kept, and the outcome is a conflict",
         %{athanor: athanor, ctx: ctx} = context do
      schedule = keeping(context, "nightly")
      {:ok, _} = Aqua.Notes.keep(ctx, "nightly", "the list as it was")

      started = started!(schedule, 60)
      assert {:ok, %{content: "the list as it was"}} = read_by_run(ctx, started, "nightly")
      {:ok, _} = Aqua.Notes.keep(ctx, "nightly", "corrected by hand")
      run = finished!(started, "the run's list")
      source = source(run, schedule)

      assert {:ok, %{"conflict" => 1}} = drain(athanor)
      assert {:ok, "conflict"} = outcome(athanor, source)
      assert {:ok, %{revision: 2, note: %{content: "corrected by hand"}}} = note(ctx, "nightly")
    end

    test "a person's edit after the run finished is kept, and the outcome is a conflict",
         %{athanor: athanor, ctx: ctx} = context do
      schedule = keeping(context, "nightly")
      started = started!(schedule, 60)
      assert {:error, {:not_found, "note", "nightly"}} = read_by_run(ctx, started, "nightly")
      run = finished!(started, "the run's list")
      {:ok, _} = Aqua.Notes.keep(ctx, "nightly", "written by hand")

      assert {:ok, %{"conflict" => 1}} = drain(athanor)
      assert {:ok, "conflict"} = outcome(athanor, source(run, schedule))
      assert {:ok, %{revision: 1, note: %{content: "written by hand"}}} = note(ctx, "nightly")
    end

    test "a run that read the note publishes over the revision it read",
         %{athanor: athanor, ctx: ctx} = context do
      schedule = keeping(context, "nightly")
      {:ok, _} = Aqua.Notes.keep(ctx, "nightly", "a person's start")
      started = started!(schedule, 60)
      assert {:ok, _} = read_by_run(ctx, started, "nightly")
      run = finished!(started, "the run's answer")

      assert {:ok, %{"applied" => 1}} = drain(athanor)
      assert {:ok, "applied"} = outcome(athanor, source(run, schedule))
      assert {:ok, %{revision: 2, note: %{content: "the run's answer"}}} = note(ctx, "nightly")
    end

    test "a repeating run that reads no note replaces its own outcome; a person's edit before the next delivery is kept",
         %{athanor: athanor, ctx: ctx} = context do
      schedule = keeping(context)

      first = ran!(schedule, 300, "first outcome")
      assert {:ok, %{"applied" => 1}} = drain(athanor)

      second = ran!(schedule, 200, "second outcome")
      assert {:ok, %{"applied" => 1}} = drain(athanor)
      assert {:ok, %{revision: 2, note: %{content: "second outcome"}}} = note(ctx, schedule.id)

      third = ran!(schedule, 100, "third outcome")
      {:ok, _} = Aqua.Notes.keep(ctx, schedule.id, "a person's correction")
      assert {:ok, %{"conflict" => 1}} = drain(athanor)

      assert {:ok, "applied"} = outcome(athanor, source(first, schedule))
      assert {:ok, "applied"} = outcome(athanor, source(second, schedule))
      assert {:ok, "conflict"} = outcome(athanor, source(third, schedule))

      assert {:ok, %{revision: 3, note: %{content: "a person's correction"}}} =
               note(ctx, schedule.id)
    end

    test "an earlier occurrence finishing after a later one's note landed is superseded",
         %{athanor: athanor, ctx: ctx} = context do
      schedule = context |> keeping() |> overlapping!()
      earlier = started!(schedule, 300)
      later = ran!(schedule, 100, "later outcome")
      assert {:ok, %{"applied" => 1}} = drain(athanor)

      earlier = finished!(earlier, "earlier outcome")
      assert {:ok, %{"superseded" => 1}} = drain(athanor)
      assert {:ok, "superseded"} = outcome(athanor, source(earlier, schedule))
      assert {:ok, "applied"} = outcome(athanor, source(later, schedule))
      assert {:ok, %{revision: 1, note: %{content: "later outcome"}}} = note(ctx, schedule.id)
    end

    test "the profile revoked after the note was staged refuses it: no note, the outcome refused",
         %{athanor: athanor, ctx: ctx, profile_id: profile_id} = context do
      schedule = keeping(context)
      run = ran!(schedule, 60, "kept once authority stands")
      source = source(run, schedule)

      plant(fn ->
        :ok =
          Arca.ProfileStorage.transition(Sanctum.Context.actor(ctx), profile_id, :any, "revoked")
      end)

      assert {:ok, %{"refused" => 1}} = drain(athanor)
      assert {:ok, "refused"} = outcome(athanor, source)
      assert {:ok, %{revision: 0}} = note(ctx, schedule.id)
    end

    test "a new head consent since the finish refuses the note",
         %{athanor: athanor, ctx: ctx} = context do
      schedule = keeping(context)
      run = ran!(schedule, 60, "kept under the old consent")
      _ = ConsentFixtures.regrant_origins!(ctx, context.profile_id, [:schedule, :interactive])

      assert {:ok, %{"refused" => 1}} = drain(athanor)
      assert {:ok, "refused"} = outcome(athanor, source(run, schedule))
      assert {:ok, %{revision: 0}} = note(ctx, schedule.id)
    end

    test "a crash after the note's publication and before its receipt rolls both back, and the next drain keeps one note",
         %{athanor: athanor, ctx: ctx} = context do
      schedule = keeping(context)
      run = ran!(schedule, 60, "kept with its receipt")
      source = source(run, schedule)

      # The receipt's table is gone once the note is staged: the
      # publication's statement lands, and the receipt beside it raises.
      plant(fn -> rename!("consumer_receipts", "consumer_receipts_away") end)

      assert {:stopped, {:unavailable, "Notes"}} = drain(athanor)
      rename!("consumer_receipts_away", "consumer_receipts")

      assert {:ok, %{revision: 0}} = note(ctx, schedule.id)
      assert :none = outcome(athanor, source)

      assert {:ok, %{"applied" => 1}} = drain(athanor)
      assert {:ok, "applied"} = outcome(athanor, source)

      assert {:ok, %{revision: 1, note: %{content: "kept with its receipt"}}} =
               note(ctx, schedule.id)
    end

    for loss <- [:lapsed, :taken] do
      test "a job claim #{loss} on a live member writes neither the note nor a receipt",
           %{athanor: athanor, ctx: ctx} = context do
        schedule = keeping(context)
        run = ran!(schedule, 60, "never written")
        source = source(run, schedule)

        plant(fn -> lose_claim!(athanor.id, unquote(loss)) end)

        assert {:stopped, unquote(loss)} = drain(athanor)
        assert :none = outcome(athanor, source)
        assert {:ok, %{revision: 0}} = note(ctx, schedule.id)

        assert {:ok, [_pending]} =
                 Arca.Outbox.pending(
                   Prima.Actor.in_athanor(athanor.id),
                   "schedule_notes",
                   "schedule_outcome"
                 )
      end
    end
  end

  describe "what is written" do
    test "a note named by the schedule's id, with the run as provenance, and a long output cut with a marker",
         %{athanor: athanor, ctx: ctx} = context do
      schedule = keeping(context)
      long = String.duplicate("é", 40_000)
      {_occurrence, execution_id} = ran!(schedule, 60, long)

      assert {:ok, %{"applied" => 1}} = drain(athanor)
      assert {:ok, %{note: note}} = note(ctx, schedule.id)
      assert note.kept_by == "schedule:" <> schedule.id
      assert note.execution == execution_id
      assert String.valid?(note.content)
      assert String.ends_with?(note.content, "longer than 64 KiB]")
      assert byte_size(note.content) <= 64 * 1024 + 100
    end

    test "the note carries the sources the run read, after its execution row is gone, and a send its flows do not cover is refused",
         %{athanor: athanor, ctx: ctx} = context do
      schedule = keeping(context, "nightly")
      {_occurrence, execution_id} = started = started!(schedule, 60)
      actor = Sanctum.Context.actor(ctx)
      vault = Prima.Source.new(:vault_disclosed)

      # The run read a disclosed vault value, and ended.
      {:ok, %{execution: row}} =
        Arca.Execution.admit(
          %{
            id: execution_id,
            reference: schedule.resolved_reference,
            profile_id: schedule.profile_id,
            user_id: ctx.user_id,
            athanor_id: ctx.athanor_id,
            component_type: "reagent",
            origin: :schedule,
            sources: []
          },
          Arca.Test.Actor.standing(ctx.athanor_id)
        )

      assert :ok = Opus.Ledger.join(actor, execution_id, [vault])

      {:ok, _ended} =
        Arca.Execution.record_end(
          actor,
          execution_id,
          "completed",
          %{completed_at: DateTime.utc_now(), duration_ms: 1},
          row.current_attempt,
          Arca.Test.Actor.stored()
        )

      finished!(started, "the run's list")

      # Retention removes the run's row before the note is delivered.
      {1, _} =
        Arca.Repo.delete_all(
          from(e in Arca.Schemas.Execution,
            where: e.athanor_id == ^ctx.athanor_id and e.id == ^execution_id
          )
        )

      assert {:ok, %{"applied" => 1}} = drain(athanor)
      assert {:ok, %{note: note}} = note(ctx, "nightly")
      assert note.sources == [vault]

      # A run that reads the note may send it only where a flow lets the
      # vault's class leave.
      reader = Prima.UUID7.execution_id()

      {:ok, _reader} =
        Arca.Execution.admit(
          %{
            id: reader,
            reference: "catalyst:local.reader:1.0.0",
            user_id: ctx.user_id,
            athanor_id: ctx.athanor_id,
            component_type: "catalyst",
            origin: :programmatic
          },
          Arca.Test.Actor.standing(ctx.athanor_id)
        )

      {:ok, answer} = Aqua.Notes.read(ctx, "nightly")

      assert :ok =
               Opus.Ledger.join(actor, reader, Aqua.Providers.Notes.answer_sources(actor, answer))

      filed_only = %Prima.Authority.Blob.Edge{flows: [%{from: :filed, to: "export.example"}]}

      assert {:refused, _uncovered} =
               Opus.Ledger.check(actor, reader, filed_only, {:domain, "export.example"})
    end

    test "a note_name no note may carry is refused, and the id is not used instead",
         %{athanor: athanor, ctx: ctx} = context do
      for name <- ["nightly: sync", "../escape", "about-us"] do
        schedule = keeping(context, name)
        _ = ran!(schedule, 60, "x")
        assert {:ok, %{"refused" => 1}} = drain(athanor)
        assert {:ok, %{revision: 0}} = note(ctx, schedule.id)
      end

      assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
    end

    test "a run nobody asked to keep writes nothing, and its record is answered",
         %{athanor: athanor, ctx: ctx} = context do
      schedule = schedule!(context, nil)
      run = ran!(schedule, 60, "not for keeping")

      assert {:ok, %{"applied" => 1}} = drain(athanor)
      assert {:ok, "applied"} = outcome(athanor, source(run, schedule))
      assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
    end

    test "a destination changed after the run read its note is a conflict, and the unread note it now names is kept",
         %{athanor: athanor, ctx: ctx} = context do
      schedule = keeping(context, "old")
      {:ok, _} = Aqua.Notes.keep(ctx, "old", "the old note")
      {:ok, _} = Aqua.Notes.keep(ctx, "new", "a person's unread note")
      run = started!(schedule, 60)
      assert {:ok, %{content: "the old note"}} = read_by_run(ctx, run, "old")

      {:ok, _} =
        CronSchedule.update(Sanctum.Context.actor(ctx), schedule.id, %{
          metadata: Jason.encode!(%{"keep_outcome" => true, "note_name" => "new"})
        })

      run = finished!(run, "the run's outcome")

      assert {:ok, %{"conflict" => 1}} = drain(athanor)
      assert {:ok, "conflict"} = outcome(athanor, source(run, schedule))
      assert {:ok, %{revision: 1, note: %{content: "a person's unread note"}}} = note(ctx, "new")
      assert {:ok, %{revision: 1, note: %{content: "the old note"}}} = note(ctx, "old")
    end

    test "an athanor archived after the note was staged gets no note, and the outcome is refused",
         %{athanor: athanor, ctx: ctx} = context do
      schedule = keeping(context)
      run = ran!(schedule, 60, "must not land after archive")
      with_between(context)
      plant(fn -> {:ok, _} = Sanctum.Tenancy.Athanors.archive(athanor) end)

      assert {:ok, %{"refused" => 1}} = drain(athanor)
      assert {:ok, "refused"} = outcome(athanor, source(run, schedule))
      assert {:ok, %{revision: 0}} = note(ctx, schedule.id)
    end

    test "an archived athanor's schedule writes nothing", %{athanor: athanor} = context do
      schedule = keeping(context)
      run = ran!(schedule, 60, "x")
      {:ok, _} = Sanctum.Tenancy.Athanors.archive(athanor)

      assert {:ok, %{"refused" => 1}} = drain(athanor)
      assert {:ok, "refused"} = outcome(athanor, source(run, schedule))
    end
  end

  describe "the member's slot" do
    setup context do
      keys = [{ControlPlane, :standing}, {ControlPlane, :generation}, {ControlPlane, :slot}]
      saved = Map.new(keys, &{&1, :persistent_term.get(&1, :absent)})

      on_exit(fn ->
        for {key, value} <- saved do
          if value == :absent,
            do: :persistent_term.erase(key),
            else: :persistent_term.put(key, value)
        end
      end)

      with_between(context)
      node = "node-sched-#{System.unique_integer([:positive])}"
      {:ok, slot} = ControlPlane.take(node, node <> "#boot_a", 60_000)
      {:ok, slot: slot}
    end

    test "is what the note is kept under", %{athanor: athanor, ctx: ctx} = context do
      schedule = keeping(context)
      _ = ran!(schedule, 60, "x")
      assert {:ok, %{"applied" => 1}} = drain(athanor)
      assert {:ok, %{revision: 1}} = note(ctx, schedule.id)
    end

    test "taken over between the read and the publication publishes nothing and answers nothing",
         %{athanor: athanor, ctx: ctx, slot: slot} = context do
      schedule = keeping(context)
      run = ran!(schedule, 60, "x")
      plant(fn -> take_over!(slot) end)

      assert {:stopped, _} = drain(athanor)
      assert :none = outcome(athanor, source(run, schedule))
      assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
    end

    test "run out with no successor publishes nothing",
         %{athanor: athanor, ctx: ctx, slot: slot} = context do
      schedule = keeping(context)
      run = ran!(schedule, 60, "x")
      plant(fn -> expire!(slot) end)

      assert {:stopped, _} = drain(athanor)
      assert :none = outcome(athanor, source(run, schedule))
      assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
    end
  end

  describe "the process" do
    test "drains the athanor a completion it hears names",
         %{athanor: athanor, ctx: ctx} = context do
      schedule = keeping(context)
      keeper = keeper!()
      :ok = :sys.suspend(keeper)
      {_occurrence, execution_id} = ran!(schedule, 60, "heard")
      :ok = :sys.resume(keeper)

      completion =
        ScheduleCompleted.new(Prima.Actor.in_athanor(athanor.id))

      :ok = Cyfr.Bus.broadcast_global(Cyfr.Bus.schedule_completions(), completion)
      # One round trip: the completion ahead of it has been handled.
      :sys.get_state(keeper)

      assert {:ok, %{revision: 1, note: %{content: "heard"}}} = note(ctx, schedule.id)
    end

    test "drains on its tick a record no completion named", %{athanor: athanor} do
      keeper = keeper!(tick_ms: 100)

      # Written straight to the outbox, so nothing is published: only the
      # tick reaches it. A run nobody asked to keep is answered with
      # nothing written.
      record = unkept_record!(athanor.id)
      source = Prima.OutboxRecord.source(record)

      wait_until(
        fn -> match?({:ok, "applied"}, outcome(athanor, source)) end,
        5_000,
        "the keeper's tick to answer the record"
      )

      assert Process.whereis(ScheduleNotes) == keeper
    end

    test "is subscribed again after a restart" do
      before = keeper!()
      ref = Process.monitor(before)
      Process.exit(before, :kill)
      assert_receive {:DOWN, ^ref, :process, ^before, :killed}

      :ok =
        wait_until(
          fn -> Process.whereis(ScheduleNotes) not in [nil, before] end,
          5_000,
          "the notes keeper to restart"
        )

      restarted = Process.whereis(ScheduleNotes)
      assert Cyfr.Bus.schedule_completions() in Registry.keys(Cyfr.PubSub, restarted)
    end

    test "survives a completion that names an athanor with nothing to keep" do
      keeper = keeper!()

      completion =
        ScheduleCompleted.new(Prima.Actor.in_athanor("ath_nowhere"))

      :ok = Cyfr.Bus.broadcast_global(Cyfr.Bus.schedule_completions(), completion)
      :sys.get_state(keeper)
      assert Process.whereis(ScheduleNotes) == keeper
    end
  end

  # An outcome record of a run nobody asked to keep, in `athanor_id`'s
  # outbox, as a finish writes it.
  defp unkept_record!(athanor_id) do
    actor = Prima.Actor.in_athanor(athanor_id)
    now = DateTime.utc_now()

    record =
      Prima.OutboxRecord.schedule_outcome(%{
        occurrence: %{
          id: Prima.UUID7.generate_id("occ"),
          athanor_id: athanor_id,
          scheduled_for: now,
          execution_id: Prima.UUID7.execution_id(),
          note_revision_read: nil
        },
        schedule: %{id: "sched_unkept", profile_id: "prof_unkept", updated_at: now},
        consent_revision: nil,
        keep: {false, nil},
        output: "not for keeping",
        sources: []
      })

    :ok = Arca.Outbox.put!(actor, record)
    record
  end

  defp lose_claim!(athanor_id, :lapsed) do
    past = DateTime.add(Arca.ServerMetaStorage.now!(), -1_000, :millisecond)

    {1, _} =
      Arca.Repo.update_all(
        from(c in Arca.Schemas.JobClaim,
          where: c.kind == "schedule_notes" and c.key == ^athanor_id
        ),
        set: [lease_until: past]
      )

    :ok
  end

  defp lose_claim!(athanor_id, :taken) do
    {1, _} =
      Arca.Repo.update_all(
        from(c in Arca.Schemas.JobClaim,
          where: c.kind == "schedule_notes" and c.key == ^athanor_id
        ),
        set: [owner: "boot_peer"],
        inc: [fence: 1]
      )

    :ok
  end

  defp rename!(from, to) do
    Arca.Repo.query!(~s(ALTER TABLE "#{from}" RENAME TO "#{to}"))
    :ok
  end

  defp take_over!(%{node: node, generation: generation, fence: fence}) do
    {1, _} =
      Arca.Repo.update_all(from(l in Arca.Schemas.CellLease, where: l.node == ^node),
        set: [owner: node <> "#boot_b", generation: generation + 1, fence: fence + 1]
      )

    :ok
  end

  defp expire!(%{node: node}) do
    past = DateTime.add(Arca.ServerMetaStorage.now!(), -1_000, :millisecond)

    {1, _} =
      Arca.Repo.update_all(from(l in Arca.Schemas.CellLease, where: l.node == ^node),
        set: [lease_until: past]
      )

    :ok
  end
end

defmodule Aqua.ScheduleNotesSchedulerTest do
  @moduledoc """
  The whole path, through the real scheduler: a fired run whose schedule
  keeps its outcome completes while the member's notes keeper is held,
  the keeper then dies with the completion it was woken by unread, and
  the restarted keeper keeps the note from the record the finish wrote.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Arca.{CronSchedule, ScheduleOccurrences}
  alias Cyfr.Test.ScriptedWorker
  alias Opus.Schedules.Scheduler
  alias Prima.Test.AuthorityFixtures
  alias Sanctum.Test.ConsentFixtures

  @reference "reagent:local.test"
  @profile_id "prof_test"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    test_path = Path.join(System.tmp_dir!(), "notes_sched_#{System.unique_integer([:positive])}")

    keys = [
      cyfr: :cron_scheduler_enabled,
      cyfr: :schedule_notes_enabled,
      cyfr: :locus_runtime_workers,
      arca: :base_path
    ]

    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id)
      File.rm_rf!(test_path)

      # A switch the suite holds `false` is put back as `false`: deleted,
      # it would read as its default, on.
      for {{app, key}, value} <- prev do
        if is_nil(value),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end
    end)

    Application.put_env(:cyfr, :cron_scheduler_enabled, true)
    Application.put_env(:cyfr, :schedule_notes_enabled, true)

    Application.put_env(
      :cyfr,
      :locus_runtime_workers,
      ScriptedWorker.workers(@reference, prev[{:cyfr, :locus_runtime_workers}])
    )

    Application.put_env(:arca, :base_path, test_path)
    Cyfr.Test.Sandbox.stop_work_on_exit()

    Sanctum.TestContext.ready!(ctx.athanor_id)
    granted!(ctx)
    {:ok, ctx: ctx}
  end

  defp granted!(ctx) do
    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
        name: "test",
        version: "1.0.0",
        type: "reagent"
      })

    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{
          id: @profile_id,
          kind: :owner,
          source_ref: @reference,
          label: "default",
          status: :active
        },
        %{
          id: "consent-#{@profile_id}",
          revision: 1,
          scope: :versionless,
          pinned_version: "",
          invoke_mode: :open_inert,
          shape_digest: "sha256:shape-#{@profile_id}",
          commit_digest: "sha256:commit-#{@profile_id}",
          resolved_policy:
            Jason.encode!(%{
              "canonical" => "jcs-1",
              "nodes" => %{
                @reference => %{
                  "limits" => AuthorityFixtures.limits_map(),
                  "edges" => %{"@ingress" => %{}}
                }
              }
            }),
          activation: %{@reference => component.release_digest},
          admitted_origins: [:interactive, :schedule],
          vault_refs: []
        }
      )
  end

  test "a fired run's note is kept by the restarted keeper, the completion that woke it lost", %{
    ctx: ctx
  } do
    # The keeper is held still, so the completion that wakes it waits
    # unread in its mailbox.
    keeper = start_supervised!({Aqua.ScheduleNotes, tick_ms: :timer.hours(1)})
    :ok = :sys.suspend(keeper)

    {:ok, schedule} =
      CronSchedule.create(Sanctum.Context.actor(ctx), %{
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        name: "sched-#{System.unique_integer([:positive])}",
        cron_expression: "0 * * * *",
        reference: "reagent:local.test:1.0.0",
        resolved_reference: "reagent:local.test:1.0.0",
        profile_id: @profile_id,
        metadata: ~s({"keep_outcome": true, "note_name": "nightly-run"}),
        next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        cap: 1_000
      })

    {1, _} =
      Arca.Repo.update_all(from(s in Arca.Schemas.CronSchedule, where: s.id == ^schedule.id),
        set: [next_run_at: DateTime.add(DateTime.utc_now(), -5, :second)]
      )

    start_supervised!({ScriptedWorker, ref: @reference, script: [%{"ran" => true}]})
    start_supervised!(Scheduler)

    wait_until(
      fn ->
        match?(
          {:ok, [%{state: "completed"}]},
          ScheduleOccurrences.list(Sanctum.Context.actor(ctx), schedule.id)
        )
      end,
      15_000,
      "the run to complete"
    )

    # The keeper dies with the completion it was woken by still unread.
    ref = Process.monitor(keeper)
    Process.exit(keeper, :kill)
    assert_receive {:DOWN, ^ref, :process, ^keeper, :killed}

    wait_until(
      fn ->
        match?({:ok, %{revision: 1}}, Aqua.Notes.current(ctx, "nightly-run"))
      end,
      10_000,
      "the restarted keeper to keep the note"
    )

    assert {:ok, %{note: note}} = Aqua.Notes.current(ctx, "nightly-run")
    assert note.content =~ "ran"
    assert note.kept_by == "schedule:" <> schedule.id
  end
end
