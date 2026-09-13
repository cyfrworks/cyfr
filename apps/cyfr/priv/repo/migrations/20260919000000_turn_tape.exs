# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.TurnTape do
  use Ecto.Migration

  # The durable shape of a turn the host loop writes: a turn pins its
  # actor, consent and agent revision, owns a logical root execution and
  # its attempt, and reads the transcript behind a consumption boundary;
  # a step carries its dispatch generation and cancel mark; an approval
  # names the proposal it consumed; a message names its turn and the
  # sender's retry identity. Executions gain a kind, the current-attempt
  # pointer and the durable event counter; `execution_attempts` is the
  # fence, backfilled from the lease columns, which stay until the engine
  # is rekeyed. Budget reservations and their charges are rows.
  #
  # Columns added by `alter` carry no composite reference: SQLite cannot
  # add a table constraint through ALTER, and the tenant seam holds every
  # query to `athanor_id`. The new tables reference `executions` by
  # `(id, athanor_id)`.
  def up do
    alter table(:turns) do
      add :parent_turn_id, :string
      add :message_id, :string
      add :root_execution_id, :string
      add :attempt, :string
      add :runner_id, :string
      add :fence, :string, null: false, default: ""
      add :recovery_attempts, :integer, null: false, default: 0
      add :profile_id, :string
      add :consent_id, :string
      add :agent_revision_digest, :string
      add :agent_capability_digest, :string
      add :budget_id, :string
      add :model, :string
      add :options, :text
      add :window_upto_seq, :integer
      add :active_ms, :integer, null: false, default: 0
      add :paused_at, :utc_datetime_usec
      # approval | launch
      add :paused_reason, :string
      add :launch_step_id, :string
    end

    create unique_index(:turns, [:conversation_id, :message_id], where: "message_id IS NOT NULL")

    create unique_index(:turns, [:root_execution_id],
             where: "root_execution_id IS NOT NULL AND parent_turn_id IS NULL"
           )

    create index(:turns, [:athanor_id, :status])
    create index(:turns, [:athanor_id, :parent_turn_id])

    alter table(:turn_steps) do
      add :result_message_id, :string
      add :proposal_digest, :string
      add :request_digest, :string
      add :usage, :text
      add :excluded, :text
      # nil | replay_safe
      add :recovery, :string
      add :generation, :integer, null: false, default: 0
      add :cancel_requested_at, :utc_datetime_usec
      add :child_execution_id, :string
      add :error, :text
    end

    create index(:turn_steps, [:athanor_id, :dispatch_state])

    alter table(:approvals) do
      add :proposal_digest, :string, null: false, default: ""
      # continue | launch | denied | expired
      add :resolution_kind, :string
      add :launch_execution_id, :string
      add :conversation_id, :string
    end

    create index(:approvals, [:athanor_id, :conversation_id, :status])
    create index(:approvals, [:athanor_id, :status, :expires_at])

    alter table(:messages) do
      add :turn_id, :string
      add :approval_id, :string
      add :client_id, :string
    end

    create unique_index(:messages, [:conversation_id, :client_id], where: "client_id IS NOT NULL")
    create index(:messages, [:athanor_id, :turn_id])

    alter table(:executions) do
      # component | turn | tool_call
      add :kind, :string, null: false, default: "component"
      add :current_attempt, :string
      add :event_seq, :integer, null: false, default: 0
    end

    create index(:executions, [:athanor_id, :kind, :status])

    create table(:execution_attempts, primary_key: false) do
      add :attempt, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :execution_id,
          references(:executions,
            type: :string,
            on_delete: :delete_all,
            with: [athanor_id: :athanor_id]
          ),
          null: false

      add :fence, :integer, null: false
      add :runner_id, :string, null: false
      add :lease_until, :utc_datetime_usec, null: false
      # running | paused | completed | failed | cancelled | lapsed
      add :state, :string, null: false
      # ok | error | result_lost | cancelled | uncertain
      add :outcome, :string
      add :cancel_requested_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec, null: false
      add :running_since, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
    end

    create unique_index(:execution_attempts, [:execution_id, :fence])
    create index(:execution_attempts, [:athanor_id, :state, :lease_until])

    # Every existing row becomes its own first attempt, terminal rows with
    # the outcome their status records, and the pointer names it.
    execute """
    INSERT INTO execution_attempts
      (attempt, athanor_id, execution_id, fence, runner_id, lease_until, state, outcome,
       started_at, running_since, ended_at)
    SELECT
      COALESCE(attempt, 'att_legacy_' || id),
      athanor_id,
      id,
      1,
      COALESCE(runner_id, ''),
      COALESCE(lease_until, started_at),
      status,
      CASE status
        WHEN 'completed' THEN 'ok'
        WHEN 'failed' THEN 'error'
        WHEN 'cancelled' THEN 'cancelled'
        ELSE NULL
      END,
      started_at,
      CASE status WHEN 'running' THEN started_at ELSE NULL END,
      completed_at
    FROM executions
    """

    execute "UPDATE executions SET current_attempt = COALESCE(attempt, 'att_legacy_' || id)"

    create table(:budget_reservations, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :root_execution_id,
          references(:executions,
            type: :string,
            on_delete: :delete_all,
            with: [athanor_id: :athanor_id]
          ),
          null: false

      add :kind, :string, null: false, default: "invoke"
      add :cap, :integer, null: false
      add :charged, :integer, null: false, default: 0
      add :inserted_at, :utc_datetime_usec, null: false
      add :released_at, :utc_datetime_usec
    end

    create index(:budget_reservations, [:athanor_id, :root_execution_id])

    create table(:budget_charges, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :reservation_id,
          references(:budget_reservations, type: :string, on_delete: :delete_all),
          null: false

      add :attempt, :string, null: false
      add :generation, :integer, null: false, default: 0
      add :holder_execution_id, :string
      add :n, :integer, null: false
      add :runner_id, :string, null: false
      add :admit_by, :utc_datetime_usec
      add :admitted_at, :utc_datetime_usec
      add :holder_deadline, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:budget_charges, [:reservation_id, :id])
    create index(:budget_charges, [:athanor_id, :attempt])
    create index(:budget_charges, [:athanor_id, :holder_execution_id])
  end

  def down do
    drop table(:budget_charges)
    drop table(:budget_reservations)
    drop table(:execution_attempts)

    drop index(:executions, [:athanor_id, :kind, :status])

    alter table(:executions) do
      remove :kind
      remove :current_attempt
      remove :event_seq
    end

    drop index(:messages, [:athanor_id, :turn_id])
    drop index(:messages, [:conversation_id, :client_id])

    alter table(:messages) do
      remove :turn_id
      remove :approval_id
      remove :client_id
    end

    drop index(:approvals, [:athanor_id, :status, :expires_at])
    drop index(:approvals, [:athanor_id, :conversation_id, :status])

    alter table(:approvals) do
      remove :proposal_digest
      remove :resolution_kind
      remove :launch_execution_id
      remove :conversation_id
    end

    drop index(:turn_steps, [:athanor_id, :dispatch_state])

    alter table(:turn_steps) do
      remove :result_message_id
      remove :proposal_digest
      remove :request_digest
      remove :usage
      remove :excluded
      remove :recovery
      remove :generation
      remove :cancel_requested_at
      remove :child_execution_id
      remove :error
    end

    drop index(:turns, [:athanor_id, :parent_turn_id])
    drop index(:turns, [:athanor_id, :status])
    drop index(:turns, [:root_execution_id])
    drop index(:turns, [:conversation_id, :message_id])

    alter table(:turns) do
      remove :parent_turn_id
      remove :message_id
      remove :root_execution_id
      remove :attempt
      remove :runner_id
      remove :fence
      remove :recovery_attempts
      remove :profile_id
      remove :consent_id
      remove :agent_revision_digest
      remove :agent_capability_digest
      remove :budget_id
      remove :model
      remove :options
      remove :window_upto_seq
      remove :active_ms
      remove :paused_at
      remove :paused_reason
      remove :launch_step_id
    end
  end
end
