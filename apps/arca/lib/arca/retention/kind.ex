# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.Kind do
  @moduledoc """
  One retainable kind of record — the seam between retention policy
  (`Arca.Retention`: the roster, the per-athanor settings, the cleanup)
  and each kind's row mechanics.

  An adapter interprets ONE settings value in its own unit — `:keep`
  (the newest N survive) or `:days` (rows older than N days go) — and
  answers in one convention: `{:ok, count}` affected (deleted, or
  would-be deleted on a dry run), `{:error, term}` when its store cannot
  answer. Adding a kind is one adapter module plus one entry in
  `Arca.Retention.kinds/0`; the settings, the cleanup and the `retention`
  tool's vocabulary all derive from that roster and cannot fall behind
  it.

  `key/0` is BOTH the settings key and the `cleanup_type` spelling —
  deliberately the stored spelling (`"mcp_log_days"`, not a prettier
  rename): the value lives in the athanor's settings row, and a renamed
  key would silently revert every configured policy to its default,
  which for a lengthened policy means deleting records the athanor asked
  to keep.
  """

  @doc "The settings key and cleanup vocabulary — `\"executions\"`, `\"mcp_log_days\"`, …"
  @callback key() :: String.t()

  @doc "The value while the athanor has not set one (`config :arca, Arca.Retention` may override)."
  @callback default() :: pos_integer()

  @doc "How the value reads: `:keep` (newest N survive) or `:days` (age cutoff)."
  @callback unit() :: :keep | :days

  @doc """
  Apply the policy inside the actor's athanor: delete — or, on a dry
  run, count — everything past `value`, answering `{:ok, affected}`.
  """
  @callback prune(Cyfr.Actor.t(), pos_integer(), dry_run :: boolean()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc "The cutoff a `:days` value names, from now."
  @spec days_cutoff(pos_integer()) :: DateTime.t()
  def days_cutoff(days) when is_integer(days) and days > 0 do
    DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
  end

  @doc """
  A value from `config :arca, Arca.Retention` — a kind's default or a
  bound of its own — or `fallback` when the configuration names none.
  """
  @spec configured(atom(), pos_integer()) :: pos_integer()
  def configured(key, fallback) when is_atom(key) and is_integer(fallback) and fallback > 0,
    do: Keyword.get(Application.get_env(:arca, Arca.Retention, []), key, fallback)
end
