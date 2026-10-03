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
    3. the custody copy of every `completed` or `failed` receipt still
       holding one is released, and copies no receipt row names are
       released once older than a day by the store's own clock.

  Nothing here touches a published destination. Answers how many receipts
  completed or failed and how many copies were released (or, on a dry
  run, how many receipts would fail and copies would go).
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
    with {:ok, completed} <- resume(actor, dry_run),
         {:ok, failed} <- Arca.FileOffers.fail_stale(actor, Kind.days_cutoff(days), dry_run),
         {:ok, released} <- Arca.FileOffers.sweep_custody(actor, dry_run) do
      {:ok, completed + failed + released}
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
