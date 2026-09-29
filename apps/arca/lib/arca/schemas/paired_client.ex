# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.PairedClient do
  @moduledoc """
  Ecto schema for the `paired_clients` table (backs `Arca.PairedClients`):
  one client a person holds in an athanor, the credential it stands on, a
  paired device's public key, and its standing, which alone decides what
  it may do.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @standings ~w(active revoked)
  @source_kinds ~w(session api_key device_cert)

  @doc "The standings a paired client may hold; `revoked` is terminal."
  @spec standings() :: [String.t()]
  def standings, do: @standings

  @doc """
  The credentials a paired client may stand on: a session, an API key, or
  a device certificate, whose client carries the device's public key.
  """
  @spec source_kinds() :: [String.t()]
  def source_kinds, do: @source_kinds

  schema "paired_clients" do
    field :athanor_id, :string
    field :user_id, :string
    field :source_kind, :string
    field :source_id, :string
    field :device_public_key, :binary
    field :standing, :string, default: "active"
    field :label, :string
    timestamps(type: :utc_datetime_usec)
  end
end
