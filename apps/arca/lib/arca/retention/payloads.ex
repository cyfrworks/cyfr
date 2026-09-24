# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.Payloads do
  @moduledoc """
  Retained execution payloads of the default class (`api`) and of chat
  steps (`chat_step`) older than N days go — the bytes and the rows that
  reference them. The other classes have kinds of their own
  (`Arca.Retention.WebhookPayloads`, `Arca.Retention.SchedulePayloads`,
  `Arca.Retention.SystemPayloads`), each with its own window.
  """
  @behaviour Arca.Retention.Kind

  alias Arca.Retention.Kind

  @classes ["api", "chat_step"]

  @impl true
  def key, do: "payload_days"

  @impl true
  def default, do: Kind.configured(:payload_days, 30)

  @impl true
  def unit, do: :days

  @impl true
  def prune(actor, days, dry_run), do: prune_classes(actor, @classes, days, dry_run)

  @doc "Delete — or on a dry run count — the payloads in `classes` older than `days`."
  @spec prune_classes(Cyfr.Actor.t(), [String.t()], pos_integer(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def prune_classes(%Cyfr.Actor{} = actor, classes, days, dry_run) do
    if dry_run,
      do: Arca.ExecutionPayloads.count_older_than_days(actor, days, classes),
      else: Arca.ExecutionPayloads.delete_older_than_days(actor, days, classes)
  end
end
