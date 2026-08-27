# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Retention do
  require Logger

  @moduledoc """
  Retention policy for tenant data — which records an athanor keeps, and
  for how long.

  Retention is per athanor — the furnace owns its records, and every
  member sees the same ones. This module owns the roster and the policy:
  `kinds/0` names every retainable kind (`Cyfr.Retention.Kind` adapters
  — the row mechanics live with each kind's store), and the settings
  document, the scheduler loop (`Cyfr.RetentionScheduler`) and the MCP
  `retention` tool's vocabulary
  (`Emissary.MCP.Tools.RecordsProvider`) all derive from that roster, so
  none of them can fall behind it.

  ## Storage

  An athanor's retention policy lives under the `"retention"` key of its
  settings document (`Sanctum.Tenancy.Athanors.settings/1` — the row's
  JSON column), next to every other per-athanor setting; the keys are
  each kind's `key/0`. Settings are shared by all members; an athanor
  that never configured retention gets the defaults (each kind's, which
  `config :cyfr, Cyfr.Retention` may override). Every key drives
  destructive cleanup, so an unreadable settings document is an error
  the cleanup walks skip — defaulting there could delete data the
  athanor asked to keep.

  ## The roster walk

  `cleanup_all/1` walks `Sanctum.Tenancy.Athanors.list_active/0`: an
  archived athanor's records freeze with it — archiving touches nothing,
  purging is the deliberate reclaim, and retention resumes if the
  furnace reopens.

  ## Usage

      ctx = Sanctum.TestContext.local()

      {:ok, settings} = Cyfr.Retention.get_settings(ctx)
      :ok = Cyfr.Retention.set_settings(ctx, %{"executions" => 5})

      {:ok, deleted} = Cyfr.Retention.cleanup(ctx, "executions")
      {:ok, would_delete} = Cyfr.Retention.cleanup(ctx, "executions", dry_run: true)
  """

  alias Sanctum.Context

  @kinds [
    Cyfr.Retention.Executions,
    Cyfr.Retention.Builds,
    Cyfr.Retention.McpLogs,
    Cyfr.Retention.PolicyLogs,
    Cyfr.Retention.Conversations
  ]

  @doc "The closed roster of retainable kinds — everything else derives from it."
  @spec kinds() :: [module()]
  def kinds, do: @kinds

  @doc """
  Get retention settings for the context's athanor — one string key per
  kind, missing keys filled from the kind's default. A missing row means
  the athanor never configured retention; an unreadable row is an error,
  not the defaults: every setting drives destructive cleanup, and a
  transient database failure must not silently shorten a policy the
  athanor lengthened.
  """
  @spec get_settings(Context.t()) :: {:ok, %{String.t() => pos_integer()}} | {:error, term()}
  def get_settings(%Context{} = ctx) do
    case Sanctum.Tenancy.Athanors.get(ctx.athanor_id) do
      {:ok, athanor} ->
        configured =
          case Sanctum.Tenancy.Athanors.settings(athanor)["retention"] do
            %{} = map -> map
            _ -> %{}
          end

        {:ok,
         Map.new(@kinds, fn kind -> {kind.key(), configured[kind.key()] || kind.default()} end)}

      {:error, :not_found} ->
        {:ok, Map.new(@kinds, fn kind -> {kind.key(), kind.default()} end)}

      {:error, reason} ->
        Logger.warning(
          "[Cyfr.Retention] settings unreadable for athanor #{ctx.athanor_id} " <>
            "(#{inspect(reason)}); skipping rather than defaulting"
        )

        {:error, reason}
    end
  end

  @doc """
  Set retention settings for the context's athanor. Only roster keys are
  accepted, only positive integers (or integer strings) as values —
  anything else refuses typed instead of silently keeping the old value.
  Provided keys update; missing keys retain their current values.
  """
  @spec set_settings(Context.t(), map()) ::
          :ok | {:error, {:unknown_setting, String.t()} | {:invalid_setting, String.t()} | term()}
  def set_settings(%Context{} = ctx, new_settings) when is_map(new_settings) do
    with :ok <- validate_settings(new_settings),
         {:ok, current} <- get_settings(ctx),
         {:ok, athanor} <- Sanctum.Tenancy.Athanors.get(ctx.athanor_id) do
      updated =
        Map.new(@kinds, fn kind ->
          key = kind.key()

          case Map.fetch(new_settings, key) do
            {:ok, value} -> {key, coerce_positive_int!(value)}
            :error -> {key, current[key]}
          end
        end)

      case Sanctum.Tenancy.Athanors.put_settings(athanor, %{"retention" => updated}) do
        {:ok, _athanor} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_settings(new_settings) do
    known = MapSet.new(@kinds, & &1.key())

    Enum.find_value(new_settings, :ok, fn {key, value} ->
      cond do
        not MapSet.member?(known, key) -> {:error, {:unknown_setting, key}}
        not positive_int?(value) -> {:error, {:invalid_setting, key}}
        true -> nil
      end
    end)
  end

  defp positive_int?(value) when is_integer(value), do: value > 0

  defp positive_int?(value) when is_binary(value) do
    match?({n, ""} when n > 0, Integer.parse(value))
  end

  defp positive_int?(_), do: false

  # Validated above — the bang is for the impossible arm.
  defp coerce_positive_int!(value) when is_integer(value), do: value
  defp coerce_positive_int!(value) when is_binary(value), do: String.to_integer(value)

  @doc """
  Apply one kind's policy inside the context's athanor: delete — or, with
  `dry_run: true`, count — everything past the athanor's configured value
  (`value:` overrides it for a one-off cleanup). Answers
  `{:ok, affected_count}`, `{:error, {:unknown_kind, key}}` for a key
  outside the roster, or the kind's own store error.
  """
  @spec cleanup(Context.t(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def cleanup(%Context{} = ctx, key, opts \\ []) when is_binary(key) do
    case Enum.find(@kinds, &(&1.key() == key)) do
      nil ->
        {:error, {:unknown_kind, key}}

      kind ->
        dry_run = Keyword.get(opts, :dry_run, false)

        case Keyword.fetch(opts, :value) do
          {:ok, value} when is_integer(value) and value > 0 ->
            kind.prune(ctx, value, dry_run)

          :error ->
            with {:ok, settings} <- get_settings(ctx) do
              kind.prune(ctx, settings[key], dry_run)
            end
        end
    end
  end

  @doc """
  Every kind's policy across every active athanor, each inside its own
  context (its own settings). Answers per-kind totals and the
  `{athanor_id, key, reason}` triples whose cleanup failed — a failure
  in one athanor or kind never stops the walk.
  """
  @spec cleanup_all(keyword()) :: {:ok, map()}
  def cleanup_all(opts \\ []) do
    athanors = Sanctum.Tenancy.Athanors.list_active()

    {deleted, errors} =
      Enum.reduce(athanors, {Map.new(@kinds, &{&1.key(), 0}), []}, fn athanor, acc ->
        ctx = athanor_ctx(athanor.id)

        Enum.reduce(@kinds, acc, fn kind, {deleted, errors} ->
          case cleanup(ctx, kind.key(), opts) do
            {:ok, count} -> {Map.update!(deleted, kind.key(), &(&1 + count)), errors}
            {:error, reason} -> {deleted, [{athanor.id, kind.key(), reason} | errors]}
          end
        end)
      end)

    {:ok, %{tenants: length(athanors), deleted: deleted, errors: Enum.reverse(errors)}}
  end

  @doc """
  Reclaim orphaned conversation blob directories across every active
  athanor (`Arca.ConversationStorage.sweep_orphaned_blobs/1` — bytes a
  best-effort delete once left behind, still counted against the storage
  cap). Roster-driven, each athanor inside its own context.
  """
  @spec sweep_conversation_blob_orphans() :: {:ok, map()}
  def sweep_conversation_blob_orphans do
    athanors = Sanctum.Tenancy.Athanors.list_active()

    results =
      Enum.map(athanors, fn athanor ->
        {athanor.id, Arca.ConversationStorage.sweep_orphaned_blobs(athanor_ctx(athanor.id))}
      end)

    reclaimed =
      results
      |> Enum.map(fn
        {_id, {:ok, count}} when is_integer(count) -> count
        {_id, _} -> 0
      end)
      |> Enum.sum()

    errors = for {athanor_id, {:error, reason}} <- results, do: {athanor_id, reason}

    {:ok, %{tenants: length(athanors), dirs_deleted: reclaimed, errors: errors}}
  end

  # Each athanor's cleanup runs inside that athanor — its own settings,
  # its own rows; the user_id is audit attribution only. Least privilege:
  # a deleter reads settings and drops rows and blobs, it executes
  # nothing.
  defp athanor_ctx(athanor_id, user_id \\ "system") do
    Sanctum.internal_context(
      user_id: user_id,
      athanor_id: athanor_id,
      scope: :athanor,
      permissions: [:storage_read, :storage_write]
    )
  end
end
