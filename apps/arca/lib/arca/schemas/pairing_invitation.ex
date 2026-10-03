# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.PairingInvitation do
  @moduledoc """
  Ecto schema for the `pairing_invitations` table (backs
  `Arca.PairingInvitations`): one bearer invitation to pair a device into
  an athanor, stored by the hash of its secret.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @states ~w(pending consumed revoked)

  @doc "The states an invitation moves through; the last two are terminal."
  @spec states() :: [String.t()]
  def states, do: @states

  schema "pairing_invitations" do
    field :athanor_id, :string
    field :secret_hash, :string
    field :user_id, :string
    field :membership_id, :string
    field :prospective_client_id, :string
    field :audience_home, :string
    field :expires_at, :utc_datetime_usec
    field :state, :string, default: "pending"
    field :consumed_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
