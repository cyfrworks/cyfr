# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.CellLease do
  @moduledoc """
  One member of the cell: the node holding a slot, the boot holding it now,
  and the generation everything that member issues is stamped with.

  The slot is keyed by the node's distribution name, not by a boot. A
  restarted node takes its own slot over rather than opening a second one,
  and the row survives a release so a returning node's generation carries
  on from its predecessor's instead of starting again at one.

  `generation` is the member's, never the cell's: it rises when THIS slot
  is taken over and at no other time, so a member joining or leaving
  invalidates nothing a peer issued. `fence` is the row's write token,
  raised by every write, so a renew is a compare-and-set.

  Read through `Arca.ControlPlane` (cached, no query on the hot path) and
  written by the cell's claimant.
  """

  use Ecto.Schema

  @primary_key {:node, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "cell_leases" do
    field :owner, :string
    field :generation, :integer
    field :fence, :integer
    field :lease_until, :utc_datetime_usec
    field :taken_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
