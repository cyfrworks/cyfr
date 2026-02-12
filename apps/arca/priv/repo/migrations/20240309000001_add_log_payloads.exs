defmodule Arca.Repo.Migrations.AddLogPayloads do
  use Ecto.Migration

  def change do
    # MCP logs: store full request/response payloads inline
    alter table(:mcp_logs) do
      add :input, :text
      add :output, :text
      add :error, :text
    end

    # Executions: store full input/output/trace inline
    alter table(:executions) do
      add :input, :text
      add :output, :text
      add :wasi_trace, :text
      add :host_policy, :text
    end

    # Policy logs: store full policy snapshot and decision reason
    alter table(:policy_logs) do
      add :host_policy_snapshot, :text
      add :decision_reason, :text
    end

    # Audit events: store full event data inline
    alter table(:audit_events) do
      add :data, :text
    end
  end
end
