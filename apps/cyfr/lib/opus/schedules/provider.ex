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
  taking no subject, and handed its current state first:

    * `schedules.changes` rides the athanor's schedules topic. Its
      refresh is every live schedule of the athanor, paused ones
      included, as `changed` (`live_schedules/2`).
    * `schedule_runs.changes` rides the athanor's schedule runs topic. Its
      refresh is the athanor's 20 newest occurrences of schedules
      (`recent_runs/2`).

  Neither carries a schedule's input, metadata, profile, pinned
  reference, maker or feed columns.

  The cap is the platform setting `max_schedules_per_athanor` (0 is no
  ceiling), read at each create and handed to `Arca.CronSchedule.create/2`,
  which counts the athanor's non-deleted schedules, a paused one included,
  and inserts in one transaction under the athanor's row lock.
  """

  # The one kind of row this tool reads and writes.
  @kind "schedule"

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
                required: true,
                description:
                  "Cron expression, e.g. '*/5 * * * *' (create/update). Minimum 1-minute interval."
              ),
              Arg.new("reference", :string,
                required: true,
                description: "Component reference string (create/update)"
              ),
              Arg.new("profile_id", :string,
                required: true,
                description:
                  "Profile the schedule fires under; its consent authorizes the binding (create, required; update). re_resolve re-authorizes the schedule's existing profile and ignores this argument."
              ),
              Arg.new("input", {:map, Arg.new(nil, :json)},
                description: "Input data to pass to the component (create/update)"
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
            planes: [:external],
            permission: :execute
          ),
          Operation.new(
            "schedule",
            "list",
            "List schedule",
            [
              Arg.new("limit", :integer,
                description: "Maximum results to return (list)",
                default: 25
              )
            ],
            kind: :read,
            sources: [],
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
            sources: [],
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
                  "Cron expression, e.g. '*/5 * * * *' (create/update). Minimum 1-minute interval."
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
                description: "Input data to pass to the component (create/update)"
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
              )
            ],
            kind: :write,
            planes: [:external],
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
            planes: [:external],
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
            planes: [:external],
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
            planes: [:external],
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
        description: "Manage recurring WASM component execution schedules",
        title: "Cron Schedule"
      )
    ]
  end

  # Create
  @impl true
  def handle("schedule", %Context{} = ctx, %{"action" => "create"} = args) do
    with :ok <- validate_required(args, ["name", "cron_expression", "reference"]),
         :ok <- validate_cron(args["cron_expression"]),
         {:ok, missed} <- missed_runs(args, %{missed_runs: "skip", catch_up_limit: nil}),
         {:ok, reference, resolved_reference} <-
           resolve_for_schedule(ctx, args["reference"], "create schedule"),
         :ok <- verify_component_exists(ctx, resolved_reference),
         :ok <- authorize_profile_binding(ctx, resolved_reference, args["profile_id"]) do
      input_json = if args["input"], do: safe_encode(args["input"]), else: nil
      metadata_json = if args["metadata"], do: safe_encode(args["metadata"]), else: nil

      next_run =
        case compute_next_run(args["cron_expression"]) do
          {:ok, dt} -> dt
          _ -> nil
        end

      attrs = %{
        user_id: ctx.user_id,
        name: args["name"],
        cron_expression: args["cron_expression"],
        reference: reference,
        resolved_reference: resolved_reference,
        input: input_json,
        metadata: metadata_json,
        next_run_at: next_run,
        profile_id: args["profile_id"],
        concurrency: args["concurrency"] || "forbid"
      }

      insert(ctx, Map.merge(attrs, missed))
    end
  end

  # List
  def handle("schedule", %Context{} = ctx, %{"action" => "list"} = args) do
    limit = min(args["limit"] || 25, 1000)

    case Arca.CronSchedule.list(Sanctum.Context.actor(ctx), limit: limit, kind: @kind) do
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
    with {:schedule, {:ok, schedule}} <-
           {:schedule, schedule(ctx, id)},
         :ok <- validate_cron_if_present(args["cron_expression"]),
         {:ok, missed} <- missed_runs(args, schedule) do
      update_attrs = missed

      update_attrs =
        if args["concurrency"],
          do: Map.put(update_attrs, :concurrency, args["concurrency"]),
          else: update_attrs

      update_attrs =
        if args["name"], do: Map.put(update_attrs, :name, args["name"]), else: update_attrs

      update_attrs =
        if args["cron_expression"],
          do: Map.put(update_attrs, :cron_expression, args["cron_expression"]),
          else: update_attrs

      # Re-resolve reference if it changed (mirror the create path)
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

        update_attrs =
          if Map.has_key?(args, "metadata"),
            do:
              Map.put(
                update_attrs,
                :metadata,
                if(args["metadata"], do: safe_encode(args["metadata"]))
              ),
            else: update_attrs

        # Recompute next_run if cron changed
        cron = args["cron_expression"] || schedule.cron_expression

        update_attrs =
          case compute_next_run(cron) do
            {:ok, dt} -> Map.put(update_attrs, :next_run_at, dt)
            _ -> update_attrs
          end

        case Arca.CronSchedule.update(Sanctum.Context.actor(ctx), schedule.id, update_attrs) do
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
  def handle("schedule", %Context{} = ctx, %{"action" => "pause", "schedule_id" => id}) do
    case schedule(ctx, id) do
      {:error, reason} ->
        {:error, format_store_error(reason, id)}

      {:ok, schedule} ->
        case Arca.CronSchedule.update(Sanctum.Context.actor(ctx), schedule.id, %{status: "paused"}) do
          {:ok, updated} ->
            Opus.Schedules.Scheduler.pause(updated.id)
            Changes.changed(Sanctum.Context.actor(ctx), updated.id)
            {:ok, format_schedule(updated)}

          {:error, reason} ->
            store_refusal(reason, id)
        end
    end
  end

  # Resume
  def handle("schedule", %Context{} = ctx, %{"action" => "resume", "schedule_id" => id}) do
    case schedule(ctx, id) do
      {:error, reason} ->
        {:error, format_store_error(reason, id)}

      {:ok, schedule} ->
        # No cap check here: the cap counts every non-deleted schedule, so a
        # paused schedule still occupies its slot and resume never mints one.
        next_run =
          case compute_next_run(schedule.cron_expression) do
            {:ok, dt} -> dt
            _ -> nil
          end

        case Arca.CronSchedule.update(Sanctum.Context.actor(ctx), schedule.id, %{
               status: "active",
               next_run_at: next_run
             }) do
          {:ok, updated} ->
            Opus.Schedules.Scheduler.resume(updated.id)
            Changes.changed(Sanctum.Context.actor(ctx), updated.id)
            {:ok, format_schedule(updated)}

          {:error, reason} ->
            store_refusal(reason, id)
        end
    end
  end

  # Delete
  def handle("schedule", %Context{} = ctx, %{"action" => "delete", "schedule_id" => id}) do
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

  # Re-resolve — bump resolved_reference to latest version without recreating the schedule
  def handle("schedule", %Context{} = ctx, %{"action" => "re_resolve", "schedule_id" => id}) do
    case schedule(ctx, id) do
      {:error, reason} ->
        {:error, format_store_error(reason, id)}

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
          "error_count"
        ],
        deadline_bound: @deadline_bound,
        shape: schedules_shape(),
        refresh: {__MODULE__, :live_schedules}
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
          "reason"
        ],
        deadline_bound: @deadline_bound,
        shape: schedule_runs_shape(),
        refresh: {__MODULE__, :recent_runs}
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
            "message" => %{"type" => "string"}
          },
          "required" => ["class", "message"]
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
      [] -> :ok
      keys -> {:error, "Missing required arguments: #{Enum.join(keys, ", ")}"}
    end
  end

  defp validate_cron(expr) do
    case Opus.Schedules.Cron.parse(expr) do
      {:ok, _} ->
        case Opus.Schedules.Cron.min_interval_seconds(expr) do
          {:ok, interval} when interval < 60 ->
            {:error,
             "Minimum interval is 1 minute. Expression '#{expr}' runs every #{interval}s."}

          {:ok, _} ->
            :ok

          {:error, reason} ->
            {:error, "Invalid cron expression: #{reason}"}
        end

      {:error, reason} ->
        {:error, "Invalid cron expression: #{reason}"}
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
  defp insert(ctx, attrs) do
    with {:ok, cap} <- schedule_cap() do
      case Arca.CronSchedule.create(Sanctum.Context.actor(ctx), Map.put(attrs, :cap, cap)) do
        {:ok, schedule} ->
          Opus.Schedules.Scheduler.add(schedule.id)
          Changes.changed(Sanctum.Context.actor(ctx), schedule.id)
          {:ok, format_schedule(schedule)}

        {:error, :schedule_cap} ->
          {:error, "Schedule limit reached (#{cap} per athanor)"}

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
      reference: schedule.reference,
      resolved_reference: schedule.resolved_reference,
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

  # The storage layer answers typed reasons; this seam renders them.
  # A write's refusal: a member that lost its slot is answered in the
  # refusal vocabulary, as a feed's write is; the rest as sentences.
  defp store_refusal(reason, _id) when reason in [:not_owner, :no_athanor], do: {:error, reason}
  defp store_refusal(reason, id), do: {:error, format_store_error(reason, id)}

  defp format_store_error(reason, id \\ nil)
  defp format_store_error(:not_found, nil), do: "Schedule not found"
  defp format_store_error(:not_found, id), do: "Schedule not found: #{id}"
  defp format_store_error(:database_error, _), do: "Storage unavailable — try again shortly"

  defp format_store_error({:validation, errors}, _) when is_map(errors) do
    Enum.map_join(errors, "; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
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
      case Arca.CronSchedule.update(Sanctum.Context.actor(ctx), schedule.id, %{
             resolved_reference: pinned
           }) do
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

  defp validate_cron_if_present(nil), do: :ok
  defp validate_cron_if_present(expr), do: validate_cron(expr)

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
  # A schedule fires under its bound profile's consent or not at all: the
  # declaration requires a string `profile_id` at create and refuses a nil
  # one at update, and the stored column is never null.
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
