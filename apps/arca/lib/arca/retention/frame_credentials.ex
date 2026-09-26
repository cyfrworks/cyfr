# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.FrameCredentials do
  @moduledoc """
  The rows of discarded frames older than N days go
  (`Arca.FrameCredentials`): a frame's credential row is revoked when its
  frame is discarded or a standing transition retires it, and is kept
  after that only as the record that it was.

  An active or suspended row is left whatever its age: it is the standing
  of a bearer a frame may still hold, and its own deadline ends it. The
  age is counted from the revocation (`updated_at`), not from the mint.
  """
  @behaviour Arca.Retention.Kind

  alias Arca.Retention.Kind

  @impl true
  def key, do: "frame_credential_days"

  @impl true
  def default, do: Kind.configured(:frame_credential_days, 7)

  @impl true
  def unit, do: :days

  @impl true
  def prune(%Prima.Actor{athanor_id: athanor}, days, dry_run)
      when is_binary(athanor) and athanor != "" and is_integer(days) and days > 0 do
    cutoff = Kind.days_cutoff(days)
    opts = [athanor_id: athanor]

    if dry_run,
      do: Arca.FrameCredentials.count_revoked_before(cutoff, opts),
      else: Arca.FrameCredentials.delete_revoked_before(cutoff, opts)
  end

  def prune(%Prima.Actor{}, _days, _dry_run), do: {:error, :no_athanor}
end
