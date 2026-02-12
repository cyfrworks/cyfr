defmodule Arca.Repo.Migrations.CreateLogTables do
  use Ecto.Migration

  def change do
    # MCP request log index table
    # Full payloads stored in files at mcp_logs/{request_id}.json
    create table(:mcp_logs, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_id, :string
      add :user_id, :string
      add :timestamp, :utc_datetime_usec, null: false
      add :tool, :string
      add :action, :string
      add :method, :string
      add :status, :string, null: false, default: "pending"
      add :duration_ms, :integer
      add :routed_to, :string
      add :error_code, :integer
    end

    create index(:mcp_logs, [:session_id])
    create index(:mcp_logs, [:user_id])
    create index(:mcp_logs, [:timestamp])
    create index(:mcp_logs, [:status])

    # Policy log index table
    # Full payloads stored in files at users/{user_id}/policy_logs/{request_id}.json
    create table(:policy_logs, primary_key: false) do
      add :id, :string, primary_key: true
      add :request_id, :string
      add :execution_id, :string
      add :session_id, :string
      add :user_id, :string, null: false
      add :timestamp, :utc_datetime_usec, null: false
      add :event_type, :string, null: false
      add :component_ref, :string
      add :component_type, :string
      add :decision, :string
    end

    create index(:policy_logs, [:request_id])
    create index(:policy_logs, [:execution_id])
    create index(:policy_logs, [:user_id])
    create index(:policy_logs, [:timestamp])

    # Audit event index table
    # Full payloads stored in files at users/{user_id}/audit/{date}.jsonl
    create table(:audit_events, primary_key: false) do
      add :id, :string, primary_key: true
      add :request_id, :string
      add :session_id, :string
      add :user_id, :string, null: false
      add :timestamp, :utc_datetime_usec, null: false
      add :event_type, :string, null: false
    end

    create index(:audit_events, [:request_id])
    create index(:audit_events, [:user_id])
    create index(:audit_events, [:timestamp])
    create index(:audit_events, [:event_type])
  end
end
