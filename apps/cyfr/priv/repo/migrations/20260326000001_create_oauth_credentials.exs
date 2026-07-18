# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.CreateOauthCredentials do
  use Ecto.Migration

  def up do
    create table(:oauth_credentials, primary_key: false) do
      add :id, :string, primary_key: true
      # "google", "microsoft", etc. — matches manifest oauth block key
      add :provider, :string, null: false
      # "" for provider credentials, "catalyst:local.gmail:0.1.0" for component tokens
      add :component_ref, :string, null: false, default: ""

      # AES-256-GCM encrypted JSON blob (client_id/secret for providers, token bundle for components)
      add :encrypted_data, :binary, null: false
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
      timestamps()
    end

    create unique_index(:oauth_credentials, [:provider, :component_ref, :org_id, :project_id])
    create index(:oauth_credentials, [:component_ref, :org_id, :project_id])
    create index(:oauth_credentials, [:org_id, :project_id])
  end

  def down do
    drop_if_exists index(:oauth_credentials, [:org_id, :project_id])
    drop_if_exists index(:oauth_credentials, [:component_ref, :org_id, :project_id])

    drop_if_exists unique_index(:oauth_credentials, [
                     :provider,
                     :component_ref,
                     :org_id,
                     :project_id
                   ])

    drop_if_exists table(:oauth_credentials)
  end
end
