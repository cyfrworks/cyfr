# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Retention do
  require Logger
  require Arca.Repo.Errors

  @moduledoc """
  Retention policy for tenant data — which records an athanor keeps, and
  for how long.

  Retention is per athanor — the furnace owns its records, and every
  member sees the same ones. This module owns the policy: the settings
  file, the defaults, and which setting governs which entity. The row
  mechanics live with each entity's storage (`Arca.Execution`,
  `Arca.McpLog`, `Arca.PolicyLog`, `Arca.ConversationStorage`); the MCP
  surface lives with its dispatcher
  (`Emissary.MCP.Tools.RecordsProvider`).

  ## Storage

  An athanor's settings are persisted to `config/retention.json` under the
  tenant-scoped path that `Arca.Storage.tenant_segments/1` builds, so each
  athanor carries its own copy. Settings are shared by all members of the
  athanor. If no settings exist, global defaults from application config
  are used.

  ## Global Defaults (config.exs)

      config :cyfr, Cyfr.Retention,
        executions: 10,        # Keep last N executions per athanor
        builds: 10             # Keep last N builds per athanor

  ## Programmatic Usage

      ctx = Sanctum.TestContext.local()

      # Get the athanor's settings (or defaults)
      settings = Cyfr.Retention.get_settings(ctx)

      # Update the athanor's settings
      :ok = Cyfr.Retention.set_settings(ctx, %{"executions" => 5})

      # Clean up old executions in the athanor
      {:ok, deleted_count} = Cyfr.Retention.cleanup_executions(ctx)

      # Preview what would be deleted
      {:ok, %{would_delete: ids}} = Cyfr.Retention.cleanup_executions(ctx, dry_run: true)

  """

  alias Sanctum.Context

  @default_execution_retention 10_000
  @default_build_retention 100
  @default_mcp_log_days 30
  @default_policy_log_days 30
  @default_messages_days 365

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
          mcp_log_days: non_neg_integer(),
          policy_log_days: non_neg_integer(),
          messages_days: non_neg_integer()
        }
  def settings do
    # The module moved out of Arca; the old config key keeps working for
    # one release so an operator's config does not silently reset.
    config =
      Application.get_env(:cyfr, __MODULE__) ||
        Application.get_env(:cyfr, Arca.Retention, [])

    %{
      executions: Keyword.get(config, :executions, @default_execution_retention),
      builds: Keyword.get(config, :builds, @default_build_retention),
      mcp_log_days: Keyword.get(config, :mcp_log_days, @default_mcp_log_days),
      policy_log_days: Keyword.get(config, :policy_log_days, @default_policy_log_days),
      messages_days: Keyword.get(config, :messages_days, @default_messages_days)
    }
  end

  @doc """
  Get retention settings for a context's athanor.

  Reads the athanor's settings from Arca, falling back to global defaults.
  Settings are stored at `config/retention.json` in the athanor's tenant
  directory and are shared by all its members.
  """
  @spec get_settings(Context.t()) :: map()
  def get_settings(%Context{} = ctx) do
    defaults = settings()

    case Arca.get_json(ctx, ["config", "retention.json"]) do
      {:ok, user_settings} ->
        %{
          "executions" => user_settings["executions"] || defaults.executions,
          "builds" => user_settings["builds"] || defaults.builds,
          "mcp_log_days" => user_settings["mcp_log_days"] || defaults.mcp_log_days,
          "policy_log_days" => user_settings["policy_log_days"] || defaults.policy_log_days,
          "messages_days" => user_settings["messages_days"] || defaults.messages_days
        }

      {:error, _} ->
        %{
          "executions" => defaults.executions,
          "builds" => defaults.builds,
          "mcp_log_days" => defaults.mcp_log_days,
          "policy_log_days" => defaults.policy_log_days,
          "messages_days" => defaults.messages_days
        }
    end
  end

  @doc """
  Set retention settings for the context's athanor.

  Stores the athanor's settings in Arca at `config/retention.json`.
  Only provided keys are updated; missing keys retain their current values.
  """
  @spec set_settings(Context.t(), map()) :: :ok | {:error, term()}
  def set_settings(%Context{} = ctx, new_settings) when is_map(new_settings) do
    current = get_settings(ctx)

    updated = %{
      "executions" => get_positive_int(new_settings, "executions", current["executions"]),
      "builds" => get_positive_int(new_settings, "builds", current["builds"]),
      "mcp_log_days" => get_positive_int(new_settings, "mcp_log_days", current["mcp_log_days"]),
      "policy_log_days" =>
        get_positive_int(new_settings, "policy_log_days", current["policy_log_days"]),
      "messages_days" => get_positive_int(new_settings, "messages_days", current["messages_days"])
    }

    Arca.put_json(ctx, ["config", "retention.json"], updated)
  end

  defp get_positive_int(map, key, default) do
    value = Map.get(map, key) || Map.get(map, String.to_existing_atom(key))

    cond do
      is_integer(value) and value > 0 -> value
      is_binary(value) -> String.to_integer(value) |> max(1)
      true -> default
    end
  rescue
    _e in ArgumentError ->
      Logger.warning("[Retention] Invalid setting for #{key}: not a valid integer")
      default
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
  @spec cleanup_executions(Context.t(), keyword()) ::
          {:ok, non_neg_integer() | map()} | {:error, term()}
  def cleanup_executions(%Context{} = ctx, opts \\ []) do
    user_settings = get_settings(ctx)
    keep = Keyword.get(opts, :keep, user_settings["executions"])
    dry_run = Keyword.get(opts, :dry_run, false)

    tenant_opts = [athanor_id: ctx.athanor_id]

    if dry_run do
      ids_to_delete = Arca.Execution.ids_to_delete(keep, tenant_opts)

      total = length(Arca.Execution.list(athanor_id: ctx.athanor_id, limit: 999_999))

      would_keep = min(total, keep)
      {:ok, %{would_delete: ids_to_delete, would_keep: would_keep}}
    else
      case Arca.Execution.delete_older_than(keep, tenant_opts) do
        {:error, _} = err -> err
        {count, _} -> {:ok, count}
      end
    end
  end

  @doc """
  Clean up executions for every athanor.

  Iterates through all athanors that have execution records and applies each
  athanor's retention policy.

  ## Options

  Same as `cleanup_executions/2`

  ## Returns

  - `{:ok, %{tenants: count, deleted: count}}` - Summary of cleanup
  """
  @spec cleanup_all_executions(Context.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def cleanup_all_executions(%Context{} = ctx, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    tenants = Arca.Execution.distinct_athanors(ctx)

    {successes, failures} =
      tenants
      |> Enum.map(fn athanor_id ->
        # Each athanor's cleanup runs inside that athanor: its own settings
        # file, its own rows.
        tenant_ctx =
          Sanctum.internal_context(
            user_id: ctx.user_id,
            athanor_id: athanor_id,
            scope: :athanor
          )

        {athanor_id, cleanup_executions(tenant_ctx, opts)}
      end)
      |> Enum.split_with(fn {_, result} -> match?({:ok, _}, result) end)

    success_results = Enum.map(successes, fn {_, {:ok, r}} -> r end)

    error_list =
      Enum.map(failures, fn {athanor_id, {:error, reason}} ->
        {athanor_id, reason}
      end)

    if dry_run do
      all_would_delete = Enum.flat_map(success_results, fn %{would_delete: ids} -> ids end)
      {:ok, %{tenants: length(tenants), would_delete: all_would_delete, errors: error_list}}
    else
      {:ok, %{tenants: length(tenants), deleted: Enum.sum(success_results), errors: error_list}}
    end
  end

  @doc """
  Clean up MCP logs, policy logs and stale conversations for every athanor
  that has any, each inside its own context (its own retention settings).
  Returns per-kind totals and the athanors whose cleanup failed.
  """
  @spec cleanup_all_logs(keyword()) :: {:ok, map()}
  def cleanup_all_logs(opts \\ []) do
    athanors =
      (Arca.McpLog.distinct_athanors() ++
         Arca.PolicyLog.distinct_athanors() ++ Arca.ConversationStorage.distinct_athanors())
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    results =
      Enum.map(athanors, fn athanor_id ->
        ctx = Sanctum.internal_context(user_id: "system", athanor_id: athanor_id, scope: :athanor)

        {athanor_id, cleanup_mcp_logs(ctx, opts), cleanup_policy_logs(ctx, opts),
         cleanup_conversations(ctx, opts)}
      end)

    mcp_deleted = results |> Enum.map(fn {_, r, _, _} -> count_of(r) end) |> Enum.sum()
    policy_deleted = results |> Enum.map(fn {_, _, r, _} -> count_of(r) end) |> Enum.sum()
    conversations_deleted = results |> Enum.map(fn {_, _, _, r} -> count_of(r) end) |> Enum.sum()

    errors =
      for {athanor_id, mcp, policy, conv} <- results,
          {kind, {:error, reason}} <- [mcp_logs: mcp, policy_logs: policy, conversations: conv],
          do: {athanor_id, kind, reason}

    {:ok,
     %{
       tenants: length(athanors),
       mcp_logs_deleted: mcp_deleted,
       policy_logs_deleted: policy_deleted,
       conversations_deleted: conversations_deleted,
       errors: errors
     }}
  end

  defp count_of({:ok, count}) when is_integer(count), do: count
  defp count_of(_), do: 0

  # ============================================================================
  # Build Cleanup
  # ============================================================================

  @doc """
  Clean up old build records for a user.

  Build records are flat `builds/{id}.json` status files written by
  `Locus.MCP`, so this still uses file-based cleanup via the Arca
  storage adapter. The newest `keep` records survive, ordered by their
  `started_at` timestamp.
  """
  @spec cleanup_builds(Context.t(), keyword()) ::
          {:ok, non_neg_integer() | map()} | {:error, term()}
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
  # MCP Log Cleanup
  # ============================================================================

  @doc """
  Clean up old MCP log records.

  Deletes logs older than the configured `mcp_log_days` setting.

  ## Options

  - `:days` - Override the number of days to keep (default from config)
  - `:dry_run` - If true, returns what would be deleted without actually deleting

  ## Returns

  - `{:ok, deleted_count}` - Number of logs deleted
  - `{:ok, %{would_delete: count}}` - If dry_run is true
  """
  @spec cleanup_mcp_logs(Context.t(), keyword()) ::
          {:ok, non_neg_integer() | map()} | {:error, term()}
  def cleanup_mcp_logs(%Context{} = ctx, opts \\ []) do
    user_settings = get_settings(ctx)
    days = Keyword.get(opts, :days, user_settings["mcp_log_days"])
    dry_run = Keyword.get(opts, :dry_run, false)

    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)
    tenant_opts = [athanor_id: ctx.athanor_id]

    if dry_run do
      case Arca.McpLog.count_before(cutoff, tenant_opts) do
        {:error, _} = err -> err
        count -> {:ok, %{would_delete: count}}
      end
    else
      case Arca.McpLog.delete_before(cutoff, tenant_opts) do
        {:error, _} = err -> err
        {count, _} -> {:ok, count}
      end
    end
  end

  @doc """
  Clean up old policy enforcement log records.

  Deletes logs older than the configured `policy_log_days` setting.

  ## Options

  - `:days` - Override the number of days to keep (default from config)
  - `:dry_run` - If true, returns what would be deleted without actually deleting

  ## Returns

  - `{:ok, deleted_count}` - Number of logs deleted
  - `{:ok, %{would_delete: count}}` - If dry_run is true
  """
  @spec cleanup_policy_logs(Context.t(), keyword()) ::
          {:ok, non_neg_integer() | map()} | {:error, term()}
  def cleanup_policy_logs(%Context{} = ctx, opts \\ []) do
    user_settings = get_settings(ctx)
    days = Keyword.get(opts, :days, user_settings["policy_log_days"])
    dry_run = Keyword.get(opts, :dry_run, false)

    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)
    tenant_opts = [athanor_id: ctx.athanor_id]

    if dry_run do
      case Arca.PolicyLog.count_before(cutoff, tenant_opts) do
        {:error, _} = err -> err
        count -> {:ok, %{would_delete: count}}
      end
    else
      case Arca.PolicyLog.delete_before(cutoff, tenant_opts) do
        {:error, _} = err -> err
        {count, _} -> {:ok, count}
      end
    end
  end

  @doc """
  Clean up the athanor's conversations whose last activity is older than
  the configured `messages_days` (messages go with them). A conversation
  with a running turn is never touched.

  ## Options

  - `:days` - Override the number of days to keep (default from config)
  - `:dry_run` - If true, returns what would be deleted without deleting

  ## Returns

  - `{:ok, deleted_count}` / `{:ok, %{would_delete: count}}` on dry run
  """
  @spec cleanup_conversations(Context.t(), keyword()) ::
          {:ok, non_neg_integer() | map()} | {:error, term()}
  def cleanup_conversations(%Context{} = ctx, opts \\ []) do
    days = Keyword.get(opts, :days, get_settings(ctx)["messages_days"])
    dry_run = Keyword.get(opts, :dry_run, false)
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    if dry_run do
      {:ok, %{would_delete: Arca.ConversationStorage.count_before(ctx, cutoff)}}
    else
      {count, _} = Arca.ConversationStorage.delete_before(ctx, cutoff)
      {:ok, count}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Cyfr.Retention] cleanup_conversations failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Build records are flat `builds/{id}.json` files (Locus.MCP's
  # build_record_path/1); an entry without a readable `started_at` is
  # kept, never deleted.
  defp list_builds_with_timestamps(ctx) do
    case Arca.list(ctx, ["builds"]) do
      {:ok, entries} ->
        builds =
          entries
          |> Enum.map(fn entry -> {Path.rootname(entry), get_build_timestamp(ctx, entry)} end)
          |> Enum.reject(fn {_id, ts} -> is_nil(ts) end)

        {:ok, builds}

      {:error, :not_found} ->
        {:ok, []}

      {:error, _} = err ->
        err
    end
  end

  defp get_build_timestamp(ctx, entry) do
    case Arca.get_json(ctx, ["builds", entry]) do
      {:ok, data} -> data["started_at"]
      _ -> nil
    end
  end

  defp delete_build(ctx, id) do
    Arca.delete(ctx, ["builds", id <> ".json"])
  end
end
