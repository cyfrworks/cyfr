defmodule Arca.Retention do
  @moduledoc """
  Retention policy enforcement for CYFR storage.

  Implements configurable retention policies for execution records and other
  user data. The Sanctum defaults to keeping the last 10 executions
  per user.

  ## MCP Tool Interface

  Retention settings can be managed via the `storage` MCP tool:

      # Get current settings
      {"action": "retention", "retention_action": "get"}

      # Update settings (admin only)
      {"action": "retention", "retention_action": "set", "settings": {"executions": 5}}

      # Run cleanup (admin only)
      {"action": "retention", "retention_action": "cleanup", "cleanup_type": "executions"}

      # Preview cleanup without deleting
      {"action": "retention", "retention_action": "cleanup", "dry_run": true}

  ## Storage

  User-specific settings are persisted to `users/{user_id}/config/retention.json`.
  If no user settings exist, global defaults from application config are used.

  ## Global Defaults (config.exs)

      config :arca, Arca.Retention,
        executions: 10,        # Keep last N executions per user
        builds: 10,            # Keep last N builds per user
        audit_days: 30         # Keep audit logs for N days

  ## Programmatic Usage

      ctx = Sanctum.Context.local()

      # Get user-specific settings (or defaults)
      settings = Arca.Retention.get_settings(ctx)

      # Update user settings
      :ok = Arca.Retention.set_settings(ctx, %{"executions" => 5})

      # Clean up old executions for a user
      {:ok, deleted_count} = Arca.Retention.cleanup_executions(ctx)

      # Preview what would be deleted
      {:ok, %{would_delete: ids}} = Arca.Retention.cleanup_executions(ctx, dry_run: true)

  """

  alias Sanctum.Context

  @default_execution_retention 10
  @default_build_retention 10
  @default_audit_days 30

  # ============================================================================
  # Configuration
  # ============================================================================

  @doc """
  Get current retention settings (global defaults from config).

  Returns a map with all retention configuration values.
  """
  @spec settings() :: %{
          executions: non_neg_integer(),
          builds: non_neg_integer(),
          audit_days: non_neg_integer()
        }
  def settings do
    config = Application.get_env(:arca, __MODULE__, [])

    %{
      executions: Keyword.get(config, :executions, @default_execution_retention),
      builds: Keyword.get(config, :builds, @default_build_retention),
      audit_days: Keyword.get(config, :audit_days, @default_audit_days)
    }
  end

  @doc """
  Get retention settings for a user context.

  Reads user-specific settings from Arca, falling back to global defaults.
  Settings are stored at `config/retention.json` in the user's directory.
  """
  @spec get_settings(Context.t()) :: map()
  def get_settings(%Context{} = ctx) do
    defaults = settings()

    case Arca.get_json(ctx, ["config", "retention.json"]) do
      {:ok, user_settings} ->
        %{
          "executions" => user_settings["executions"] || defaults.executions,
          "builds" => user_settings["builds"] || defaults.builds,
          "audit_days" => user_settings["audit_days"] || defaults.audit_days
        }

      {:error, _} ->
        %{
          "executions" => defaults.executions,
          "builds" => defaults.builds,
          "audit_days" => defaults.audit_days
        }
    end
  end

  @doc """
  Set retention settings for a user context.

  Stores user-specific settings in Arca at `config/retention.json`.
  Only provided keys are updated; missing keys retain their current values.
  """
  @spec set_settings(Context.t(), map()) :: :ok | {:error, term()}
  def set_settings(%Context{} = ctx, new_settings) when is_map(new_settings) do
    current = get_settings(ctx)

    updated = %{
      "executions" => get_positive_int(new_settings, "executions", current["executions"]),
      "builds" => get_positive_int(new_settings, "builds", current["builds"]),
      "audit_days" => get_positive_int(new_settings, "audit_days", current["audit_days"])
    }

    Arca.put_json(ctx, ["config", "retention.json"], updated)
  end

  defp get_positive_int(map, key, default) do
    value = Map.get(map, key) || Map.get(map, String.to_atom(key))

    cond do
      is_integer(value) and value > 0 -> value
      is_binary(value) -> String.to_integer(value) |> max(1)
      true -> default
    end
  rescue
    _ -> default
  end

  # ============================================================================
  # Execution Cleanup
  # ============================================================================

  @doc """
  Clean up old execution records for a user.

  Keeps the most recent N executions (based on started_at timestamp) and
  deletes older ones via SQLite. N is configured via `:executions` setting.

  ## Options

  - `:keep` - Override the number of executions to keep (default from config)
  - `:dry_run` - If true, returns what would be deleted without actually deleting

  ## Returns

  - `{:ok, deleted_count}` - Number of executions deleted
  - `{:ok, %{would_delete: ids}}` - If dry_run is true
  """
  @spec cleanup_executions(Context.t(), keyword()) :: {:ok, non_neg_integer() | map()} | {:error, term()}
  def cleanup_executions(%Context{} = ctx, opts \\ []) do
    user_settings = get_settings(ctx)
    keep = Keyword.get(opts, :keep, user_settings["executions"])
    dry_run = Keyword.get(opts, :dry_run, false)

    if dry_run do
      ids_to_delete = Arca.Execution.ids_to_delete(ctx.user_id, keep)
      total = length(Arca.Execution.list(user_id: ctx.user_id, limit: 999_999))
      would_keep = min(total, keep)
      {:ok, %{would_delete: ids_to_delete, would_keep: would_keep}}
    else
      {count, _} = Arca.Execution.delete_older_than(ctx.user_id, keep)
      {:ok, count}
    end
  end

  @doc """
  Clean up executions for all users.

  Iterates through all users that have execution records in SQLite
  and applies retention policy.

  ## Options

  Same as `cleanup_executions/2`

  ## Returns

  - `{:ok, %{users: count, deleted: count}}` - Summary of cleanup
  """
  @spec cleanup_all_executions(Context.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def cleanup_all_executions(%Context{} = ctx, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    user_ids = Arca.Execution.distinct_user_ids()

    results =
      user_ids
      |> Enum.map(fn user_id ->
        user_ctx = %{ctx | user_id: user_id}
        cleanup_executions(user_ctx, opts)
      end)
      |> Enum.filter(fn
        {:ok, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    if dry_run do
      all_would_delete = Enum.flat_map(results, fn %{would_delete: ids} -> ids end)
      {:ok, %{users: length(user_ids), would_delete: all_would_delete}}
    else
      {:ok, %{users: length(user_ids), deleted: Enum.sum(results)}}
    end
  end

  # ============================================================================
  # Audit Log Cleanup
  # ============================================================================

  @doc """
  Clean up old audit events for a user.

  Deletes audit events older than the configured `audit_days` setting
  via SQLite DELETE query.

  ## Options

  - `:days` - Override the number of days to keep (default from config)
  - `:dry_run` - If true, returns what would be deleted without actually deleting

  ## Returns

  - `{:ok, deleted_count}` - Number of audit events deleted
  - `{:ok, %{would_delete: ids}}` - If dry_run is true
  """
  @spec cleanup_audit(Context.t(), keyword()) :: {:ok, non_neg_integer() | map()} | {:error, term()}
  def cleanup_audit(%Context{} = ctx, opts \\ []) do
    user_settings = get_settings(ctx)
    days = Keyword.get(opts, :days, user_settings["audit_days"])
    dry_run = Keyword.get(opts, :dry_run, false)
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    if dry_run do
      import Ecto.Query

      ids =
        from(e in Arca.AuditEvent,
          where: e.user_id == ^ctx.user_id,
          where: e.timestamp < ^cutoff,
          select: e.id
        )
        |> Arca.Repo.all()

      total = length(Arca.AuditEvent.list(user_id: ctx.user_id, limit: 999_999))
      would_keep = total - length(ids)
      {:ok, %{would_delete: ids, would_keep: would_keep}}
    else
      import Ecto.Query

      {count, _} =
        from(e in Arca.AuditEvent,
          where: e.user_id == ^ctx.user_id,
          where: e.timestamp < ^cutoff
        )
        |> Arca.Repo.delete_all()

      {:ok, count}
    end
  end

  # ============================================================================
  # Build Cleanup
  # ============================================================================

  @doc """
  Clean up old build records for a user.

  Builds are file-based artifacts (WASM binaries), so this still uses
  file-based cleanup via the Arca storage adapter.
  """
  @spec cleanup_builds(Context.t(), keyword()) :: {:ok, non_neg_integer() | map()} | {:error, term()}
  def cleanup_builds(%Context{} = ctx, opts \\ []) do
    user_settings = get_settings(ctx)
    keep = Keyword.get(opts, :keep, user_settings["builds"])
    dry_run = Keyword.get(opts, :dry_run, false)

    case list_builds_with_timestamps(ctx) do
      {:ok, builds} ->
        sorted = Enum.sort_by(builds, fn {_id, ts} -> ts end, :desc)
        to_delete = Enum.drop(sorted, keep)

        if dry_run do
          ids_to_delete = Enum.map(to_delete, fn {id, _ts} -> id end)
          {:ok, %{would_delete: ids_to_delete}}
        else
          deleted_count =
            to_delete
            |> Enum.map(fn {id, _ts} -> delete_build(ctx, id) end)
            |> Enum.count(&(&1 == :ok))

          {:ok, deleted_count}
        end

      {:error, _} = err ->
        err
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp list_builds_with_timestamps(ctx) do
    case Arca.list(ctx, ["builds"]) do
      {:ok, build_ids} ->
        builds =
          build_ids
          |> Enum.map(fn id -> {id, get_build_timestamp(ctx, id)} end)
          |> Enum.reject(fn {_id, ts} -> is_nil(ts) end)

        {:ok, builds}

      {:error, :not_found} ->
        {:ok, []}

      {:error, _} = err ->
        err
    end
  end

  defp get_build_timestamp(ctx, id) do
    case Arca.get_json(ctx, ["builds", id, "started.json"]) do
      {:ok, data} -> data["started_at"]
      _ -> nil
    end
  end

  defp delete_build(ctx, id) do
    Arca.delete_tree(ctx, ["builds", id])
  end
end
