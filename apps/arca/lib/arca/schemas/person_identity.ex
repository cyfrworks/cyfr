# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.PersonIdentity do
  @moduledoc """
  Ecto schema for the `person_identities` table (backs
  `Arca.PersonIdentities`): one row per person this home knows, beside
  their `users` row: the account they were admitted by, its identifier,
  its directory and the head this home last read. `provenance` is
  `remote` and `enrollment` `enrolled` on every row this home writes.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @provenances ~w(local remote)
  @enrollments ~w(none pending enrolled)

  @doc "Where a person's keys are held."
  @spec provenances() :: [String.t()]
  def provenances, do: @provenances

  @doc "The enrollment states a row moves through."
  @spec enrollments() :: [String.t()]
  def enrollments, do: @enrollments

  schema "person_identities" do
    field :user_id, :string
    field :identifier, :string
    field :provenance, :string
    field :enrollment, :string, default: "none"
    field :head_hash, :string
    field :directory_url, :string
    field :first_method_at, :utc_datetime_usec
    field :revision, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end
end
