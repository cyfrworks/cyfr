# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.TopicSubscriptions do
  use Ecto.Migration

  # Stores topic follows for each member’s sidebar. Follows control
  # expanded/collapsed display; athanor membership still controls access.
  # Existing topics remain unfollowed until a member follows them.
  def up do
    create table(:topic_subscriptions, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      add :conversation_id, :string, null: false
      add :user_id, :string, null: false
      add :joined_at, :utc_datetime_usec, null: false
    end

    create unique_index(:topic_subscriptions, [:conversation_id, :user_id])

    # The sidebar's read: this person's follows in this estate.
    create index(:topic_subscriptions, [:athanor_id, :user_id])
  end

  def down do
    drop index(:topic_subscriptions, [:athanor_id, :user_id])
    drop index(:topic_subscriptions, [:conversation_id, :user_id])
    drop table(:topic_subscriptions)
  end
end
