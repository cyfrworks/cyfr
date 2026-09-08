# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ToolGrants do
  use Ecto.Migration

  # One store for "the human already said yes to this", replacing two.
  #
  # `Aqua.ConversationRunner` kept the same decision in two places and
  # neither was right:
  #
  #   * `:conversation` lived in `state.grants`, a `MapSet` in process
  #     memory. A deploy, a crash or an idle timeout silently reverted an
  #     explicit human decision, and the person was asked again with no
  #     indication their earlier answer had been discarded.
  #   * `:always` wrote `"auto"` into the agent's markdown `tool_policy`
  #     through `Aqua.AgentConfig.set_tool_auto/3`, and `:never` deleted
  #     the key through `drop_tool/3`. A chat click edited the agent's
  #     authored file — the same file the agents page edits — so a
  #     transient decision and a durable definition shared one storage.
  #
  # After this, the markdown is **declared** policy (the author's intent)
  # and a grant is a **decision**. One resolver composes them:
  # `declared ∪ allow − deny`, with deny winning over a declared `"auto"`.
  #
  # ## Two partial indexes, not one composite
  #
  # An agent-scope row carries no conversation, and `NULL ≠ NULL` on both
  # Postgres and SQLite — a single unique index over a nullable column
  # would not constrain those rows at all, which is exactly the row you
  # least want duplicated. Each scope gets an index over the columns that
  # actually identify it.
  #
  # `effect` is deliberately NOT part of either key: flipping allow ↔ deny
  # updates the row in place rather than accumulating a contradictory pair.
  #
  # ## Two athanors, on purpose
  #
  # `athanor_id` is the tenancy — where the grant applies, and what
  # `Arca.TenantTables.delete_all_for/1` reclaims. `agent_athanor_id` is
  # who owns the agent it is about. They are equal today and stay equal for
  # agent scope (that rule is enforced in `Aqua.ToolGrants`), but a
  # conversation-scope grant on an agent borrowed into another estate has
  # them differ — which is the case personal crews introduce.
  def up do
    create table(:tool_grants, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      add :scope, :string, null: false
      add :effect, :string, null: false
      add :conversation_id, :string
      add :agent_athanor_id, :string, null: false
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

    # The resolver's read: every grant that could bear on one turn.
    create index(:tool_grants, [:athanor_id, :agent_name])
  end

  def down do
    drop index(:tool_grants, [:athanor_id, :agent_name])

    drop index(:tool_grants, [:agent_athanor_id, :agent_name, :tool, :action],
           name: :tool_grants_agent_scope_index
         )

    drop index(:tool_grants, [:conversation_id, :agent_athanor_id, :agent_name, :tool, :action],
           name: :tool_grants_conversation_scope_index
         )

    drop table(:tool_grants)
  end
end
