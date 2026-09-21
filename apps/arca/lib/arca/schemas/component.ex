# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Component do
  @moduledoc """
  Ecto schema for the `components` table (backs `Arca.ComponentStorage`).

  `inserted_at` and `updated_at` use `:utc_datetime_usec`, returning
  `DateTime` values on both adapters.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "components" do
    field :name, :string
    field :version, :string
    field :component_type, :string
    field :description, :string
    field :tags, :string
    field :category, :string
    field :license, :string
    field :digest, :string
    field :release_digest, :string
    field :size, :integer
    field :exports, :string
    field :manifest, :string
    field :publisher, :string
    field :publisher_id, :string
    field :source, :string
    field :signature_verified, :boolean
    field :signer_identity, :string
    field :signer_issuer, :string
    field :athanor_id, :string
    timestamps(type: :utc_datetime_usec)
  end
end
