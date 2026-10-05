# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.FileReceipts do
  @moduledoc """
  The recovery of accepted transfers and the custody copies they leave
  (`Arca.FileOffers`), in the recipient's athanor.

  One sweep, in this order:

    1. `Arca.FileOffers.complete/2` for every `received` and `published`
       receipt, so a transfer a crash or a full cap left part-way resumes
       at its recorded path and state, reconciling before it writes;
    2. a `received` receipt older than the value for which no write was
       ever sent (`ever_issued` false) is marked `failed` and its custody
       copy released; one with a write ever sent is kept and reconciled on
       every sweep at any age, at its current and earlier issued paths,
       since a write that was sent may still land;
    3. a receipt `failed` for longer than the value (its failure written
       before the cutoff) is deleted: its recipient was told when it
       failed and has seen it listed since, and its custody copy went
       then;
    4. the custody copy of every `completed` or `failed` receipt still
       holding one is released, and copies no receipt row names are
       released once older than a day by the store's own clock.

  Nothing here touches a published destination. Answers how many receipts
  completed, failed or were deleted and how many copies were released
  (or, on a dry run, how many receipts would fail or be deleted and
  copies would go).
  """
  @behaviour Arca.Retention.Kind

  alias Arca.Retention.Kind

  @impl true
  def key, do: "file_receipt_days"

  @impl true
  def default, do: Kind.configured(:file_receipt_days, 7)

  @impl true
  def unit, do: :days

  @impl true
  def prune(%Prima.Actor{athanor_id: athanor} = actor, days, dry_run)
      when is_binary(athanor) and athanor != "" and is_integer(days) and days > 0 and
             is_boolean(dry_run) do
    cutoff = Kind.days_cutoff(days)

    # A receipt failed here is written now, after the cutoff, so it is not
    # also deleted by the same run.
    with {:ok, completed} <- resume(actor, dry_run),
         {:ok, failed} <- Arca.FileOffers.fail_stale(actor, cutoff, dry_run),
         {:ok, deleted} <- Arca.FileOffers.delete_failed(actor, cutoff, dry_run),
         {:ok, released} <- Arca.FileOffers.sweep_custody(actor, dry_run) do
      {:ok, completed + failed + deleted + released}
    end
  end

  def prune(%Prima.Actor{}, _days, _dry_run), do: {:error, :no_athanor}

  defp resume(_actor, true), do: {:ok, 0}

  defp resume(actor, false) do
    with {:ok, received} <- Arca.FileOffers.receipts(actor, status: "received"),
         {:ok, published} <- Arca.FileOffers.receipts(actor, status: "published") do
      completed =
        Enum.count(received ++ published, fn receipt ->
          match?({:ok, %{status: "completed"}}, Arca.FileOffers.complete(actor, receipt.id))
        end)

      {:ok, completed}
    end
  end
end
