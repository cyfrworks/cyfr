# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.TopicSubscription do
  @moduledoc """
  One person following one topic.

  Presence-only, like a membership: the row IS the fact. It drives what is
  in a sidebar and what notifies — never who may read, which stays
  `Sanctum.Tenancy.Members.member?/2`. An unfollowed topic is collapsed,
  not hidden.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{}

  schema "topic_subscriptions" do
    field :athanor_id, :string
    field :conversation_id, :string
    field :user_id, :string
    field :joined_at, :utc_datetime_usec
  end
end
