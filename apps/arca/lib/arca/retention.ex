# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention do
  @moduledoc """
  Retention policy for tenant data — which records an athanor keeps, and
  for how long.

  Retention is per athanor: the estate owns its records, and every member
  sees the same ones. This module owns the roster and the policy.
  `kinds/0` names every retainable kind (`Arca.Retention.Kind` adapters;
  the row mechanics live with each kind's store), and the settings, the
  `retention` tool's vocabulary (`Arca.Providers.Records`) and the
  per-athanor cleanup all derive from that roster, so none of them can
  fall behind it.

  ## Settings

  An athanor's values live in its own `retention_settings` row
  (`Arca.RetentionSettings`), keyed by each kind's `key/0`, apart from
  the security-owned settings document on the athanor row. A key the
  athanor never set reads as its kind's default, which
  `config :arca, Arca.Retention` may override. Every value drives
  destructive cleanup, so settings that are corrupt or cannot be read
  refuse cleanup rather than default: defaulting could delete data the
  athanor asked to keep.

  ## Cleanup

  `cleanup/3` applies one kind inside the actor's athanor, for a caller
  that asked for it. `cleanup_athanor/2` applies every kind under the
  athanor's own settings, for the server's walk over the active estates;
  that walk, and which estates are active, are the host's
  (`Cyfr.RetentionScheduler`), and it hands this module one narrowly
  scoped system actor per estate. An archived estate is never handed
  here: its records freeze with it.

  ## Usage

      actor = Prima.Actor.in_athanor("ath_test")

      {:ok, settings} = Arca.Retention.get_settings(actor)
      {:ok, settings} = Arca.Retention.set_settings(actor, %{"executions" => 5})

      {:ok, deleted} = Arca.Retention.cleanup(actor, "executions")
      {:ok, would_delete} = Arca.Retention.cleanup(actor, "executions", dry_run: true)
  """

  @kinds [
    Arca.Retention.Executions,
    Arca.Retention.ExecutionsAge,
    Arca.Retention.Payloads,
    Arca.Retention.WebhookPayloads,
    Arca.Retention.SchedulePayloads,
    Arca.Retention.SystemPayloads,
    Arca.Retention.Builds,
    Arca.Retention.McpLogs,
    Arca.Retention.PolicyLogs,
    Arca.Retention.Decisions,
    Arca.Retention.Threads,
    Arca.Retention.StagedRevisions,
    Arca.Retention.WriteIntents,
    Arca.Retention.ProjectionTombstones
  ]

  # The largest integer the settings row's canonical encoding carries
  # (RFC 8785 numbers are IEEE 754 doubles).
  @max_value 9_007_199_254_740_991

  @typedoc "One value per retention key."
  @type settings :: %{String.t() => pos_integer()}

  @typedoc "Why settings could not be read or written."
  @type settings_refusal :: :no_athanor | :corrupt | :database_error

  @doc "The closed roster of retainable kinds — everything else derives from it."
  @spec kinds() :: [module()]
  def kinds, do: @kinds

  @doc """
  The class an execution's payloads are kept under when its caller names
  none: a webhook's under `webhook`, the server's own under `system`,
  everything else under `api`. A turn's own dispatches name `chat_step`.
  """
  @spec default_class(Prima.Actor.t()) :: String.t()
  def default_class(%Prima.Actor{user_id: "webhook:" <> _}), do: "webhook"
  def default_class(%Prima.Actor{system: true}), do: "system"
  def default_class(%Prima.Actor{}), do: "api"

  # ============================================================================
  # Settings
  # ============================================================================

  @doc """
  The actor's athanor's settings — one key per kind, a key it never set
  read as the kind's default.
  """
  @spec get_settings(Prima.Actor.t()) :: {:ok, settings()} | {:error, settings_refusal()}
  def get_settings(%Prima.Actor{} = actor) do
    with {:ok, %{patch: patch}} <- Arca.RetentionSettings.get(actor) do
      {:ok, fill(patch)}
    end
  end

  @doc """
  Set some of the actor's athanor's settings, answering all of them as
  they now stand. Only roster keys are accepted, and only positive
  integers or integer strings as values; anything else refuses typed
  rather than silently keeping the old value. Keys not named keep their
  values, including under a patch another caller lands at the same time.
  """
  @spec set_settings(Prima.Actor.t(), map()) ::
          {:ok, settings()}
          | {:error,
             {:unknown_setting, String.t()}
             | {:invalid_setting, String.t()}
             | settings_refusal()
             | :settings_conflict}
  def set_settings(%Prima.Actor{} = actor, changes) when is_map(changes) do
    with {:ok, validated} <- validate(changes),
         {:ok, %{patch: patch}} <- Arca.RetentionSettings.patch(actor, validated) do
      {:ok, fill(patch)}
    end
  end

  defp fill(patch), do: Map.new(@kinds, &{&1.key(), Map.get(patch, &1.key(), &1.default())})

  defp validate(changes) do
    known = MapSet.new(@kinds, & &1.key())

    Enum.reduce_while(changes, {:ok, %{}}, fn {key, value}, {:ok, validated} ->
      cond do
        not MapSet.member?(known, key) -> {:halt, {:error, {:unknown_setting, key}}}
        positive = positive_int(value) -> {:cont, {:ok, Map.put(validated, key, positive)}}
        true -> {:halt, {:error, {:invalid_setting, key}}}
      end
    end)
  end

  defp positive_int(value) when is_integer(value) and value > 0 and value <= @max_value,
    do: value

  defp positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> positive_int(n)
      _ -> nil
    end
  end

  defp positive_int(_value), do: nil

  # ============================================================================
  # Cleanup
  # ============================================================================

  @doc """
  Apply one kind's policy inside the actor's athanor: delete — or, with
  `dry_run: true`, count — everything past the athanor's value for it.
  `value:` overrides that value for a one-off cleanup and must be a
  positive integer (`{:error, {:invalid_setting, key}}` otherwise).

  Answers `{:ok, affected_count}`, `{:error, {:unknown_kind, key}}` for a
  key outside the roster, the settings refusal when the athanor's
  settings are corrupt or cannot be read (`:corrupt`, `:database_error`)
  — an override included, since nothing destructive runs for an estate
  whose settings cannot be established — or the kind's own store error.
  """
  @spec cleanup(Prima.Actor.t(), String.t(), keyword()) ::
          {:ok, non_neg_integer()}
          | {:error,
             {:unknown_kind, String.t()}
             | {:invalid_setting, String.t()}
             | settings_refusal()
             | term()}
  def cleanup(actor, key, opts \\ [])

  def cleanup(%Prima.Actor{athanor_id: id}, key, _opts)
      when is_binary(key) and (is_nil(id) or id == ""),
      do: {:error, :no_athanor}

  def cleanup(%Prima.Actor{} = actor, key, opts) when is_binary(key) and is_list(opts) do
    case Enum.find(@kinds, &(&1.key() == key)) do
      nil ->
        {:error, {:unknown_kind, key}}

      kind ->
        with {:ok, override} <- override(kind, opts),
             {:ok, settings} <- get_settings(actor) do
          value = override || Map.fetch!(settings, kind.key())
          kind.prune(actor, value, Keyword.get(opts, :dry_run, false))
        end
    end
  end

  defp override(kind, opts) do
    case Keyword.fetch(opts, :value) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _invalid} -> {:error, {:invalid_setting, kind.key()}}
      :error -> {:ok, nil}
    end
  end

  @doc """
  Every kind's policy inside one athanor, under that athanor's own
  settings, read once. The unit `Cyfr.RetentionScheduler` walks across
  the active estates, so the actor must be the server's own, narrowed to
  that one athanor: `system: true`, `scope: :athanor` and its
  `athanor_id` (`{:error, :forbidden}` otherwise, `{:error, :no_athanor}`
  without an athanor). `dry_run: true` counts instead of deleting.

  Answers what each kind deleted and the `{key, reason}` of each kind
  that failed; a kind that failed never stops the rest. Settings that are
  corrupt or cannot be read refuse the whole of it, before any kind runs.
  """
  @spec cleanup_athanor(Prima.Actor.t(), keyword()) ::
          {:ok, %{deleted: %{String.t() => non_neg_integer()}, errors: [{String.t(), term()}]}}
          | {:error, :corrupt | :database_error | :forbidden | :no_athanor}
  def cleanup_athanor(actor, opts \\ [])

  def cleanup_athanor(%Prima.Actor{athanor_id: id}, _opts) when is_nil(id) or id == "",
    do: {:error, :no_athanor}

  def cleanup_athanor(%Prima.Actor{system: true, scope: :athanor} = actor, opts)
      when is_list(opts) do
    dry_run = Keyword.get(opts, :dry_run, false)

    with {:ok, settings} <- get_settings(actor) do
      {deleted, errors} =
        Enum.reduce(@kinds, {Map.new(@kinds, &{&1.key(), 0}), []}, fn kind, {deleted, errors} ->
          case kind.prune(actor, Map.fetch!(settings, kind.key()), dry_run) do
            {:ok, count} -> {Map.put(deleted, kind.key(), count), errors}
            {:error, reason} -> {deleted, [{kind.key(), reason} | errors]}
          end
        end)

      {:ok, %{deleted: deleted, errors: Enum.reverse(errors)}}
    end
  end

  def cleanup_athanor(%Prima.Actor{}, _opts), do: {:error, :forbidden}
end
