# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.SecretGrant do
  @moduledoc """
  Ecto schema for the `secret_grants` table (backs `Arca.SecretStorage`).
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "secret_grants" do
    field :secret_name, :string
    field :component_ref, :string
    field :scope, :string
    field :org_id, :string
    field :project_id, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
