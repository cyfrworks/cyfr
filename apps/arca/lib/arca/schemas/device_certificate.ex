# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.DeviceCertificate do
  @moduledoc """
  Ecto schema for the `device_certificates` table (backs
  `Arca.DeviceCertificates`): one certificate this home issued to a paired
  client of an athanor, with its signed bytes and digest.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @subject_kinds ~w(local identity)
  @states ~w(active revoked)

  @doc "The kinds of certificate subject."
  @spec subject_kinds() :: [String.t()]
  def subject_kinds, do: @subject_kinds

  @doc "The stored states; `expired` is read from the clock, never stored."
  @spec states() :: [String.t()]
  def states, do: @states

  schema "device_certificates" do
    field :athanor_id, :string
    field :paired_client_id, :string
    field :user_id, :string
    field :subject_kind, :string
    field :identifier, :string
    field :key_epoch, :string
    field :device_public_key, :binary
    field :issuing_home, :string
    field :audience_home, :string
    field :not_before, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :certificate, :binary
    field :digest, :string
    field :state, :string, default: "active"
    field :revoked_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
