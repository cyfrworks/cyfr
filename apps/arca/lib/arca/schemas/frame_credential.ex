# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.FrameCredential do
  @moduledoc """
  Ecto schema for the `frame_credentials` table (backs
  `Arca.FrameCredentials`): one frame a shell opened, the standing of the
  bearer it holds.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @states ~w(active suspended revoked)
  @source_kinds ~w(session api_key)

  @doc "The states a frame credential may be in; `revoked` is terminal."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "What a frame credential may be minted under."
  @spec source_kinds() :: [String.t()]
  def source_kinds, do: @source_kinds

  schema "frame_credentials" do
    field :athanor_id, :string
    field :user_id, :string
    field :publisher, :string
    field :name, :string
    field :version, :string
    field :version_digest, :string
    field :grant_revision, :integer
    field :frame_id, :string
    field :source_kind, :string
    field :source_id, :string
    field :state, :string, default: "active"
    field :deadline, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
