defmodule Opus.CronMCP do
  @moduledoc """
  MCP tool provider for cron schedule management.

  Provides a single `schedule` tool with action-based dispatch for
  creating, listing, updating, pausing, resuming, and deleting
  user-scoped recurring WASM component executions.
  """

  alias Sanctum.Context

  @max_schedules_per_user 25

  def resources, do: []
  def resource_templates, do: []
  def read(_ctx, _uri), do: {:error, "No resources"}

  def tools do
    [
      %{
        name: "schedule",
        title: "Cron Schedule",
        description: "Manage recurring WASM component execution schedules",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["create", "list", "get", "update", "pause", "resume", "delete"],
              "description" => "Action to perform"
            },
            "name" => %{
              "type" => "string",
              "description" => "Human-readable schedule name, unique per user (create/update)"
            },
            "cron_expression" => %{
              "type" => "string",
              "description" => "Cron expression, e.g. '*/5 * * * *' (create/update). Minimum 1-minute interval."
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
         :ok <- validate_limit(ctx.user_id) do
      input_json = if args["input"], do: Jason.encode!(args["input"]), else: nil
      metadata_json = if args["metadata"], do: Jason.encode!(args["metadata"]), else: nil

      next_run =
        case compute_next_run(args["cron_expression"]) do
          {:ok, dt} -> dt
          _ -> nil
        end

      attrs = %{
        user_id: ctx.user_id,
        name: args["name"],
        cron_expression: args["cron_expression"],
        reference: args["reference"],
        input: input_json,
        metadata: metadata_json,
        next_run_at: next_run
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
    limit = args["limit"] || 25
    schedules = Arca.CronSchedule.list_by_user(ctx.user_id, limit: limit)

    {:ok, %{
      schedules: Enum.map(schedules, &format_schedule/1),
      count: length(schedules)
    }}
  end

  # Get
  def handle("schedule", %Context{} = ctx, %{"action" => "get", "schedule_id" => id}) do
    case Arca.CronSchedule.get_by_user(ctx.user_id, id) do
      nil -> {:error, "Schedule not found: #{id}"}
      schedule -> {:ok, format_schedule(schedule)}
    end
  end

  def handle("schedule", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: schedule_id"}
  end

  # Update
  def handle("schedule", %Context{} = ctx, %{"action" => "update", "schedule_id" => id} = args) do
    case Arca.CronSchedule.get_by_user(ctx.user_id, id) do
      nil ->
        {:error, "Schedule not found: #{id}"}

      schedule ->
        # Validate cron if being changed
        if args["cron_expression"] do
          case validate_cron(args["cron_expression"]) do
            :ok -> :ok
            error -> throw(error)
          end
        end

        update_attrs = %{}
        update_attrs = if args["name"], do: Map.put(update_attrs, :name, args["name"]), else: update_attrs
        update_attrs = if args["cron_expression"], do: Map.put(update_attrs, :cron_expression, args["cron_expression"]), else: update_attrs
        update_attrs = if args["reference"], do: Map.put(update_attrs, :reference, args["reference"]), else: update_attrs

        update_attrs =
          if Map.has_key?(args, "input"),
            do: Map.put(update_attrs, :input, if(args["input"], do: Jason.encode!(args["input"]))),
            else: update_attrs

        update_attrs =
          if Map.has_key?(args, "metadata"),
            do: Map.put(update_attrs, :metadata, if(args["metadata"], do: Jason.encode!(args["metadata"]))),
            else: update_attrs

        # Recompute next_run if cron changed
        cron = args["cron_expression"] || schedule.cron_expression

        update_attrs =
          case compute_next_run(cron) do
            {:ok, dt} -> Map.put(update_attrs, :next_run_at, dt)
            _ -> update_attrs
          end

        case Arca.CronSchedule.update(schedule.id, update_attrs) do
          {:ok, updated} ->
            Opus.CronScheduler.update(updated.id)
            {:ok, format_schedule(updated)}

          {:error, changeset} ->
            {:error, format_changeset_error(changeset)}
        end
    end
  catch
    {:error, _} = err -> err
  end

  def handle("schedule", _ctx, %{"action" => "update"}) do
    {:error, "Missing required argument: schedule_id"}
  end

  # Pause
  def handle("schedule", %Context{} = ctx, %{"action" => "pause", "schedule_id" => id}) do
    case Arca.CronSchedule.get_by_user(ctx.user_id, id) do
      nil ->
        {:error, "Schedule not found: #{id}"}

      schedule ->
        case Arca.CronSchedule.update(schedule.id, %{status: "paused"}) do
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
    case Arca.CronSchedule.get_by_user(ctx.user_id, id) do
      nil ->
        {:error, "Schedule not found: #{id}"}

      schedule ->
        next_run =
          case compute_next_run(schedule.cron_expression) do
            {:ok, dt} -> dt
            _ -> nil
          end

        case Arca.CronSchedule.update(schedule.id, %{status: "active", next_run_at: next_run}) do
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
    case Arca.CronSchedule.get_by_user(ctx.user_id, id) do
      nil ->
        {:error, "Schedule not found: #{id}"}

      schedule ->
        case Arca.CronSchedule.soft_delete(schedule.id) do
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
            {:error, "Minimum interval is 1 minute. Expression '#{expr}' runs every #{interval}s."}

          {:ok, _} ->
            :ok

          {:error, reason} ->
            {:error, "Invalid cron expression: #{reason}"}
        end

      {:error, reason} ->
        {:error, "Invalid cron expression: #{reason}"}
    end
  end

  defp validate_limit(user_id) do
    count = Arca.CronSchedule.count_by_user(user_id)

    if count >= @max_schedules_per_user do
      {:error, "Schedule limit reached (#{@max_schedules_per_user} per user)"}
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
      {:ok, data} -> data
      _ -> nil
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
end
