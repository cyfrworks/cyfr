# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.PairedClient do
  @moduledoc """
  Ecto schema for the `paired_clients` table (backs `Arca.PairedClients`):
  one client a person holds in an athanor, the confirmation class it was
  assigned, the credential it stands on and its standing.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @standings ~w(active revoked)
  @source_kinds ~w(session api_key)

  @doc "The standings a paired client may hold; `revoked` is terminal."
  @spec standings() :: [String.t()]
  def standings, do: @standings

  @doc "The credentials a paired client may stand on."
  @spec source_kinds() :: [String.t()]
  def source_kinds, do: @source_kinds

  schema "paired_clients" do
    field :athanor_id, :string
    field :user_id, :string
    field :class, :string
    field :source_kind, :string
    field :source_id, :string
    field :standing, :string, default: "active"
    field :label, :string
    timestamps(type: :utc_datetime_usec)
  end
end
