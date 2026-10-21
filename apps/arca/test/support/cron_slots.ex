# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.CronSlots do
  @moduledoc """
  How many of an athanor's cap slots of one kind are taken, as a test
  observes it: the rows `Arca.CronSchedule.list/2` answers, which are
  every row of the kind not deleted, paused ones included. The cap itself
  is counted inside the create's transaction (`Arca.CronSchedule`).
  """

  @spec occupied(Prima.Actor.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def occupied(%Prima.Actor{} = actor, kind) do
    with {:ok, rows} <- Arca.CronSchedule.list(actor, kind: kind, limit: 10_000),
         do: {:ok, length(rows)}
  end
end
