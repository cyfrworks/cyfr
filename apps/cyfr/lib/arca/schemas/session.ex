# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Session do
  @moduledoc """
  Ecto schema for the `sessions` table (backs `Arca.SessionStorage`).
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "sessions" do
    field :token_hash, :binary
    field :token_prefix, :string
    field :user_id, :string
    field :email, :string
    field :provider, :string
    field :permissions, :string
    field :expires_at, :utc_datetime_usec
    field :org_id, :string
    field :project_id, :string
    field :scope, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
