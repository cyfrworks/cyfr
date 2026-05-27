# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Secret do
  @moduledoc """
  Ecto schema for the `secrets` table (backs `Arca.SecretStorage`).
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "secrets" do
    field :name, :string
    field :encrypted_value, :binary
    field :scope, :string
    field :org_id, :string
    field :project_id, :string
    timestamps(type: :utc_datetime_usec)
  end
end
