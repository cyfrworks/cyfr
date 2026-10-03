# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.PersonIdentity do
  @moduledoc """
  Ecto schema for the `person_identities` table (backs
  `Arca.PersonIdentities`): one row per person this home knows, beside
  their `users` row.

  `provenance` is `local` (this home holds the person's keys) or `remote`
  (another home does, and admitted them through the CYFR door); it is a
  fact on the row and never read from the door a person last used.
  `enrollment` is `none`, `pending` (an enrollment attempt is open) or
  `enrolled` (the row carries the identifier). The private halves of the
  live and operational keys are sealed bytes Arca never opens.
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
    field :live_public_key, :binary
    field :operational_public_key, :binary
    field :live_key_sealed, :binary, redact: true
    field :operational_key_sealed, :binary, redact: true
    field :genesis_hash, :string
    field :head_hash, :string
    field :directory_url, :string
    field :first_method_at, :utc_datetime_usec
    field :revision, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end
end
