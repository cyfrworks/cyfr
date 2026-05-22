# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.CreateWebhooks do
  use Ecto.Migration

  def change do
    create table(:webhooks, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :target_ref, :string, null: false
      add :secret_encrypted, :binary, null: false
      add :signature_header, :string, null: false, default: "x-cyfr-signature"
      add :input_template, :text, null: false, default: "{}"
      add :description, :string
      add :enabled, :boolean, null: false, default: true
      add :rate_limit, :string
      add :created_by, :string
      add :rotated_at, :utc_datetime_usec
      add :scope_type, :string, null: false, default: "project"
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:webhooks, [:slug])
    create unique_index(:webhooks, [:name, :scope_type, :org_id, :project_id])
  end
end
