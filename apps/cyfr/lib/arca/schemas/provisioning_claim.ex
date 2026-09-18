# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ProvisioningClaim do
  @moduledoc """
  Ecto schema for the `provisioning_claims` table: who is filling an
  estate.

  One row per athanor — every entry point that fills or heals an estate
  shares it, as every fill shares one lock today. A claim is taken and
  settled by compare-and-set on `(owner, fence)`: `owner` is the boot
  holding it, `attempt` the attempt run under it, `fence` the fencing
  token (1 on the first claim, raised by one on every take) and
  `lease_until` how long the take stands. A mark from a boot that no
  longer holds the claim, or under a fence a later take raised past,
  never lands — so a stale owner cannot mark readiness, overwrite a
  successor's failure, mint consent or replace the agent index.

  `entry_kind` names the entry point of `Sanctum.Provisioning` the
  attempt came through:

    * `sign_in` — the personal fill and group retries of `after_sign_in/1`.
    * `first_need` — `start_provisioning/1` and `ready/1` on an unfilled
      estate.
    * `provision` — the explicit `provision/2` behind `athanor.provision`.
    * `install_shipped` — `install_shipped/2`, one shipped version copied
      in.
    * `seed_sync` — `sync_seeds/0` at boot, healing a filled estate.

  `outcome` is nil while the attempt holds the claim and settles to
  `ready` (the estate is filled), `failed` (the attempt recorded a
  failure; `outcome_detail` says where) or `released` (the attempt ended
  with no verdict on readiness — a sync or an install on an estate that
  was already filled). Owned by the athanor.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @entry_kinds ~w(sign_in first_need provision install_shipped seed_sync)
  @outcomes ~w(ready failed released)

  schema "provisioning_claims" do
    field :athanor_id, :string
    field :owner, :string
    field :attempt, :string
    field :entry_kind, :string
    field :lease_until, :utc_datetime_usec
    field :fence, :integer
    field :outcome, :string
    field :outcome_detail, :string
    timestamps(type: :utc_datetime_usec)
  end

  @doc "The entry points a claim is taken through, as `entry_kind` spells them."
  @spec entry_kinds() :: [String.t()]
  def entry_kinds, do: @entry_kinds

  @doc "What a settled claim records as its `outcome`."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @fields [
    :id,
    :athanor_id,
    :owner,
    :attempt,
    :entry_kind,
    :lease_until,
    :fence,
    :outcome,
    :outcome_detail
  ]

  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required([:id, :athanor_id, :owner, :attempt, :entry_kind, :lease_until, :fence])
    |> validate_inclusion(:entry_kind, @entry_kinds)
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_number(:fence, greater_than: 0)
    |> unique_constraint(:athanor_id)
  end
end
