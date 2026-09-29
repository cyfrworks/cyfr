# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.InstallationClaim do
  @moduledoc """
  Ecto schema for the `installation_claims` table (backs
  `Arca.InstallationClaims`): a claim a restore makes of an empty node,
  one per installation token ever claimed, `pending` until the attempt it
  bound ends. At most one is pending.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "installation_claims" do
    field :token_digest, :string
    field :request_id, :string
    field :identifier, :string
    field :state, :string
    field :outcome, :string
    field :claimed_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
