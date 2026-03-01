defmodule Arca.Repo.Migrations.DropAuditEvents do
  use Ecto.Migration

  def up do
    drop_if_exists table(:audit_events)
  end

  def down do
    create table(:audit_events, primary_key: false) do
      add :id, :string, primary_key: true
      add :request_id, :string
      add :session_id, :string
      add :user_id, :string
      add :timestamp, :utc_datetime
      add :event_type, :string
      add :data, :text
    end

    create index(:audit_events, [:user_id])
    create index(:audit_events, [:event_type])
    create index(:audit_events, [:timestamp])
    create index(:audit_events, [:request_id])
  end
end
