# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Passkey do
  @moduledoc """
  Ecto schema for the `passkeys` table (backs `Arca.Passkeys`): one WebAuthn
  credential of a person at this relying home, pinned to its RP ID, and its
  standing: `pending`, `active` or `revoked`.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @states ~w(pending active revoked)

  @doc "The standings a passkey may hold; `revoked` is terminal."
  @spec states() :: [String.t()]
  def states, do: @states

  schema "passkeys" do
    field :user_id, :string
    field :credential_id, :string
    field :rp_id, :string
    field :relying_home, :string
    field :public_key, :binary
    field :sign_count, :integer, default: 0
    field :identity_recovery_epoch, :string
    field :state, :string
    field :registration_digest, :string
    field :possession_verified, :boolean, default: false
    field :expires_at, :utc_datetime_usec
    field :admin_confirmation_id, :string
    field :label, :string
    field :activated_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
