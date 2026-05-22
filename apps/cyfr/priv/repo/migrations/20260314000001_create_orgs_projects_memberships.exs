# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.CreateOrgsProjectsMemberships do
  use Ecto.Migration

  def change do
    create table(:orgs, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :plan, :string, null: false, default: "free"
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:orgs, [:slug])

    create table(:projects, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, references(:orgs, type: :string, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :settings, :string
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:projects, [:org_id, :slug])

    create table(:memberships, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string, null: false
      add :org_id, references(:orgs, type: :string, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "member"
      add :invited_at, :utc_datetime_usec
      add :accepted_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:memberships, [:user_id, :org_id])
  end
end
