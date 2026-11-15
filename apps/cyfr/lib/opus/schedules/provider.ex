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
  Only that person's own signed-in session (`aqua_writer/1`) makes one,
  turns a schedule into one or out of one, or changes its line: a key's
  call, a tincture's and any other caller is refused
  `:aqua_line_by_person`, and an agent cannot reach these writes at all,
  since they take the external plane alone. Pausing, resuming, deleting,
  renaming and retiming one are a schedule's ordinary writes. No other
  agent is a schedule's reference, and an Aqua line has no version to
  re-resolve.

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
                required: true,
                description:
                  "Cron expression, e.g. '*/5 * * * *' (create/update). Minimum 1-minute interval."
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
  def handle(
        "schedule",
        %Context{} = ctx,
        %{"action" => "create", "reference" => @aqua_line} = args
      ) do
    with :ok <- aqua_writer(ctx),
         :ok <- validate_required(args, ["name", "cron_expression"]),
         :ok <- validate_cron(args["cron_expression"]),
         :ok <- no_profile(args),
         {:ok, missed} <- missed_runs(args, %{missed_runs: "skip", catch_up_limit: nil}),
         {:ok, input_json} <- aqua_input(args) do
      attrs = %{
        user_id: ctx.user_id,
        name: args["name"],
        cron_expression: args["cron_expression"],
        reference: @aqua_line,
        resolved_reference: @aqua_line,
        input: input_json,
        metadata: if(args["metadata"], do: safe_encode(args["metadata"])),
        next_run_at: next_run(args["cron_expression"]),
        profile_id: nil,
        concurrency: args["concurrency"] || "forbid"
      }

      insert(ctx, Map.merge(attrs, missed))
    end
  end

  def handle("schedule", %Context{} = ctx, %{"action" => "create"} = args) do
    with :ok <- validate_required(args, ["name", "cron_expression", "reference"]),
         :ok <- no_other_agent(args["reference"]),
         :ok <- profile_given(args),
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
         {:ok, missed} <- missed_runs(args, schedule),
         {:ok, line} <- aqua_update(ctx, schedule, args) do
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

        # Recompute next_run if cron changed
        cron = args["cron_expression"] || schedule.cron_expression

        update_attrs =
          case compute_next_run(cron) do
            {:ok, dt} -> Map.put(update_attrs, :next_run_at, dt)
            _ -> update_attrs
          end

        case Arca.CronSchedule.update(Sanctum.Context.actor(ctx), schedule.id, update_attrs,
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
  defp insert(ctx, attrs) do
    with {:ok, cap} <- schedule_cap() do
      case Arca.CronSchedule.create(
             Sanctum.Context.actor(ctx),
             Map.merge(attrs, %{cap: cap, by_person: by_person?(ctx)})
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
  defp store_refusal(reason, _id) when reason in [:not_owner, :no_athanor, :aqua_line_by_person],
    do: {:error, reason}

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

  # Who may make an Aqua line or change its line: the schedule's person in
  # a signed-in session of their own (a browser's, or a paired device's),
  # never through an API key or a tincture's frame credential, and never
  # under an origin that is no person's own act. The declaration keeps
  # these writes off the in-chain plane, so no agent's call reaches here.
  defp aqua_writer(%Context{auth_method: method, api_key_id: nil, frame: nil, origin: origin})
       when method in [:oidc, :device] and origin in [nil, :interactive],
       do: :ok

  defp aqua_writer(_ctx), do: {:error, :aqua_line_by_person}

  # What the storage write is told of its caller: whether it is the
  # person's own signed-in session, decided from the context alone. The
  # store decides against the row it locks whether that is needed
  # (`Arca.CronSchedule.update/4`); the check above is only the fast
  # refusal on the row as read.
  defp by_person?(ctx), do: aqua_writer(ctx) == :ok

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
  # update that touches an Aqua line's reference or input, or makes a
  # schedule one, is the person's; one that leaves it names the profile
  # the component binds.
  defp aqua_update(ctx, schedule, args) do
    aqua? = schedule.reference == @aqua_line
    to_aqua? = args["reference"] == @aqua_line
    leaving? = aqua? and Map.has_key?(args, "reference") and not to_aqua?
    touches? = Map.has_key?(args, "reference") or Map.has_key?(args, "input")

    cond do
      not aqua? and not to_aqua? ->
        with :ok <- no_other_agent(args["reference"]), do: {:ok, :component}

      touches? and aqua_writer(ctx) != :ok ->
        aqua_writer(ctx)

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
