# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.Turns do
  use Ecto.Migration

  # The durable shape of a turn, as bookkeeping: `turns` own accepted work
  # and its state; `turn_steps` own orchestration state and REFERENCE
  # content by message and execution id, never duplicating it;
  # `approvals` own a decision, which the corresponding message row
  # references; `execution_events` own the live stream's lifecycle and
  # step outcomes. Every table carries `athanor_id NOT NULL`, and a child
  # names its parent together with the athanor, so nothing here can point
  # across estates. The runner writes `turns` rows at accept, complete,
  # fail and cancel; the other tables wait for the loop that will own
  # them. `messages.kind` grows `tool_call`, `tool_result` and
  # `turn_aborted` beside `text`, `approval`, `error` and `system`.
  def change do
    # A parent row is named with its athanor.
    create unique_index(:conversations, [:id, :athanor_id])

    create table(:turns, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :conversation_id,
          references(:conversations,
            type: :string,
            on_delete: :delete_all,
            with: [athanor_id: :athanor_id]
          ),
          null: false

      # The execution running the turn (the AQUA root), once accepted.
      add :execution_id, :string
      add :orchestrator, :string
      add :requested_by, :string
      # accepted | completed | failed | cancelled
      add :status, :string, null: false
      add :error, :text
      add :accepted_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
    end

    create unique_index(:turns, [:id, :athanor_id])
    create index(:turns, [:athanor_id, :conversation_id, :accepted_at])
    create unique_index(:turns, [:execution_id], where: "execution_id IS NOT NULL")

    create table(:turn_steps, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :turn_id,
          references(:turns,
            type: :string,
            on_delete: :delete_all,
            with: [athanor_id: :athanor_id]
          ),
          null: false

      add :seq, :integer, null: false
      # model | tool | approval | clone
      add :kind, :string, null: false
      add :idempotency_key, :string
      add :tool, :string
      add :action, :string
      # proposed | dispatched | closed | uncertain
      add :dispatch_state, :string, null: false, default: "proposed"
      add :message_id, :string
      add :execution_id, :string
      add :approval_id, :string
      add :authority_digest, :string
      # ok | error | denied | skipped
      add :outcome, :string
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
    end

    create unique_index(:turn_steps, [:turn_id, :seq])
    create unique_index(:turn_steps, [:id, :athanor_id])
    create index(:turn_steps, [:athanor_id, :turn_id])

    create table(:approvals, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :turn_id,
          references(:turns,
            type: :string,
            on_delete: :delete_all,
            with: [athanor_id: :athanor_id]
          ),
          null: false

      add :step_id, :string
      add :message_id, :string
      # pending | approved | declined | expired | error
      add :status, :string, null: false
      add :scope, :string
      add :decided_by, :string
      add :decided_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      add :resolution, :text
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:approvals, [:id, :athanor_id])
    create index(:approvals, [:athanor_id, :status])
    create index(:approvals, [:athanor_id, :turn_id])

    create table(:execution_events, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      add :execution_id, :string, null: false
      add :turn_id, :string
      add :step_id, :string
      add :seq, :integer, null: false
      add :type, :string, null: false
      add :data, :text
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:execution_events, [:execution_id, :seq])
    create index(:execution_events, [:athanor_id, :turn_id])

    alter table(:executions) do
      # The turn an execution belongs to, and the schedule that fired it.
      add :turn_id, :string
      add :schedule_id, :string
    end

    create index(:executions, [:turn_id])
    create index(:executions, [:schedule_id])
  end
end
