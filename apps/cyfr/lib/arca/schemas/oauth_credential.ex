# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.OauthCredential do
  @moduledoc """
  Ecto schema for the `oauth_credentials` table (backs `Arca.OAuthStorage`).
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "oauth_credentials" do
    field :provider, :string
    field :component_ref, :string
    field :encrypted_data, :binary
    field :org_id, :string
    field :project_id, :string
    timestamps(type: :utc_datetime_usec)
  end
end
