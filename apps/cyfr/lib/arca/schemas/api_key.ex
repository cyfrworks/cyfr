# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ApiKey do
  @moduledoc """
  Ecto schema for the `api_keys` table (backs `Arca.ApiKeyStorage`).
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "api_keys" do
    field :name, :string
    field :key_hash, :binary
    field :key_prefix, :string
    field :type, :string
    field :scope, :string
    field :rate_limit, :string
    field :ip_allowlist, :string
    field :revoked, :boolean
    field :created_by, :string
    field :rotated_at, :utc_datetime_usec
    field :scope_type, :string
    field :org_id, :string
    field :project_id, :string
    timestamps(type: :utc_datetime_usec)
  end
end
