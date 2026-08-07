# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.CreateOauthProviderCredentials do
  use Ecto.Migration

  # OAuth provider client id/secret pairs (the operator's OAuth app at
  # Google/GitHub/...), sealed as one blob per (tenant, provider). These were
  # previously ordinary rows in `secrets` read under the executing caller's
  # context — which let any execute-permission context read the client
  # secret. This store is read by the token-exchange/refresh plane only,
  # never through a caller's permission set.
  def change do
    create table(:oauth_provider_credentials, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
      add :provider, :string, null: false
      add :payload_ciphertext, :binary, null: false
      add :created_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:oauth_provider_credentials, [:provider, :org_id, :project_id])
  end
end
