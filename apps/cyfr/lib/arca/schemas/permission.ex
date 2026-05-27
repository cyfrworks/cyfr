# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Permission do
  @moduledoc """
  Ecto schema for the `permissions` table (backs `Arca.PermissionStorage`).
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "permissions" do
    field :subject, :string
    field :permissions, :string
    field :scope_type, :string
    field :org_id, :string
    field :project_id, :string
    timestamps(type: :utc_datetime_usec)
  end
end
