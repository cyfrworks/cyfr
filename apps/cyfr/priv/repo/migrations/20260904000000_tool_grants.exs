# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ToolGrants do
  use Ecto.Migration

  # Stores athanor-scoped tool decisions separately from authored agent policy.
  # Effective policy is declared permissions plus allows, minus denies.
  # Agent-scope grants apply across conversations; conversation-scope grants
  # apply only to the named conversation.
  #
  # Each scope has its own unique index. Agent rows have no conversation id,
  # and a nullable composite key would permit duplicate agent grants.
  # Effect is excluded from the keys so changing allow/deny updates one row.
  def up do
    create table(:tool_grants, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      add :scope, :string, null: false
      add :effect, :string, null: false
      add :conversation_id, :string
      add :agent_name, :string, null: false
      add :tool, :string, null: false
      add :action, :string, null: false
      add :granted_by, :string
      add :granted_at, :utc_datetime_usec, null: false
    end

    # Named short on purpose: Ecto's default name for the conversation-scope
    # key is 73 bytes and Postgres would truncate it at 63, so the changeset
    # could never match what the database reports. SQLite reports a
    # violation by column, not by name, so `Arca.ToolGrantStorage` declares
    # the constraint under both spellings.
    create unique_index(
             :tool_grants,
             [:conversation_id, :agent_name, :tool, :action],
             where: "scope = 'conversation'",
             name: :tool_grants_conversation_scope_index
           )

    create unique_index(
             :tool_grants,
             [:athanor_id, :agent_name, :tool, :action],
             where: "scope = 'agent'",
             name: :tool_grants_agent_scope_index
           )

    # The resolver's read: every grant that could bear on one turn.
    create index(:tool_grants, [:athanor_id, :agent_name])
  end

  def down do
    drop index(:tool_grants, [:athanor_id, :agent_name])

    drop index(:tool_grants, [:athanor_id, :agent_name, :tool, :action],
           name: :tool_grants_agent_scope_index
         )

    drop index(:tool_grants, [:conversation_id, :agent_name, :tool, :action],
           name: :tool_grants_conversation_scope_index
         )

    drop table(:tool_grants)
  end
end
