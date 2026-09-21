# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.StorageWriteIntent do
  @moduledoc """
  Ecto schema for the `storage_write_intents` table: the evidence of one
  mutable storage write a guest asked of its attempt
  (`Arca.ExecutionAttempts.while_held/5`).

  A row is inserted `pending` while the attempt at `fence`, claimed by
  `runner`, holds its execution, before the store is touched. It settles
  once: `confirmed` when the store applied the write and the attempt still
  held its row, `failed` when the store refused it and wrote nothing, and
  `uncertain` when the store could not say what it did or the attempt lost
  its row while the write was in flight. `reason` says why a `failed` or
  `uncertain` row settled as it did. `op` is `put | append | delete`,
  `path` the athanor-relative path, and `bytes` what a put or append
  carried. A row goes only when its execution's row does. Owned by the
  athanor.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @ops ["put", "append", "delete"]
  @states ["pending", "confirmed", "failed", "uncertain"]

  @doc "The operations an intent records."
  def ops, do: @ops

  @doc "The states of an intent; every state but `pending` is settled."
  def states, do: @states

  schema "storage_write_intents" do
    field :athanor_id, :string
    field :execution_id, :string
    field :attempt, :string
    field :fence, :integer
    field :runner, :string
    field :op, :string
    field :path, :string
    field :bytes, :integer
    field :state, :string
    field :reason, :string
    field :inserted_at, :utc_datetime_usec
    field :settled_at, :utc_datetime_usec
  end
end
