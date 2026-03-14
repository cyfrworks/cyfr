defmodule Arca.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false) do
      add :id, :string, primary_key: true
      add :token_hash, :binary, null: false
      add :token_prefix, :string
      add :user_id, :string, null: false
      add :email, :string
      add :provider, :string, null: false
      add :permissions, :text, null: false, default: "[]"
      add :session_id, :string
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:sessions, [:token_hash])

    create table(:revoked_sessions, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_id, :string, null: false
      add :revoked_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:revoked_sessions, [:session_id])
  end
end
