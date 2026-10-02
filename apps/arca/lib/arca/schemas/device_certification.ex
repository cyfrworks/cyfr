# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.DeviceCertification do
  @moduledoc """
  Ecto schema for the `device_certifications` table (backs
  `Arca.DeviceCertifications`): what this home certified for one of its
  people's devices at another home.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @states ~w(active revoked)

  @doc "The stored states."
  @spec states() :: [String.t()]
  def states, do: @states

  schema "device_certifications" do
    field :user_id, :string
    field :identifier, :string
    field :key_epoch, :string
    field :client_id, :string
    field :device_public_key, :binary
    field :audience_home, :string
    field :audience_athanor, :string
    field :expires_at, :utc_datetime_usec
    field :state, :string, default: "active"
    field :revision, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end
end
