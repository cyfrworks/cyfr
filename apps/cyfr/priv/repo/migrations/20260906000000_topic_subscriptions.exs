# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.TopicSubscriptions do
  use Ecto.Migration

  # Which of an estate's topics are in your sidebar.
  #
  # An athanor has always been able to hold many conversations, but every
  # member saw every one of them and there was nothing to say "this thread
  # is not mine to follow". That is fine for a two-person estate and wrong
  # for a working group with a dozen threads.
  #
  # ## Subscription, not access control
  #
  # A row here says a person FOLLOWS a topic. It does not gate reading one:
  # access stays `Sanctum.Tenancy.Members.member?/2`, so an unfollowed
  # topic renders collapsed and opens on a click. Making this an ACL would
  # be a second, weaker permission system beside membership, and a private
  # side-conversation has a better answer already — a frozen pair estate,
  # which gets its own vault and its own audit trail rather than hiding
  # rows inside somebody else's.
  #
  # No backfill: on a fresh install there is nothing to preserve, and an
  # existing server's topics render collapsed until someone follows them.
  # That belongs in the release note.
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
