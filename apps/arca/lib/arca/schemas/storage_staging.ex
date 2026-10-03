# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.StorageStaging do
  @moduledoc """
  Ecto schema for the `storage_staging` table: one row per staging
  attempt of `Arca.Storage.stage/3`, written before its bytes.

  `state` is `reserved` while the bytes may still be published (until
  `expires_at`, database time), `published` once a fenced publication
  (`Arca.FencedPublication`) references them, and `deleting` once the
  sweep (`Arca.Retention.FencedStaging`) has claimed an expired
  reservation and is removing its bytes.

  Owned by the athanor.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @states ~w(reserved published deleting)

  schema "storage_staging" do
    field :athanor_id, :string
    field :attempt, :string
    field :key, :string
    field :digest, :string
    field :state, :string
    field :expires_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @doc "The states a staging row moves through."
  @spec states() :: [String.t()]
  def states, do: @states
end
