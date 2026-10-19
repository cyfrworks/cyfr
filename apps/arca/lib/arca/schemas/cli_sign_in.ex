# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.CliSignIn do
  @moduledoc """
  Ecto schema for the `cli_sign_ins` table (backs `Arca.CliSignIns`): a
  command line waiting to be approved in Prism, by the hashes of its two
  secrets, the code both sides show, the machine it names, its state and
  its expiry.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @states ~w(pending approved cancelled)

  @doc "The states a pending sign-in may hold; `approved` and `cancelled` are terminal."
  @spec states() :: [String.t()]
  def states, do: @states

  schema "cli_sign_ins" do
    field :approval_hash, :binary
    field :token_hash, :binary
    field :token_prefix, :string
    field :user_code, :string
    field :machine, :string
    field :state, :string, default: "pending"
    field :expires_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
