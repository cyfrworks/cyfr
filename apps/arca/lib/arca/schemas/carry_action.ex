# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.CarryAction do
  @moduledoc """
  Ecto schema for the `carry_actions` table (backs `Arca.CarryActions`): a
  sign-in carry's `source` action at the person's signing home, or a
  relying home's `login_receipt` of an accepted assertion.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @kinds ~w(source login_receipt)
  @phases ~w(pending delivered completed cancelled expired)

  @doc "The kinds of carry row."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The phases a carry action moves through."
  @spec phases() :: [String.t()]
  def phases, do: @phases

  schema "carry_actions" do
    field :kind, :string
    field :action_id, :string
    field :user_id, :string
    field :source_home, :string
    field :destination_home, :string
    field :return_url, :string
    field :operation, :string, default: "join"
    field :payload, :binary
    field :payload_digest, :string
    field :key_epoch, :string
    field :challenge, :string
    field :challenge_digest, :string
    field :challenge_id, :string
    field :assertion, :binary
    field :assertion_digest, :string
    field :browser_binding_digest, :string
    field :phase, :string
    field :outcome, :string
    field :outcome_body, :string
    field :revision, :integer, default: 1
    field :expires_at, :utc_datetime_usec
    field :retain_until, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
