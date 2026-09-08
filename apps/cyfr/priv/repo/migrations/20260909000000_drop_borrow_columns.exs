# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.DropBorrowColumns do
  use Ecto.Migration

  # An agent belongs to the estate whose `aqua/` tree holds it, and a
  # shared tape runs that estate's soul and roles alone: a person's own
  # assistant rides in their own panel, never on a room's tape. The two
  # columns that let an agent be borrowed across estates — which estate a
  # conversation's agent came from, and which estate a grant's agent
  # belonged to — therefore always named the row's own athanor, and go.
  #
  # The grant keys follow: an agent-scope answer is unique per estate and
  # agent, a conversation-scope one per conversation and agent. Named
  # short, as before, for Postgres' 63-byte identifier limit; SQLite
  # reports a violation by column, and `Arca.ToolGrantStorage` declares
  # both spellings.
  def up do
    drop index(:tool_grants, [:agent_athanor_id, :agent_name, :tool, :action],
           name: :tool_grants_agent_scope_index
         )

    drop index(:tool_grants, [:conversation_id, :agent_athanor_id, :agent_name, :tool, :action],
           name: :tool_grants_conversation_scope_index
         )

    alter table(:tool_grants) do
      remove :agent_athanor_id
    end

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

    alter table(:conversations) do
      remove :orchestrator_owner
    end
  end

  def down do
    alter table(:conversations) do
      add :orchestrator_owner, :string
    end

    drop index(:tool_grants, [:athanor_id, :agent_name, :tool, :action],
           name: :tool_grants_agent_scope_index
         )

    drop index(:tool_grants, [:conversation_id, :agent_name, :tool, :action],
           name: :tool_grants_conversation_scope_index
         )

    alter table(:tool_grants) do
      add :agent_athanor_id, :string
    end

    execute "UPDATE tool_grants SET agent_athanor_id = athanor_id"

    create unique_index(
             :tool_grants,
             [:conversation_id, :agent_athanor_id, :agent_name, :tool, :action],
             where: "scope = 'conversation'",
             name: :tool_grants_conversation_scope_index
           )

    create unique_index(
             :tool_grants,
             [:agent_athanor_id, :agent_name, :tool, :action],
             where: "scope = 'agent'",
             name: :tool_grants_agent_scope_index
           )
  end
end
