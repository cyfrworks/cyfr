# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Retention.Kind do
  @moduledoc """
  One retainable kind of record — the seam between retention policy
  (`Cyfr.Retention`: the roster, the per-athanor settings document, the
  scheduler cadence, the MCP surface) and each kind's row mechanics.

  An adapter interprets ONE settings value in its own unit — `:keep`
  (the newest N survive) or `:days` (rows older than N days go) — and
  answers in one convention: `{:ok, count}` affected (deleted, or
  would-be deleted on a dry run), `{:error, term}` when its store cannot
  answer. Adding a kind is one adapter module plus one entry in
  `Cyfr.Retention.kinds/0`; the settings document, the scheduler loop
  and the MCP tool's vocabulary all derive from that roster and cannot
  fall behind it.

  `key/0` is BOTH the settings-document key and the MCP `cleanup_type`
  spelling — deliberately the stored spelling (`"mcp_log_days"`, not a
  prettier rename): the value lives in athanor rows, and a renamed key
  would silently revert every configured policy to its default, which
  for a lengthened policy means deleting records the athanor asked to
  keep.
  """

  @doc "The settings key and cleanup vocabulary — `\"executions\"`, `\"mcp_log_days\"`, …"
  @callback key() :: String.t()

  @doc "The value while the athanor has not configured one (config may override)."
  @callback default() :: pos_integer()

  @doc "How the value reads: `:keep` (newest N survive) or `:days` (age cutoff)."
  @callback unit() :: :keep | :days

  @doc """
  Apply the policy inside the context's athanor: delete — or, on a dry
  run, count — everything past `value`, answering `{:ok, affected}`.
  """
  @callback prune(Sanctum.Context.t(), pos_integer(), dry_run :: boolean()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc "The cutoff a `:days` value names, from now."
  @spec days_cutoff(pos_integer()) :: DateTime.t()
  def days_cutoff(days) when is_integer(days) and days > 0 do
    DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
  end
end
