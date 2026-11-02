# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.SharedThread do
  @moduledoc """
  Ecto schema for the `shared_threads` table (backs `Arca.SharedThreads`):
  a place people talk in, no athanor's. A `shared` thread has a title; a
  `pair` has none and names its two people in `pair_of`, the two user ids
  sorted and joined.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @kinds ~w(shared pair)
  @statuses ~w(active archived)

  @doc "A thread's kinds: a thread of people with a title, or a pair of two."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "A thread's statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  schema "shared_threads" do
    field :kind, :string
    field :pair_of, :string
    field :title, :string
    field :status, :string, default: "active"
    field :created_by, :string
    field :created_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec
    field :last_message_at, :utc_datetime_usec
    field :security_generation, :integer, default: 1
  end
end
