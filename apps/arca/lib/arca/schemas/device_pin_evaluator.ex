# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.DevicePinEvaluator do
  @moduledoc """
  Ecto schema for the `device_pin_evaluators` table (backs
  `Arca.DevicePinEvaluators`): the evaluator a home keeps for one paired
  client's six-digit PIN, its key sealed, and its count.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @derive {Inspect, except: [:sealed_key, :identifier_digest, :reset_nonce]}
  schema "device_pin_evaluators" do
    field :athanor_id, :string
    field :user_id, :string
    field :paired_client_id, :string
    field :identifier_digest, :binary
    field :sealed_key, :binary
    field :attempts, :integer, default: 0
    field :revision, :integer, default: 0
    field :next_allowed_at, :integer
    field :reset_nonce, :binary
    field :reset_expires_at, :integer
    field :confirmed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
