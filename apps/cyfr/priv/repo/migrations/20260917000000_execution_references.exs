# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ExecutionReferences do
  use Ecto.Migration

  # Enforces athanor-scoped execution references for events and payloads.
  # Recreates both tables and preserves payload rows. Payload bytes must
  # be removed before their rows permit execution deletion.
  @payload_columns ~w(id athanor_id execution_id kind digest bytes blob_ref retention_class inserted_at)

  def up do
    create unique_index(:executions, [:id, :athanor_id])

    drop table(:execution_events)
    create_execution_events(constrained: true)

    drop index(:execution_payloads, [:execution_id, :kind])
    drop index(:execution_payloads, [:athanor_id, :retention_class, :inserted_at])
    rename table(:execution_payloads), to: table(:execution_payloads_old)
    create_execution_payloads(constrained: true)
    copy_payloads(from: "execution_payloads_old", joined: true)
    drop table(:execution_payloads_old)
  end

  def down do
    drop index(:execution_payloads, [:execution_id, :kind])
    drop index(:execution_payloads, [:athanor_id, :retention_class, :inserted_at])
    rename table(:execution_payloads), to: table(:execution_payloads_old)
    create_execution_payloads(constrained: false)
    copy_payloads(from: "execution_payloads_old", joined: false)
    drop table(:execution_payloads_old)

    drop table(:execution_events)
    create_execution_events(constrained: false)

    drop unique_index(:executions, [:id, :athanor_id])
  end

  defp execution_reference(constrained: true, on_delete: on_delete) do
    references(:executions,
      type: :string,
      on_delete: on_delete,
      with: [athanor_id: :athanor_id]
    )
  end

  defp execution_reference(constrained: false, on_delete: _), do: :string

  defp create_execution_events(constrained: constrained) do
    create table(:execution_events, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :execution_id, execution_reference(constrained: constrained, on_delete: :delete_all),
        null: false

      add :turn_id, :string
      add :step_id, :string
      add :seq, :integer, null: false
      add :type, :string, null: false
      add :data, :text
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:execution_events, [:execution_id, :seq])
    create index(:execution_events, [:athanor_id, :turn_id])
  end

  defp create_execution_payloads(constrained: constrained) do
    create table(:execution_payloads, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :execution_id, execution_reference(constrained: constrained, on_delete: :nothing),
        null: false

      # input | result
      add :kind, :string, null: false
      add :digest, :string, null: false
      add :bytes, :integer, null: false
      add :blob_ref, :string, null: false
      add :retention_class, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:execution_payloads, [:execution_id, :kind])
    create index(:execution_payloads, [:athanor_id, :retention_class, :inserted_at])
  end

  # Rows whose execution no longer exists cannot satisfy the constraint
  # and are not carried; the bytes they named are the retention sweep's.
  defp copy_payloads(from: old, joined: joined) do
    columns = Enum.map_join(@payload_columns, ", ", &"p.#{&1}")

    join =
      if joined,
        do: " JOIN executions e ON e.id = p.execution_id AND e.athanor_id = p.athanor_id",
        else: ""

    execute(
      "INSERT INTO execution_payloads (#{Enum.join(@payload_columns, ", ")}) " <>
        "SELECT #{columns} FROM #{old} p#{join}"
    )
  end
end
