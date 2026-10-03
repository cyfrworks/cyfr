# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.IdentityAttempt do
  @moduledoc """
  Ecto schema for the `identity_attempts` table (backs
  `Arca.IdentityAttempts`): one enrollment, added-kit (`holder`), restore
  or rotation attempt, keyed by its request id, with the immutable
  submission it makes, the sealed material it stages and the phase it has
  reached.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @kinds ~w(enrollment holder restore rotation)
  @phases ~w(staged submitted accepted refused superseded keys_active minted completed)

  @doc "The kinds of attempt."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The closed phase list."
  @spec phases() :: [String.t()]
  def phases, do: @phases

  schema "identity_attempts" do
    field :kind, :string
    field :request_id, :string
    field :user_id, :string
    field :identifier, :string
    field :directory_url, :string
    field :phase, :string
    field :genesis, :binary
    field :entry, :binary
    field :entry_hash, :string
    field :expected_head, :string
    field :expected_revision, :integer
    field :request_digest, :string
    field :token_digest, :string
    field :staged_live_public_key, :binary
    field :staged_operational_public_key, :binary
    field :staged_live_key_sealed, :binary, redact: true
    field :staged_operational_key_sealed, :binary, redact: true
    field :kit_seed_sealed, :binary, redact: true
    field :kit_acknowledged_at, :utc_datetime_usec
    field :outcome, :string
    field :reproof_challenge_digest, :string
    field :reproof_expires_at, :utc_datetime_usec
    field :revision, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end
end
