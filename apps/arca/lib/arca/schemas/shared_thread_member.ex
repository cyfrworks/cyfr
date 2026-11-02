# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.SharedThreadMember do
  @moduledoc """
  Ecto schema for the `shared_thread_members` table (backs
  `Arca.SharedThreadMembers`): a person's seat in a shared thread
  (`active`, naming `user_id`), or an invitation waiting for a person
  identifier (`invited`, naming `person_identifier`) that becomes their
  seat at their sign-in.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @statuses ~w(active invited)

  @doc "A row's statuses: a seat, or an invitation."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  schema "shared_thread_members" do
    field :thread_id, :string
    field :user_id, :string
    field :person_identifier, :string
    field :status, :string, default: "active"
    field :added_by, :string
    field :created_at, :utc_datetime_usec
  end
end
