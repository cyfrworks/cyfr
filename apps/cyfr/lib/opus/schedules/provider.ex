# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Schedules.Provider do
  @moduledoc """
  The `schedule` tool: creating, listing, updating, pausing, resuming and
  deleting an athanor's recurring component executions
  (`Arca.CronSchedule`), and telling the scheduler
  (`Opus.Schedules.Scheduler`) what changed. A schedule's `concurrency`
  — `forbid` (the default) or `allow` — says whether a due occurrence may
  run while another of the same schedule is still open. Its `missed_runs`
  — `skip` (the default) or `catch_up` with a `catch_up_limit` of 1 to
  `Opus.Schedules.Scheduler.max_catch_up/0` — says what becomes of the due
  times the cell missed (`Opus.Schedules.Scheduler`).

  Every action reads rows of kind `schedule` only: a feed shares the
  table (`Opus.Feeds`), but its id or name is `not_found` here, `list`
  omits it, and the schedules' cap counts schedules alone. Every write
  that commits announces the row (`Opus.Schedules.Changes`): `changed`
  after a create, an update, a pause, a resume or a re-resolve, and
  `removed` after a delete.

  The streams (`streams/0`) are canvas-readable, each declaring a shape,
  taking no subject, and carrying the delivery contract
  (`Compendium.Canvas.catalog/1`):

    * `schedules.changes` rides the athanor's schedules topic. Its
      refresh is every live schedule of the athanor, paused ones
      included, as `changed` (`live_schedules/2`). An item is a
      schedule, which leaves as `removed`.
    * `schedule_runs.changes` rides the athanor's schedule runs topic. Its
      refresh is the athanor's 20 newest occurrences of schedules
      (`recent_runs/2`). An item is an occurrence, which never leaves; a
      schedule that failed before it claimed any occurrence is told with
      no `occurrence_id`, a change that names no item.

  Neither carries a schedule's input, metadata, profile, pinned
  reference, maker or feed columns.

  ## A line for Aqua

  A schedule may hold a line for Aqua instead of a component: reference
  `agent:local.aqua` (`Arca.CronSchedule.aqua_line/0`) and input
  `{"line": text}`, binding no profile, since each fire is a turn of Aqua
  as the schedule's person, with nobody present (`Aqua.ScheduleTurns`).
  What Aqua reads when one fires is its line, its time and its room
  (`thread_id`, set at create and never changed). Only that person makes
  one, turns a schedule into one or out of one, or changes its line or its
  time (`cron_expression`, `at`): in their own signed-in session
  (`aqua_writer/1`), or through a turn of theirs, the soul's or a crew
  member's alike, under Aqua's grant (`writer/2`). A key's call, a
  tincture's and any other caller is refused `:aqua_line_by_person`, and
  the store holds the same rule under the row's lock
  (`Arca.CronSchedule.update/4`). Its name is a label, which the fire does
  not say: renaming, pausing, resuming and deleting one are a schedule's
  ordinary writes, as for any schedule. No other agent is a schedule's
  reference, and an Aqua line has no version to re-resolve.

  ## From a turn

  `create`, `update`, `pause`, `resume` and `delete` take the in-chain
  plane as well; `re_resolve` stays external. A chain's call is a turn's
  own or nothing: the open turn the gate's lineage names, in the caller's
  athanor, asked for by its person, whose root made the call. A call a
  page in Aqua's browser made through the turn (the gate's `page` mark,
  stamped from the step's purpose, `Aqua.Loop`) is the page's, not the
  turn's, and is refused `:schedule_by_page`; a component's call, one
  whose parent is not its root or that names no turn,
  `:schedule_by_component`; and one naming a turn no longer open
  `:schedule_turn_ended`.

  A turn's own call writes only when the turn is the person's: it runs
  under a sign-in with no key and no frame, and belongs to work the person
  began or a schedule of theirs began, which its row's origin records
  (`interactive` or `schedule`), or `:schedule_turn_not_yours`. That
  covers the soul's turn and a crew member's alike, by decision: a
  member's job turn and the soul's turn a member's reply opens carry the
  origin of the work they belong to (`Aqua.Crew` carries the asking turn's
  origin onto the job and its reply), so a reply inside the person's own
  work writes as the person's turn does, and one inside work a key or an
  app began (`programmatic`, `webhook`) writes nothing.
  A schedule a turn makes records the turn's agent as its `maker` and,
  when the turn works under a workspace thread, that thread as its
  `thread_id`, where its fires land (`Aqua.ScheduleTurns`); both come from
  the lineage and the turn's row, never the arguments.

  ## One time

  `at` in place of `cron_expression` sets a schedule for one time, at
  least a minute and at most a year ahead, rounded up to the minute: the
  row holds the cron expression naming that minute in UTC and `once`. It
  fires once, however late (`Arca.ScheduleOccurrences.claim/3`), and is
  removed when that occurrence's run ends, unless the schedule was given
  another time since (`Arca.CronSchedule.record_run/4`). An update naming
  neither keeps a once schedule's cursor and a `cron_expression` makes it
  recurring. A pause ends a fire claimed and not yet started and puts its
  time back (`Arca.CronSchedule.update/4`), and a resume fires a once
  schedule whose time has passed at once.

  The cap is the platform setting `max_schedules_per_athanor` (0 is no
  ceiling), read at each create and handed to `Arca.CronSchedule.create/2`,
  which counts the athanor's non-deleted schedules, a paused one included,
  and inserts in one transaction under the athanor's row lock.
  """

  # The one kind of row this tool reads and writes.
  @kind "schedule"

  # A schedule's line for Aqua, and the longest line a person may send.
  @aqua_line Arca.CronSchedule.aqua_line()
  @max_line_bytes 32 * 1024

  @behaviour Prima.Provider

  @impl true
  def service, do: "opus"

  alias Cyfr.Bus.ScheduleRun
  alias Opus.Schedules.Changes
  alias Prima.Canvas.Shape
  alias Sanctum.{Context, Refusals}

  # The newest occurrences a `schedule_runs.changes` subscriber is handed
  # first.
  @recent_runs 20

  # A day: the longest a grant on either stream lives.
  @deadline_bound 86_400

  # Fifteen minutes: how long a picture of either stream stands before it
  # is read again. Each change is announced, so a read only mends one the
  # bus lost.
  @stale_after 900

  require Logger

  @impl true
  def tools do
    alias Prima.{Arg, Operation}
    # create/update also require the registration's consent binding —
    # a conditional Authz check that stays in the handler.
    [
      Operation.tool(
        [
          Operation.new(
            "schedule",
            "create",
            "Create schedule",
            [
              Arg.new("name", :string,
                required: true,
                description:
                  "Human-readable schedule name, unique within the athanor (create/update)"
              ),
              Arg.new("cron_expression", :string,
                description:
                  "Cron expression, e.g. '*/5 * * * *' (create/update): a cron_expression or an at. Minimum 1-minute interval."
              ),
              Arg.new("at", :string,
                description:
                  "Instead of cron_expression, the one time it fires, ISO 8601 with its offset, e.g. '2026-11-26T09:00:00+01:00' (create/update): at least a minute and at most a year ahead, rounded up to the minute. It fires once, however late, and is then removed."
              ),
              Arg.new("reference", :string,
                required: true,
                description:
                  "Component reference string, or agent:local.aqua for a line for Aqua (create/update)"
              ),
              Arg.new("profile_id", :string,
                description:
                  "Profile the schedule fires under; its consent authorizes the binding (create, required for a component, refused for a line for Aqua; update). re_resolve re-authorizes the schedule's existing profile and ignores this argument."
              ),
              Arg.new("input", {:map, Arg.new(nil, :json)},
                description:
                  "Input data to pass to the component, or {\"line\": text} for a line for Aqua (reference agent:local.aqua) (create/update)"
              ),
              Arg.new("metadata", {:map, Arg.new(nil, :json)},
                description:
                  "Optional metadata (create/update). `keep_outcome: true` files every completed run's output as a note in the schedule's athanor, named by `note_name` or, when unset, by the schedule's id; each run replaces the note before it."
              ),
              Arg.new("concurrency", :string,
                description:
                  "Whether a due occurrence runs while another of this schedule is still open (default forbid)",
                enum: ["forbid", "allow"]
              ),
              Arg.new("missed_runs", :string,
                description:
                  "What becomes of due times the server missed (create/update): skip them (default), or catch_up on up to catch_up_limit of them, oldest first",
                enum: ["skip", "catch_up"]
              ),
              Arg.new("catch_up_limit", :integer,
                description:
                  "How many missed times one catch-up fires, 1 to #{Opus.Schedules.Scheduler.max_catch_up()} (create/update; required with catch_up, refused with skip)"
              )
            ],
            kind: :write,
            planes: [:external, :in_chain],
            permission: :execute
          ),
          Operation.new(
            "schedule",
            "list",
            "List schedule",
            [
              Arg.new("limit", :integer,
                description: "Maximum results to return (list), at most 1000",
                default: 25
              ),
              Arg.new("offset", :integer,
                description:
                  "How many of the newest schedules to pass over before the first one listed (list)",
                default: 0
              )
            ],
            kind: :read,
            planes: [:external, :in_chain],
            permission: :execute
          ),
          Operation.new(
            "schedule",
            "get",
            "Get schedule",
            [
              Arg.new("schedule_id", :string,
                required: true,
                description: "Schedule ID or name (get/update/pause/resume/delete)"
              )
            ],
            kind: :read,
            planes: [:external, :in_chain],
            permission: :execute
          ),
          Operation.new(
            "schedule",
            "update",
            "Update schedule",
            [
              Arg.new("schedule_id", :string,
                required: true,
                description: "Schedule ID or name (get/update/pause/resume/delete)"
              ),
              Arg.new("name", :string,
                description:
                  "Human-readable schedule name, unique within the athanor (create/update)"
              ),
              Arg.new("cron_expression", :string,
                description:
                  "Cron expression, e.g. '*/5 * * * *' (create/update): a cron_expression or an at. Minimum 1-minute interval."
              ),
              Arg.new("at", :string,
                description:
                  "Instead of cron_expression, the one time it fires, ISO 8601 with its offset, e.g. '2026-11-26T09:00:00+01:00' (create/update): at least a minute and at most a year ahead, rounded up to the minute. It fires once, however late, and is then removed."
              ),
              Arg.new("reference", :string,
                description: "Component reference to run under the schedule profile"
              ),
              Arg.new("profile_id", :string,
                description:
                  "Profile the schedule fires under; its consent authorizes the binding (create, required; update). re_resolve re-authorizes the schedule's existing profile and ignores this argument."
              ),
              Arg.new("input", {:map, Arg.new(nil, :json)},
                nullable: true,
                description:
                  "Input data to pass to the component, or {\"line\": text} for a line for Aqua (reference agent:local.aqua) (create/update)"
              ),
              Arg.new("metadata", {:map, Arg.new(nil, :json)},
                nullable: true,
                description:
                  "Optional metadata (create/update). `keep_outcome: true` files every completed run's output as a note in the schedule's athanor, named by `note_name` or, when unset, by the schedule's id; each run replaces the note before it."
              ),
              Arg.new("concurrency", :string,
                description:
                  "Whether a due occurrence runs while another of this schedule is still open (default forbid)",
                enum: ["forbid", "allow"]
              ),
              Arg.new("missed_runs", :string,
                description:
                  "What becomes of due times the server missed (create/update): skip them (default), or catch_up on up to catch_up_limit of them, oldest first",
                enum: ["skip", "catch_up"]
              ),
              Arg.new("catch_up_limit", :integer,
                description:
                  "How many missed times one catch-up fires, 1 to #{Opus.Schedules.Scheduler.max_catch_up()} (create/update; required with catch_up, refused with skip)"
              ),
              Arg.new("definition", :string,
                description:
                  "The schedule's definition as read (get/list answer it): the update is refused as changed when its name, time, reference, profile, input or missed-run policy moved since; a fire or a pause does not move it"
              )
            ],
            kind: :write,
            planes: [:external, :in_chain],
            permission: :execute
          ),
          Operation.new(
            "schedule",
            "pause",
            "Pause schedule",
            [
              Arg.new("schedule_id", :string,
                required: true,
                description: "Schedule ID or name (get/update/pause/resume/delete)"
              )
            ],
            kind: :write,
            planes: [:external, :in_chain],
            permission: :execute
          ),
          Operation.new(
            "schedule",
            "resume",
            "Resume schedule",
            [
              Arg.new("schedule_id", :string,
                required: true,
                description: "Schedule ID or name (get/update/pause/resume/delete)"
              )
            ],
            kind: :write,
            planes: [:external, :in_chain],
            permission: :execute
          ),
          Operation.new(
            "schedule",
            "delete",
            "Delete schedule",
            [
              Arg.new("schedule_id", :string,
                required: true,
                description: "Schedule ID or name (get/update/pause/resume/delete)"
              )
            ],
            kind: :destructive,
            planes: [:external, :in_chain],
            permission: :execute
          ),
          Operation.new(
            "schedule",
            "re_resolve",
            "Re resolve schedule",
            [
              Arg.new("schedule_id", :string,
                required: true,
                description: "Schedule ID or name (get/update/pause/resume/delete)"
              )
            ],
            kind: :write,
            planes: [:external],
            permission: :execute
          )
        ],
        description:
          "Manage the athanor's schedules: a component run, or a line for Aqua, at a cron time or once",
        title: "Cron Schedule"
      )
    ]
  end

  # Create
  @impl true
  def handle(
        "schedule",
        %Context{} = ctx,
        %{"action" => "create", "reference" => @aqua_line} = args
      ) do
    with {:ok, writer} <- writer(ctx, args),
         :ok <- person(writer),
         :ok <- validate_required(args, ["name"]),
         {:ok, timing} <- timing(args, nil),
         :ok <- no_profile(args),
         {:ok, missed} <- missed_runs(args, %{missed_runs: "skip", catch_up_limit: nil}),
         {:ok, input_json} <- aqua_input(args),
         :ok <- fire_fits(%{reference: @aqua_line, maker: writer.maker, input: input_json}) do
      attrs = %{
        user_id: ctx.user_id,
        maker: writer.maker,
        thread_id: writer.room,
        name: args["name"],
        reference: @aqua_line,
        resolved_reference: @aqua_line,
        input: input_json,
        metadata: if(args["metadata"], do: safe_encode(args["metadata"])),
        profile_id: nil,
        concurrency: args["concurrency"] || "forbid"
      }

      insert(ctx, writer, attrs |> Map.merge(timing) |> Map.merge(missed))
    end
  end

  def handle("schedule", %Context{} = ctx, %{"action" => "create"} = args) do
    with {:ok, writer} <- writer(ctx, args),
         :ok <- validate_required(args, ["name", "reference"]),
         :ok <- no_other_agent(args["reference"]),
         :ok <- profile_given(args),
         {:ok, timing} <- timing(args, nil),
         {:ok, missed} <- missed_runs(args, %{missed_runs: "skip", catch_up_limit: nil}),
         {:ok, reference, resolved_reference} <-
           resolve_for_schedule(ctx, args["reference"], "create schedule"),
         :ok <- verify_component_exists(ctx, resolved_reference),
         :ok <- authorize_profile_binding(ctx, resolved_reference, args["profile_id"]) do
      input_json = if args["input"], do: safe_encode(args["input"]), else: nil
      metadata_json = if args["metadata"], do: safe_encode(args["metadata"]), else: nil

      attrs = %{
        user_id: ctx.user_id,
        maker: writer.maker,
        thread_id: writer.room,
        name: args["name"],
        reference: reference,
        resolved_reference: resolved_reference,
        input: input_json,
        metadata: metadata_json,
        profile_id: args["profile_id"],
        concurrency: args["concurrency"] || "forbid"
      }

      insert(ctx, writer, attrs |> Map.merge(timing) |> Map.merge(missed))
    end
  end

  # List
  def handle("schedule", %Context{} = ctx, %{"action" => "list"} = args) do
    limit = min(args["limit"] || 25, 1000)
    offset = max(args["offset"] || 0, 0)

    case Arca.CronSchedule.list(Sanctum.Context.actor(ctx),
           limit: limit,
           offset: offset,
           kind: @kind
         ) do
      {:ok, schedules} ->
        {:ok,
         %{
           schedules: Enum.map(schedules, &format_schedule/1),
           count: length(schedules)
         }}

      {:error, reason} ->
        {:error, format_store_error(reason)}
    end
  end

  # Get
  def handle("schedule", %Context{} = ctx, %{"action" => "get", "schedule_id" => id}) do
    case schedule(ctx, id) do
      {:ok, schedule} -> {:ok, format_schedule(schedule)}
      {:error, reason} -> {:error, format_store_error(reason, id)}
    end
  end

  # Update
  def handle("schedule", %Context{} = ctx, %{"action" => "update", "schedule_id" => id} = args) do
    # A definition given is compared first, so a caller who read an
    # older schedule hears that, never a refusal about what the schedule
    # has become; the store's comparison under the row's lock decides.
    with {:ok, writer} <- writer(ctx, args),
         {:schedule, {:ok, schedule}} <- {:schedule, schedule(ctx, id)},
         :ok <- Arca.CronSchedule.as_read(schedule, args["definition"]),
         {:ok, timing} <- timing(args, schedule),
         {:ok, missed} <- missed_runs(args, schedule),
         {:ok, line} <- aqua_update(writer, schedule, args) do
      update_attrs = Map.merge(missed, timing)

      update_attrs =
        if args["concurrency"],
          do: Map.put(update_attrs, :concurrency, args["concurrency"]),
          else: update_attrs

      update_attrs =
        if args["name"], do: Map.put(update_attrs, :name, args["name"]), else: update_attrs

      with {:ok, update_attrs} <- target_update(ctx, schedule, args, update_attrs, line) do
        update_attrs =
          if Map.has_key?(args, "metadata"),
            do:
              Map.put(
                update_attrs,
                :metadata,
                if(args["metadata"], do: safe_encode(args["metadata"]))
              ),
            else: update_attrs

        case Arca.CronSchedule.update(Sanctum.Context.actor(ctx), schedule.id, update_attrs,
               by_person: writer.person?,
               definition: args["definition"],
               fits: &fire_fits/1
             ) do
          {:ok, updated} ->
            Opus.Schedules.Scheduler.update(updated.id)
            Changes.changed(Sanctum.Context.actor(ctx), updated.id)
            {:ok, format_schedule(updated)}

          {:error, reason} ->
            store_refusal(reason, id)
        end
      end
    else
      {:schedule, {:error, reason}} -> {:error, format_store_error(reason, id)}
      {:error, _} = err -> err
    end
  end

  # Pause
  def handle("schedule", %Context{} = ctx, %{"action" => "pause", "schedule_id" => id} = args) do
    with {:ok, _writer} <- writer(ctx, args) do
      case schedule(ctx, id) do
        {:error, reason} ->
          {:error, format_store_error(reason, id)}

        {:ok, schedule} ->
          case Arca.CronSchedule.update(Sanctum.Context.actor(ctx), schedule.id, %{
                 status: "paused"
               }) do
            {:ok, updated} ->
              Opus.Schedules.Scheduler.pause(updated.id)
              Changes.changed(Sanctum.Context.actor(ctx), updated.id)
              {:ok, format_schedule(updated)}

            {:error, reason} ->
              store_refusal(reason, id)
          end
      end
    end
  end

  # Resume
  def handle("schedule", %Context{} = ctx, %{"action" => "resume", "schedule_id" => id} = args) do
    with {:ok, _writer} <- writer(ctx, args) do
      case schedule(ctx, id) do
        {:error, reason} ->
          {:error, format_store_error(reason, id)}

        {:ok, schedule} ->
          # No cap check here: the cap counts every non-deleted schedule, so a
          # paused schedule still occupies its slot and resume never mints one.
          case Arca.CronSchedule.update(
                 Sanctum.Context.actor(ctx),
                 schedule.id,
                 Map.put(resumed_cursor(schedule), :status, "active")
               ) do
            {:ok, updated} ->
              Opus.Schedules.Scheduler.resume(updated.id)
              Changes.changed(Sanctum.Context.actor(ctx), updated.id)
              {:ok, format_schedule(updated)}

            {:error, reason} ->
              store_refusal(reason, id)
          end
      end
    end
  end

  # Delete
  def handle("schedule", %Context{} = ctx, %{"action" => "delete", "schedule_id" => id} = args) do
    with {:ok, _writer} <- writer(ctx, args) do
      case schedule(ctx, id) do
        {:error, reason} ->
          {:error, format_store_error(reason, id)}

        {:ok, schedule} ->
          case Arca.CronSchedule.soft_delete(Sanctum.Context.actor(ctx), schedule.id) do
            {:ok, deleted} ->
              Opus.Schedules.Scheduler.remove(schedule.id)
              Changes.removed(Sanctum.Context.actor(ctx), deleted)
              {:ok, %{deleted: true, schedule_id: schedule.id, name: schedule.name}}

            {:error, reason} ->
              store_refusal(reason, id)
          end
      end
    end
  end

  # Re-resolve — bump resolved_reference to latest version without recreating the schedule
  def handle("schedule", %Context{} = ctx, %{"action" => "re_resolve", "schedule_id" => id}) do
    case schedule(ctx, id) do
      {:error, reason} ->
        {:error, format_store_error(reason, id)}

      {:ok, %{reference: @aqua_line}} ->
        {:error, {:invalid_argument, "A line for Aqua has no version to re-resolve"}}

      {:ok, schedule} ->
        case Compendium.resolve(ctx, schedule.reference) do
          {:ok, pinned, _metadata} ->
            re_resolve_to(ctx, schedule, pinned, id)

          {:error, reason} ->
            {:error, "Failed to re-resolve '#{schedule.reference}': #{Refusals.render(reason)}"}
        end
    end
  end

  @doc """
  The streams a canvas reads: `schedules.changes` and
  `schedule_runs.changes`, each with its shape and refresh (the
  moduledoc's).
  """
  @impl true
  def streams do
    [
      %Prima.Provider.Stream{
        name: "schedules.changes",
        topic: :schedules,
        projection: [
          "kind",
          "schedule_id",
          "name",
          "reference",
          "cron_expression",
          "status",
          "next_run_at",
          "last_run_at",
          "run_count",
          "error_count" | Prima.Provider.Stream.delivery_fields()
        ],
        deadline_bound: @deadline_bound,
        shape: Prima.Provider.Stream.delivered(schedules_shape()),
        refresh: {__MODULE__, :live_schedules},
        key: "schedule_id",
        removal: "removed",
        stale_after: @stale_after
      },
      %Prima.Provider.Stream{
        name: "schedule_runs.changes",
        topic: :schedule_runs,
        projection: [
          "kind",
          "schedule_id",
          "occurrence_id",
          "execution_id",
          "scheduled_for",
          "reason" | Prima.Provider.Stream.delivery_fields()
        ],
        deadline_bound: @deadline_bound,
        shape: Prima.Provider.Stream.delivered(schedule_runs_shape()),
        refresh: {__MODULE__, :recent_runs},
        key: "occurrence_id",
        stale_after: @stale_after
      }
    ]
  end

  @doc """
  The refresh of `schedules.changes`: every live schedule of the caller's
  athanor, paused ones included, newest first, each as `changed`. The
  schedules' cap bounds how many there are, so no other bound applies.
  The subject is none.
  """
  @spec live_schedules(Context.t(), nil) :: {:ok, [Cyfr.Bus.Schedules.t()]} | {:error, term()}
  def live_schedules(%Context{athanor_id: athanor_id} = ctx, _subject)
      when is_binary(athanor_id) and athanor_id != "" do
    actor = Sanctum.Context.actor(ctx)

    with {:ok, rows} <- Arca.CronSchedule.list(actor, kind: @kind, limit: :infinity) do
      {:ok, Enum.map(rows, &Changes.payload(actor, :changed, &1))}
    end
  end

  def live_schedules(%Context{}, _subject), do: {:error, :no_athanor}

  @doc """
  The refresh of `schedule_runs.changes`: the caller's athanor's
  #{@recent_runs} newest occurrences of schedules
  (`Arca.ScheduleOccurrences.recent/2`), oldest first. A `failed` or
  `uncertain` occurrence reads as `failed` and any other as `fired`. An
  occurrence keeps no reason, so its `reason` is nil. The subject is
  none.
  """
  @spec recent_runs(Context.t(), nil) :: {:ok, [ScheduleRun.t()]} | {:error, term()}
  def recent_runs(%Context{} = ctx, _subject) do
    actor = Sanctum.Context.actor(ctx)

    with {:ok, occurrences} <- Arca.ScheduleOccurrences.recent(actor, limit: @recent_runs) do
      {:ok, occurrences |> Enum.reverse() |> Enum.map(&run_change(actor, &1))}
    end
  end

  defp run_change(actor, occurrence) do
    ScheduleRun.new(actor, run_kind(occurrence.state),
      schedule_id: occurrence.schedule_id,
      occurrence_id: occurrence.id,
      execution_id: occurrence.execution_id,
      scheduled_for: occurrence.scheduled_for,
      reason: nil
    )
  end

  defp run_kind(state) when state in ["failed", "uncertain"], do: :failed
  defp run_kind(_state), do: :fired

  defp schedules_shape do
    normalized(%{
      "type" => "object",
      "fields" => %{
        "kind" => %{"type" => "enum", "values" => ["changed", "removed"]},
        "schedule_id" => %{"type" => "string"},
        "name" => %{"type" => "string"},
        "reference" => %{"type" => "string"},
        "cron_expression" => %{"type" => "string"},
        "status" => %{"type" => "enum", "values" => Arca.CronSchedule.statuses() -- ["deleted"]},
        "next_run_at" => %{"type" => "time", "nullable" => true},
        "last_run_at" => %{"type" => "time", "nullable" => true},
        "run_count" => %{"type" => "integer"},
        "error_count" => %{"type" => "integer"}
      },
      "required" => [
        "kind",
        "schedule_id",
        "name",
        "reference",
        "cron_expression",
        "status",
        "next_run_at",
        "last_run_at",
        "run_count",
        "error_count"
      ]
    })
  end

  defp schedule_runs_shape do
    normalized(%{
      "type" => "object",
      "fields" => %{
        "kind" => %{"type" => "enum", "values" => ["fired", "failed"]},
        "schedule_id" => %{"type" => "string"},
        "occurrence_id" => %{"type" => "string", "nullable" => true},
        "execution_id" => %{"type" => "string", "nullable" => true},
        "scheduled_for" => %{"type" => "time", "nullable" => true},
        "reason" => %{
          "type" => "object",
          "nullable" => true,
          "fields" => %{
            "class" => %{
              "type" => "enum",
              "values" => Enum.map(Prima.Refusal.classes(), &Atom.to_string/1)
            },
            "cause" => cause_shape(ScheduleRun.causes())
          },
          "required" => ["class", "cause"]
        }
      },
      "required" => [
        "kind",
        "schedule_id",
        "occurrence_id",
        "execution_id",
        "scheduled_for",
        "reason"
      ]
    })
  end

  # A cause's enum lists every cause with its readable sentence, so the
  # catalog a canvas reads names what each one says.
  defp cause_shape(causes) do
    %{
      "type" => "enum",
      "values" => Enum.map(causes, fn {cause, _sentence} -> Atom.to_string(cause) end),
      "labels" => Map.new(causes, fn {cause, sentence} -> {Atom.to_string(cause), sentence} end)
    }
  end

  # Declared in the normalized form the stream table keeps
  # (`Prima.Provider.Stream.valid?/1`).
  defp normalized(shape) do
    {:ok, normalized} = Shape.validate(shape)
    normalized
  end

  # Helpers

  # A schedule by id or name: a feed's id or name, or one a feed shares
  # with no schedule, is not found here.
  defp schedule(ctx, id_or_name),
    do: Arca.CronSchedule.get_by_id_or_name(Sanctum.Context.actor(ctx), id_or_name, kind: @kind)

  defp validate_required(args, keys) do
    missing = Enum.filter(keys, fn k -> !args[k] || args[k] == "" end)

    case missing do
      [] ->
        :ok

      keys ->
        {:error, {:invalid_argument, "Missing required arguments: #{Enum.join(keys, ", ")}"}}
    end
  end

  defp validate_cron(expr) do
    case Opus.Schedules.Cron.parse(expr) do
      {:ok, _} ->
        case Opus.Schedules.Cron.min_interval_seconds(expr) do
          {:ok, interval} when interval < 60 ->
            {:error,
             {:invalid_argument,
              "Minimum interval is 1 minute. Expression '#{expr}' runs every #{interval}s."}}

          {:ok, _} ->
            :ok

          {:error, reason} ->
            {:error, {:invalid_argument, "Invalid cron expression: #{reason}"}}
        end

      {:error, reason} ->
        {:error, {:invalid_argument, "Invalid cron expression: #{reason}"}}
    end
  end

  # The policy the write leaves the schedule with, as the two columns:
  # what the arguments name, over what `current` holds. A `catch_up` names
  # a limit of 1 to the scheduler's ceiling, and NULL or 0 is refused; a
  # `skip` names none, and switching to it drops the stored limit. The
  # policy is one the declaration's enum admits or the row's CHECK holds.
  defp missed_runs(args, current) do
    policy = Map.get(args, "missed_runs") || current.missed_runs

    limit =
      cond do
        Map.has_key?(args, "catch_up_limit") -> args["catch_up_limit"]
        policy == current.missed_runs -> current.catch_up_limit
        true -> nil
      end

    max = Opus.Schedules.Scheduler.max_catch_up()

    case {policy, limit} do
      {"skip", nil} ->
        {:ok, %{missed_runs: "skip", catch_up_limit: nil}}

      {"skip", _limit} ->
        {:error, {:invalid_argument, "catch_up_limit applies only to missed_runs catch_up"}}

      {"catch_up", limit} when is_integer(limit) and limit >= 1 and limit <= max ->
        {:ok, %{missed_runs: "catch_up", catch_up_limit: limit}}

      {"catch_up", _limit} ->
        {:error,
         {:invalid_argument, "missed_runs catch_up needs a catch_up_limit of 1 to #{max}"}}
    end
  end

  # The cap is read at the write and counted in the insert's own
  # transaction. A cap the store cannot answer refuses: the setting refuses
  # a stale value, and no fallback number stands in for it.
  defp insert(ctx, writer, attrs) do
    with {:ok, cap} <- schedule_cap() do
      case Arca.CronSchedule.create(
             Sanctum.Context.actor(ctx),
             Map.merge(attrs, %{cap: cap, by_person: writer.person?})
           ) do
        {:ok, schedule} ->
          Opus.Schedules.Scheduler.add(schedule.id)
          Changes.changed(Sanctum.Context.actor(ctx), schedule.id)
          {:ok, format_schedule(schedule)}

        {:error, :schedule_cap} ->
          {:error, "Schedule limit reached (#{cap} per athanor)"}

        {:error, :conflict} ->
          {:error, {:conflict, "a live schedule is named #{attrs.name}"}}

        {:error, reason} ->
          store_refusal(reason, nil)
      end
    end
  end

  defp schedule_cap do
    case Arca.PlatformSettings.effective("max_schedules_per_athanor") do
      {:ok, cap} when is_integer(cap) and cap >= 0 -> {:ok, cap}
      {:error, :unavailable} -> {:error, format_store_error(:database_error)}
    end
  end

  defp compute_next_run(cron_expression) do
    case Opus.Schedules.Cron.parse(cron_expression) do
      {:ok, parsed} -> Opus.Schedules.Cron.next_run(parsed, DateTime.utc_now())
      error -> error
    end
  end

  defp format_schedule(schedule) do
    %{
      schedule_id: schedule.id,
      name: schedule.name,
      cron_expression: schedule.cron_expression,
      once: schedule.once,
      maker: schedule.maker,
      thread_id: schedule.thread_id,
      reference: schedule.reference,
      resolved_reference: schedule.resolved_reference,
      profile_id: schedule.profile_id,
      definition: Arca.CronSchedule.definition(schedule),
      input: decode_stored(schedule.input, nil, "input"),
      metadata: decode_stored(schedule.metadata, nil, "metadata"),
      status: schedule.status,
      concurrency: schedule.concurrency,
      missed_runs: schedule.missed_runs,
      catch_up_limit: schedule.catch_up_limit,
      next_run_at: schedule.next_run_at && DateTime.to_iso8601(schedule.next_run_at),
      last_run_at: schedule.last_run_at && DateTime.to_iso8601(schedule.last_run_at),
      last_execution_id: schedule.last_execution_id,
      run_count: schedule.run_count,
      error_count: schedule.error_count,
      last_error: schedule.last_error,
      created_at: DateTime.to_iso8601(schedule.created_at),
      updated_at: DateTime.to_iso8601(schedule.updated_at)
    }
  end

  # Display plane: a corrupt stored column renders as null (logged); the
  # scheduler's EXECUTION read of the same columns stays fail-closed
  # (`Opus.Schedules.Scheduler` skips the run).
  # The line names the column and its size, never its bytes.
  defp decode_stored(json, default, field) do
    case Prima.Json.decode_stored(json, default) do
      {:ok, value} ->
        value

      {:error, :invalid_json} ->
        Logger.warning(
          "[Opus.Schedules.Provider] stored #{field} is not valid JSON (#{byte_size(json)} bytes)"
        )

        default
    end
  end

  # The storage layer answers typed reasons; this seam names them in the
  # refusal vocabulary (`Prima.Refusal`). A write's refusal: a member that
  # lost its slot is answered as itself, as a feed's write is. A create's
  # `:not_found` is its athanor's missing row, which names no schedule.
  defp store_refusal(reason, _id)
       when reason in [:not_owner, :no_athanor, :aqua_line_by_person, :schedule_changed],
       do: {:error, reason}

  # The store's own refusal of what a fire would say (`fire_fits/1`, asked
  # under the row's lock) is answered as the tool's.
  defp store_refusal({:invalid_argument, _said} = refused, _id), do: {:error, refused}

  defp store_refusal(reason, id), do: {:error, format_store_error(reason, id)}

  defp format_store_error(reason, id \\ nil)
  defp format_store_error(:not_found, nil), do: :not_found
  defp format_store_error(:not_found, id), do: {:not_found, "Schedule", id}
  defp format_store_error(:database_error, _), do: {:unavailable, "Storage"}

  defp format_store_error({:validation, errors}, _) when is_map(errors) do
    {:invalid_argument,
     Enum.map_join(errors, "; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)}
  end

  defp resolve_for_schedule(ctx, reference, label) do
    case Compendium.resolve(ctx, reference) do
      {:ok, pinned, %{was_resolved: true}} ->
        {:ok, reference, pinned}

      {:ok, pinned, _metadata} ->
        {:ok, pinned, pinned}

      {:error, reason} ->
        {:error, "Cannot #{label}: failed to resolve '#{reference}'. #{Refusals.render(reason)}"}
    end
  end

  # Apply component existence and profile-consent checks when rebinding
  # a schedule to a resolved version. Their refusals answer as themselves;
  # only the store's write is rendered as a storage error.
  defp re_resolve_to(ctx, schedule, pinned, id) do
    with :ok <- verify_component_exists(ctx, pinned),
         :ok <- authorize_profile_binding(ctx, pinned, schedule.profile_id) do
      case Arca.CronSchedule.update(
             Sanctum.Context.actor(ctx),
             schedule.id,
             %{resolved_reference: pinned},
             by_person: by_person?(ctx)
           ) do
        {:ok, updated} ->
          Opus.Schedules.Scheduler.update(updated.id)
          Changes.changed(Sanctum.Context.actor(ctx), updated.id)
          {:ok, format_schedule(updated)}

        {:error, reason} ->
          store_refusal(reason, id)
      end
    end
  end

  # A component the registry does not hold is a sentence to act on; any
  # other refusal of its inspection (its stored manifest damaged, the
  # store unavailable) answers as itself, never as a missing component.
  defp verify_component_exists(ctx, resolved_reference) do
    case Compendium.inspect_component(ctx, resolved_reference) do
      {:ok, _} ->
        :ok

      {:error, {:not_found, _}} ->
        {:error,
         "Component '#{resolved_reference}' not found in registry. Register or pull it first."}

      {:error, _} = refused ->
        refused
    end
  end

  # ---- a line for Aqua ---------------------------------------------------------

  # Who calls a write, decided once for all five writes: `person?`,
  # whether the caller is the schedule's person, which only that person's
  # writes to what an Aqua line's fire reads need; `maker`, the agent
  # whose turn calls; and `room`, the workspace thread that turn works
  # under, none for a daily thread. A call outside any chain is the
  # session's, a person's or a key's, and names no maker. A call in a
  # chain is a turn's own, and that turn is the person's, or the write is
  # refused whatever it writes: a page's call through the turn
  # `:schedule_by_page`, a component's call `:schedule_by_component`, a
  # turn under a key or a frame, or in work neither the person nor a
  # schedule began, `:schedule_turn_not_yours` (the moduledoc's "From a
  # turn" says why a crew member's turn and a member's reply are the
  # person's when that work is).
  defp writer(%Context{plane: :guest}, %{"page" => true}), do: {:error, :schedule_by_page}

  defp writer(%Context{plane: :guest} = ctx, args) do
    with {:ok, turn, room} <- own_turn(ctx, args) do
      if turn_writer?(ctx, turn),
        do: {:ok, %{person?: true, maker: turn.agent, room: room}},
        else: {:error, :schedule_turn_not_yours}
    end
  end

  defp writer(%Context{} = ctx, _args),
    do: {:ok, %{person?: aqua_writer(ctx) == :ok, maker: nil, room: nil}}

  defp person(%{person?: true}), do: :ok
  defp person(_writer), do: {:error, :aqua_line_by_person}

  # The person's own signed-in session: a browser's or a paired device's,
  # never an API key or a tincture's frame credential, and never under an
  # origin that is no person's own act.
  defp aqua_writer(%Context{auth_method: method, api_key_id: nil, frame: nil, origin: origin})
       when method in [:oidc, :device] and origin in [nil, :interactive],
       do: :ok

  defp aqua_writer(_ctx), do: {:error, :aqua_line_by_person}

  # A turn of the person's: a sign-in's chain with no key and no frame,
  # in work the person or a schedule's fire began (whose turn, and the
  # member it hands the job to, set the next wake), as its row's origin
  # records it. A crew member's job turn and the soul's turn its reply
  # opens carry the origin of the work they belong to (`Aqua.Crew`).
  defp turn_writer?(
         %Context{authenticated: true, auth_method: :oidc, api_key_id: nil, frame: nil},
         turn
       ),
       do: turn.origin in ["interactive", "schedule"]

  defp turn_writer?(_ctx, _turn), do: false

  # The open turn a chain's call is the own call of, from the lineage the
  # gate stamps (`Sanctum.Dispatch` drops what a guest sends under those
  # names): a turn of that thread, in the context's athanor, asked for by
  # its person, whose root made the call itself. Opus reads the rows, as
  # `Opus.Programs` does, since it does not call Aqua. Anything else is
  # no turn's call.
  defp own_turn(%Context{athanor_id: athanor_id, user_id: user_id} = ctx, %{
         "thread_id" => thread_id,
         "root_execution_id" => root,
         "parent_execution_id" => root
       })
       when is_binary(thread_id) and is_binary(root) and is_binary(athanor_id) and
              athanor_id != "" and is_binary(user_id) and user_id != "" do
    actor = Sanctum.Context.actor(ctx)

    with {:ok, turns} <- Arca.TurnStorage.open_turns(actor, thread_id),
         %{} = turn <-
           Enum.find(turns, &(&1.root_execution_id == root and &1.requested_by == user_id)),
         {:ok, thread} <- Arca.ThreadStorage.get(actor, thread_id),
         {:ok, room} <- room(actor, thread) do
      {:ok, turn, room}
    else
      nil -> {:error, :schedule_turn_ended}
      {:error, :not_found} -> {:error, :schedule_turn_ended}
      {:error, _unread} -> {:error, format_store_error(:database_error)}
    end
  end

  # A chain's call that is not a turn's own: a component's, whether a
  # turn started it or a key's run did.
  defp own_turn(_ctx, _args), do: {:error, :schedule_by_component}

  # The room a turn works in: a workspace thread is its own, a member's
  # thread works under its parent, and a daily thread is none, which a
  # fire reads as the daily thread current when it fires.
  defp room(_actor, %{kind: "workspace", id: id}), do: {:ok, id}

  defp room(actor, %{kind: "crew", parent_id: parent_id}) when is_binary(parent_id) do
    with {:ok, parent} <- Arca.ThreadStorage.get(actor, parent_id), do: room(actor, parent)
  end

  defp room(_actor, _daily), do: {:ok, nil}

  # What the store is told of a write that names no turn's call: whether
  # it is the person's own signed-in session, decided from the context
  # alone. The store decides against the row it locks whether that is
  # needed (`Arca.CronSchedule.update/4`).
  defp by_person?(ctx), do: aqua_writer(ctx) == :ok

  # When a write leaves the schedule firing: a cron expression, or `at`,
  # one time, as the cron expression naming that minute in UTC with
  # `once`. An update naming neither keeps a once schedule's cursor, and
  # moves a recurring one's to its expression's next time, as before.
  defp timing(%{"cron_expression" => cron, "at" => at}, _current)
       when is_binary(cron) and is_binary(at),
       do: {:error, {:invalid_argument, "A schedule names a cron_expression or an at, not both"}}

  defp timing(%{"at" => at}, _current) when is_binary(at), do: once_at(at)

  defp timing(%{"cron_expression" => cron}, _current) when is_binary(cron) do
    with :ok <- validate_cron(cron),
         do: {:ok, %{cron_expression: cron, once: false, next_run_at: next_run(cron)}}
  end

  defp timing(_args, nil),
    do: {:error, {:invalid_argument, "Missing required arguments: cron_expression or at"}}

  defp timing(_args, %{once: true}), do: {:ok, %{}}

  defp timing(_args, current), do: {:ok, %{next_run_at: next_run(current.cron_expression)}}

  # One time: at least a minute ahead as any fire is, rounded up to the
  # minute, and at most a year ahead by the date itself, so the cron
  # expression naming that minute, which names no year, next matches it.
  defp once_at(at) do
    with {:ok, asked} <- parse_at(at) do
      now = DateTime.utc_now()
      time = round_up_to_minute(asked)

      cond do
        DateTime.diff(asked, now, :second) < 60 ->
          {:error, {:invalid_argument, "at must be at least a minute ahead"}}

        DateTime.compare(time, DateTime.shift(now, year: 1)) == :gt ->
          {:error,
           {:invalid_argument,
            "at must be at most a year ahead: a schedule names no year, so a later wake is a recurring schedule"}}

        true ->
          cron = "#{time.minute} #{time.hour} #{time.day} #{time.month} *"
          {:ok, %{cron_expression: cron, once: true, next_run_at: time}}
      end
    end
  end

  defp parse_at(at) do
    case DateTime.from_iso8601(at) do
      {:ok, time, _offset} ->
        {:ok, DateTime.shift_zone!(time, "Etc/UTC")}

      {:error, _} ->
        {:error,
         {:invalid_argument, "at is an ISO 8601 time with its offset, e.g. 2026-11-26T09:00:00Z"}}
    end
  end

  defp round_up_to_minute(time) do
    floor = %{time | second: 0, microsecond: {0, 6}}
    if DateTime.compare(floor, time) == :lt, do: DateTime.add(floor, 60, :second), else: floor
  end

  # Where a resumed schedule's cursor goes: a recurring one's to its next
  # time; a once one's stays where it was while that is ahead, and one
  # whose time passed while it was paused, or whose fire the pause ended
  # (`Arca.CronSchedule.update/4` put that fire's time back), is due now,
  # a time no occurrence of it holds. A once one with no cursor fired
  # already, and its run's end removes it.
  defp resumed_cursor(%{once: true, next_run_at: %DateTime{} = at}) do
    now = DateTime.utc_now()
    if DateTime.compare(at, now) == :gt, do: %{}, else: %{next_run_at: now}
  end

  defp resumed_cursor(%{once: true}), do: %{}
  defp resumed_cursor(schedule), do: %{next_run_at: next_run(schedule.cron_expression)}

  @doc """
  What a fire of a schedule's line for Aqua says (`Opus.schedule_fire_text/2`):
  the line, opened with "`maker` set this schedule:" when a turn's agent
  made it. The schedule's name is a label and no part of it. Every write
  bounds this whole text at the longest message a fire may send
  (`fire_fits/1`), so a saved line always fits its fire.
  """
  @spec fire_text(String.t() | nil, String.t()) :: String.t()
  def fire_text(maker, line) when is_binary(maker) and is_binary(line),
    do: "#{maker} set this schedule:\n\n#{line}"

  def fire_text(nil, line) when is_binary(line), do: line

  # A row's fire, with who set it, is no longer than a message a fire may
  # send; a component's row fires no line. The store asks it of the row as
  # an update leaves it, under the row's lock (`Arca.CronSchedule.update/4`),
  # and a create of the row it makes.
  defp fire_fits(%{reference: @aqua_line} = row) do
    line =
      case Jason.decode(row.input || "") do
        {:ok, %{"line" => line}} when is_binary(line) -> line
        _unread -> ""
      end

    if byte_size(fire_text(row.maker, line)) > @max_line_bytes,
      do:
        {:error,
         {:invalid_argument,
          "The line is too long: with who set it, a fire's message holds at most 32 KiB"}},
      else: :ok
  end

  defp fire_fits(_component), do: :ok

  # The line is the input's one field: a non-empty text a person could send.
  defp aqua_input(%{"input" => %{"line" => line} = input})
       when is_binary(line) and map_size(input) == 1 do
    line = String.trim(line)

    cond do
      line == "" -> {:error, {:invalid_argument, "A line for Aqua must say something"}}
      byte_size(line) > @max_line_bytes -> {:error, {:invalid_argument, "The line is too long"}}
      true -> {:ok, safe_encode(%{"line" => line})}
    end
  end

  defp aqua_input(_args),
    do: {:error, {:invalid_argument, "A line for Aqua is the input {\"line\": text}"}}

  defp no_profile(args) do
    if args["profile_id"] in [nil, ""],
      do: :ok,
      else: {:error, {:invalid_argument, "A line for Aqua binds no profile"}}
  end

  # A component's schedule binds the profile it fires under.
  defp profile_given(%{"profile_id" => profile_id})
       when is_binary(profile_id) and profile_id != "",
       do: :ok

  defp profile_given(_args),
    do: {:error, {:invalid_argument, "Missing required field: profile_id"}}

  # Aqua is the one agent a schedule holds a line for.
  defp no_other_agent(reference) do
    if Prima.AgentRef.agent_ref?(reference),
      do: {:error, {:invalid_argument, "A schedule holds a line only for Aqua (#{@aqua_line})"}},
      else: :ok
  end

  # What an update does to the schedule's target: a component's as before
  # (`:component`), or an Aqua line's, which only the person changes. An
  # update that touches what an Aqua line's fire reads (its reference,
  # input or time), or makes a schedule one, is the person's; one that
  # leaves it names the profile the component binds.
  defp aqua_update(writer, schedule, args) do
    aqua? = schedule.reference == @aqua_line
    to_aqua? = args["reference"] == @aqua_line
    leaving? = aqua? and Map.has_key?(args, "reference") and not to_aqua?

    touches? =
      Map.has_key?(args, "reference") or Map.has_key?(args, "input") or
        is_binary(args["cron_expression"]) or is_binary(args["at"])

    cond do
      not aqua? and not to_aqua? ->
        with :ok <- no_other_agent(args["reference"]), do: {:ok, :component}

      touches? and not writer.person? ->
        {:error, :aqua_line_by_person}

      leaving? ->
        if is_binary(args["profile_id"]),
          do: {:ok, :component},
          else: {:error, {:invalid_argument, "A component's schedule binds a profile"}}

      true ->
        with :ok <- no_profile(args), do: line_update(args, aqua?)
    end
  end

  # An Aqua line kept or made: the line when the update names one, which
  # making one requires.
  defp line_update(args, aqua?) do
    pinned =
      if aqua?,
        do: %{},
        else: %{reference: @aqua_line, resolved_reference: @aqua_line, profile_id: nil}

    if Map.has_key?(args, "input") or not aqua? do
      with {:ok, input_json} <- aqua_input(args),
           do: {:ok, {:aqua, Map.put(pinned, :input, input_json)}}
    else
      {:ok, {:aqua, pinned}}
    end
  end

  # The reference, profile and input an update writes, as its target is a
  # component's (re-resolved and its binding authorized, as at create) or
  # an Aqua line's.
  defp target_update(_ctx, _schedule, _args, update_attrs, {:aqua, attrs}),
    do: {:ok, Map.merge(update_attrs, attrs)}

  defp target_update(ctx, schedule, args, update_attrs, :component) do
    with {:ok, update_attrs} <- maybe_resolve_reference(ctx, args, update_attrs),
         :ok <- maybe_authorize_profile_binding(ctx, schedule, args, update_attrs) do
      update_attrs =
        if Map.has_key?(args, "profile_id"),
          do: Map.put(update_attrs, :profile_id, args["profile_id"]),
          else: update_attrs

      update_attrs =
        if Map.has_key?(args, "input"),
          do: Map.put(update_attrs, :input, if(args["input"], do: safe_encode(args["input"]))),
          else: update_attrs

      {:ok, update_attrs}
    end
  end

  defp next_run(cron) do
    case compute_next_run(cron) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp maybe_resolve_reference(ctx, %{"reference" => reference}, update_attrs)
       when is_binary(reference) do
    with {:ok, ref, resolved} <- resolve_for_schedule(ctx, reference, "update schedule reference"),
         :ok <- verify_component_exists(ctx, resolved) do
      {:ok, update_attrs |> Map.put(:reference, ref) |> Map.put(:resolved_reference, resolved)}
    end
  end

  defp maybe_resolve_reference(_ctx, _args, update_attrs), do: {:ok, update_attrs}

  defp safe_encode(value), do: Prima.Json.safe_encode(value)

  # Binding a schedule to a profile mints a standing, attacker-timed
  # invocation conduit for that profile's authority — the consent
  # authorization class gates it, not a permission a wildcard key holds.
  # A component's schedule fires under its bound profile's consent or not
  # at all: its create is refused without a `profile_id`
  # (`profile_given/1`), the declaration refuses a nil one at update, and
  # the table holds its column non-null for every row but an Aqua line's.
  defp authorize_profile_binding(ctx, target_ref, profile_id) when is_binary(profile_id) do
    case Sanctum.Consent.RegistrationBinding.authorize(ctx, target_ref, profile_id) do
      :ok -> :ok
      {:error, reason} -> {:error, Sanctum.Consent.RegistrationBinding.refusal(reason)}
    end
  end

  # Re-pointing is the same act as binding: the gate runs against the
  # target the row will have after this update — whether the update moves
  # the profile, the reference, or both.
  defp maybe_authorize_profile_binding(ctx, schedule, args, update_attrs) do
    repointed? = Map.has_key?(update_attrs, :resolved_reference)

    case Map.fetch(args, "profile_id") do
      :error when not repointed? ->
        :ok

      fetched ->
        profile_id =
          case fetched do
            {:ok, profile_id} -> profile_id
            :error -> schedule.profile_id
          end

        target = Map.get(update_attrs, :resolved_reference, schedule.resolved_reference)

        authorize_profile_binding(ctx, target, profile_id)
    end
  end
end
