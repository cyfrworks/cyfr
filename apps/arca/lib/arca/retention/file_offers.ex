# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.FileOffers do
  @moduledoc """
  A file offer's lifetime and the snapshots it leaves (`Arca.FileOffers`).

  The value is how many days an offer stands: an offer is made with the
  expiry its sender's athanor names then (`Arca.FileOffers.offer/3`), at
  most `max_days/0` from now, and this sweep ends every offer of the
  athanor past its expiry, `offered` →
  `expired`, releasing each snapshot once. It then releases the snapshot
  of every offer that ended without its snapshot going (a release that
  failed after its status write), and the snapshots no offer row names
  once they are older than a day by the store's own clock (a crash
  between the copy and the rows). The offer rows stay as the record of
  who offered what to whom; a `payloads/offers/` snapshot is never the
  staging sweep's.
  """
  @behaviour Arca.Retention.Kind

  alias Arca.Retention.Kind

  @impl true
  def key, do: "file_offer_days"

  @impl true
  def default, do: Kind.configured(:file_offer_days, 7)

  @impl true
  def unit, do: :days

  @doc """
  The longest an offer stands, in days, whatever the athanor's value: a
  hundred years. The expiry is a stored timestamp: a value of a few
  million days names a year past 9999, which SQLite stores but cannot
  read back, and one above about a hundred million names a year
  PostgreSQL refuses to write. The setting itself is kept as the athanor
  gave it.
  """
  @spec max_days() :: pos_integer()
  def max_days, do: 36_500

  @impl true
  def prune(%Prima.Actor{athanor_id: athanor} = actor, days, dry_run)
      when is_binary(athanor) and athanor != "" and is_integer(days) and days > 0 and
             is_boolean(dry_run) do
    with {:ok, expired} <- Arca.FileOffers.expire(actor, dry_run: dry_run),
         {:ok, released} <- Arca.FileOffers.sweep_snapshots(actor, dry_run) do
      {:ok, expired + released}
    end
  end

  def prune(%Prima.Actor{}, _days, _dry_run), do: {:error, :no_athanor}
end
