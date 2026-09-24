# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.WriteIntents do
  @moduledoc """
  Settled storage write intents older than N days go
  (`Arca.Schemas.StorageWriteIntent`): the evidence of what became of one
  mutable write a guest asked of its attempt.

  A guest reads this back within a turn or two of an uncertain write, and
  an operator reads it to see which writes may have landed; neither needs
  it for as long as the execution row it hangs from, which is what bounds
  it otherwise — one chatty attempt records one row per write.

  A `pending` intent is left whatever its age: it is the only record that
  a write may be in the store and was never settled, and the cascade from
  its execution's row takes it in the end.
  """
  @behaviour Arca.Retention.Kind

  alias Arca.Retention.Kind

  @impl true
  def key, do: "write_intent_days"

  @impl true
  def default, do: Kind.configured(:write_intent_days, 30)

  @impl true
  def unit, do: :days

  @impl true
  def prune(%Cyfr.Actor{athanor_id: athanor}, days, dry_run) when is_binary(athanor) do
    cutoff = Kind.days_cutoff(days)
    opts = [athanor_id: athanor]

    if dry_run,
      do: Arca.ExecutionAttempts.count_intents_before(cutoff, opts),
      else: Arca.ExecutionAttempts.delete_intents_before(cutoff, opts)
  end
end
