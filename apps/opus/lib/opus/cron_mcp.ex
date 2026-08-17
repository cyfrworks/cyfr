# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.CronMCP do
  @moduledoc """
  MCP tool provider for cron schedule management.

  Provides a single `schedule` tool with action-based dispatch for
  creating, listing, updating, pausing, resuming, and deleting
  user-scoped recurring WASM component executions.
  """

  @behaviour Emissary.MCP.ToolProvider

  require Logger

  alias Sanctum.Context

  @max_schedules_per_athanor 25

  def resources, do: []
  def resource_templates, do: []
  def read(_ctx, _uri), do: {:error, "No resources"}

  def tools do
    [
      %{
        name: "schedule",
        title: "Cron Schedule",
        description: "Manage recurring WASM component execution schedules",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: true,
          actions: %{
            # create/update also require the registration's consent binding —
            # a conditional Authz check that stays in the handler.
            "create" => %{kind: :write, planes: [:external], permission: :execute},
            "list" => %{kind: :read, planes: [:external, :in_chain], permission: :execute},
            "get" => %{kind: :read, planes: [:external, :in_chain], permission: :execute},
            "update" => %{kind: :write, planes: [:external], permission: :execute},
            "pause" => %{kind: :write, planes: [:external], permission: :execute},
            "resume" => %{kind: :write, planes: [:external], permission: :execute},
            "delete" => %{kind: :destructive, planes: [:external], permission: :execute},
            "re_resolve" => %{kind: :write, planes: [:external], permission: :execute}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => [
                "create",
                "list",
                "get",
                "update",
                "pause",
                "resume",
                "delete",
                "re_resolve"
              ],
              "description" => "Action to perform"
            },
            "name" => %{
              "type" => "string",
              "description" =>
                "Human-readable schedule name, unique within the athanor (create/update)"
            },
            "cron_expression" => %{
              "type" => "string",
              "description" =>
                "Cron expression, e.g. '*/5 * * * *' (create/update). Minimum 1-minute interval."
            },
            "reference" => %{
              "type" => "string",
              "description" => "Component reference string (create/update)"
            },
            "input" => %{
              "type" => "object",
              "description" => "Input data to pass to the component (create/update)"
            },
            "metadata" => %{
              "type" => "object",
              "description" => "Optional metadata (create/update)"
            },
            "schedule_id" => %{
              "type" => "string",
              "description" => "Schedule ID or name (get/update/pause/resume/delete)"
            },
            "limit" => %{
              "type" => "integer",
              "default" => 25,
              "description" => "Maximum results to return (list)"
            }
          },
          "required" => ["action"]
        }
      }
    ]
  end

  # Create
  def handle("schedule", %Context{} = ctx, %{"action" => "create"} = args) do
    with :ok <- validate_required(args, ["name", "cron_expression", "reference"]),
         :ok <- validate_cron(args["cron_expression"]),
         :ok <- validate_limit(ctx),
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
        athanor_id: ctx.athanor_id,
        next_run_at: next_run,
        profile_id: args["profile_id"]
      }

      case Arca.CronSchedule.create(attrs) do
        {:ok, schedule} ->
          Opus.CronScheduler.add(schedule.id)
          {:ok, format_schedule(schedule)}

        {:error, changeset} ->
          {:error, format_changeset_error(changeset)}
      end
    end
  end

  # List
  def handle("schedule", %Context{} = ctx, %{"action" => "list"} = args) do
    limit = min(args["limit"] || 25, 1000)
    schedules = Arca.CronSchedule.list(ctx, limit: limit)

    {:ok,
     %{
       schedules: Enum.map(schedules, &format_schedule/1),
       count: length(schedules)
     }}
  end

  # Get
  def handle("schedule", %Context{} = ctx, %{"action" => "get", "schedule_id" => id}) do
    case Arca.CronSchedule.get_by_id_or_name(ctx, id) do
      nil -> {:error, "Schedule not found: #{id}"}
      schedule -> {:ok, format_schedule(schedule)}
    end
  end

  def handle("schedule", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: schedule_id"}
  end

  # Update
  def handle("schedule", %Context{} = ctx, %{"action" => "update", "schedule_id" => id} = args) do
    with {:schedule, schedule} when not is_nil(schedule) <-
           {:schedule, Arca.CronSchedule.get_by_id_or_name(ctx, id)},
         :ok <- validate_cron_if_present(args["cron_expression"]) do
      update_attrs = %{}

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

        case Arca.CronSchedule.update(ctx, schedule.id, update_attrs) do
          {:ok, updated} ->
            Opus.CronScheduler.update(updated.id)
            {:ok, format_schedule(updated)}

          {:error, changeset} ->
            {:error, format_changeset_error(changeset)}
        end
      end
    else
      {:schedule, nil} -> {:error, "Schedule not found: #{id}"}
      {:error, _} = err -> err
    end
  end

  def handle("schedule", _ctx, %{"action" => "update"}) do
    {:error, "Missing required argument: schedule_id"}
  end

  # Pause
  def handle("schedule", %Context{} = ctx, %{"action" => "pause", "schedule_id" => id}) do
    case Arca.CronSchedule.get_by_id_or_name(ctx, id) do
      nil ->
        {:error, "Schedule not found: #{id}"}

      schedule ->
        case Arca.CronSchedule.update(ctx, schedule.id, %{status: "paused"}) do
          {:ok, updated} ->
            Opus.CronScheduler.pause(updated.id)
            {:ok, format_schedule(updated)}

          {:error, changeset} ->
            {:error, format_changeset_error(changeset)}
        end
    end
  end

  def handle("schedule", _ctx, %{"action" => "pause"}) do
    {:error, "Missing required argument: schedule_id"}
  end

  # Resume
  def handle("schedule", %Context{} = ctx, %{"action" => "resume", "schedule_id" => id}) do
    case Arca.CronSchedule.get_by_id_or_name(ctx, id) do
      nil ->
        {:error, "Schedule not found: #{id}"}

      schedule ->
        next_run =
          case compute_next_run(schedule.cron_expression) do
            {:ok, dt} -> dt
            _ -> nil
          end

        case Arca.CronSchedule.update(ctx, schedule.id, %{
               status: "active",
               next_run_at: next_run
             }) do
          {:ok, updated} ->
            Opus.CronScheduler.resume(updated.id)
            {:ok, format_schedule(updated)}

          {:error, changeset} ->
            {:error, format_changeset_error(changeset)}
        end
    end
  end

  def handle("schedule", _ctx, %{"action" => "resume"}) do
    {:error, "Missing required argument: schedule_id"}
  end

  # Delete
  def handle("schedule", %Context{} = ctx, %{"action" => "delete", "schedule_id" => id}) do
    case Arca.CronSchedule.get_by_id_or_name(ctx, id) do
      nil ->
        {:error, "Schedule not found: #{id}"}

      schedule ->
        case Arca.CronSchedule.soft_delete(ctx, schedule.id) do
          {:ok, _} ->
            Opus.CronScheduler.remove(schedule.id)
            {:ok, %{deleted: true, schedule_id: schedule.id, name: schedule.name}}

          {:error, changeset} ->
            {:error, format_changeset_error(changeset)}
        end
    end
  end

  def handle("schedule", _ctx, %{"action" => "delete"}) do
    {:error, "Missing required argument: schedule_id"}
  end

  # Re-resolve — bump resolved_reference to latest version without recreating the schedule
  def handle("schedule", %Context{} = ctx, %{"action" => "re_resolve", "schedule_id" => id}) do
    case Arca.CronSchedule.get_by_id_or_name(ctx, id) do
      nil ->
        {:error, "Schedule not found: #{id}"}

      schedule ->
        case Compendium.Resolver.resolve(ctx, schedule.reference) do
          {:ok, pinned, _metadata} ->
            case Arca.CronSchedule.update(ctx, schedule.id, %{resolved_reference: pinned}) do
              {:ok, updated} ->
                Opus.CronScheduler.update(updated.id)
                {:ok, format_schedule(updated)}

              {:error, changeset} ->
                {:error, format_changeset_error(changeset)}
            end

          {:error, reason} ->
            {:error, "Failed to re-resolve '#{schedule.reference}': #{reason}"}
        end
    end
  end

  def handle("schedule", _ctx, %{"action" => "re_resolve"}) do
    {:error, "Missing required argument: schedule_id"}
  end

  # Invalid/missing action
  def handle("schedule", _ctx, %{"action" => action}) do
    {:error, "Invalid schedule action: #{action}"}
  end

  def handle("schedule", _ctx, _args) do
    {:error, "Missing required argument: action"}
  end

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end

  # Helpers

  defp validate_required(args, keys) do
    missing = Enum.filter(keys, fn k -> !args[k] || args[k] == "" end)

    case missing do
      [] -> :ok
      keys -> {:error, "Missing required arguments: #{Enum.join(keys, ", ")}"}
    end
  end

  defp validate_cron(expr) do
    case Opus.CronParser.parse(expr) do
      {:ok, _} ->
        case Opus.CronParser.min_interval_seconds(expr) do
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

  defp validate_limit(ctx) do
    count = Arca.CronSchedule.count_active(ctx)

    if count >= @max_schedules_per_athanor do
      {:error, "Schedule limit reached (#{@max_schedules_per_athanor} per athanor)"}
    else
      :ok
    end
  end

  defp compute_next_run(cron_expression) do
    case Opus.CronParser.parse(cron_expression) do
      {:ok, parsed} -> Opus.CronParser.next_run(parsed, DateTime.utc_now())
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
      input: decode_json(schedule.input),
      metadata: decode_json(schedule.metadata),
      status: schedule.status,
      next_run_at: schedule.next_run_at && DateTime.to_iso8601(schedule.next_run_at),
      last_run_at: schedule.last_run_at && DateTime.to_iso8601(schedule.last_run_at),
      last_execution_id: schedule.last_execution_id,
      run_count: schedule.run_count,
      error_count: schedule.error_count,
      created_at: schedule.created_at && DateTime.to_iso8601(schedule.created_at),
      updated_at: schedule.updated_at && DateTime.to_iso8601(schedule.updated_at)
    }
  end

  defp decode_json(nil), do: nil
  defp decode_json(""), do: nil

  defp decode_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, data} ->
        data

      _ ->
        Logger.warning("[CronMCP] Failed to decode JSON: #{inspect(json)}")
        nil
    end
  end

  defp format_changeset_error(%Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    inspect(errors)
  end

  defp format_changeset_error(other), do: inspect(other)

  defp resolve_for_schedule(ctx, reference, label) do
    case Compendium.Resolver.resolve(ctx, reference) do
      {:ok, pinned, %{was_resolved: true}} ->
        {:ok, reference, pinned}

      {:ok, pinned, _metadata} ->
        {:ok, pinned, pinned}

      {:error, reason} ->
        {:error, "Cannot #{label}: failed to resolve '#{reference}'. #{reason}"}
    end
  end

  defp verify_component_exists(ctx, resolved_reference) do
    case Compendium.Component.inspect_component(ctx, resolved_reference) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        {:error,
         "Component '#{resolved_reference}' not found in registry. Register or pull it first."}
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

  defp safe_encode(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> ~s({"_encoding_error":"value not encodable"})
    end
  end

  # Binding a schedule to a profile mints a standing, attacker-timed
  # invocation conduit for that profile's authority — the consent
  # authorization class gates it, not a permission a wildcard key holds.
  # A schedule fires under its bound profile's consent or not at all, so
  # an unbound registration is refused here rather than minted as a row
  # that can never fire.
  defp authorize_profile_binding(_ctx, _target_ref, nil) do
    {:error, "profile_id is required — a schedule fires under its bound profile's consent"}
  end

  defp authorize_profile_binding(ctx, target_ref, profile_id) when is_binary(profile_id) do
    case Sanctum.Consent.RegistrationBinding.authorize(ctx, target_ref, profile_id) do
      :ok -> :ok
      {:error, reason} -> {:error, "profile binding refused: #{inspect(reason)}"}
    end
  end

  defp authorize_profile_binding(_ctx, _target_ref, _), do: {:error, "invalid profile_id"}

  # Re-pointing is the same act as binding: the gate runs against the
  # target the row will have after this update. An explicit nil is an
  # unbind, and an unbound schedule can never fire — refuse it here the
  # same way create does.
  defp maybe_authorize_profile_binding(ctx, schedule, args, update_attrs) do
    case Map.fetch(args, "profile_id") do
      :error ->
        :ok

      {:ok, profile_id} ->
        target =
          Map.get(update_attrs, :resolved_reference) || schedule.resolved_reference ||
            schedule.reference

        authorize_profile_binding(ctx, target, profile_id)
    end
  end
end
