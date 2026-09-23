# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.JobClaim do
  @moduledoc """
  Who is running one of the cell's singleton jobs: one row per
  `(kind, key)`, taken and renewed by compare-and-set on `(owner, fence)`
  against database time.

  A claim is a mutual-exclusion token and authorizes nothing. Its holder
  reads and writes through the same tenant-scoped facades under the same
  actor as any other caller, so `key` naming an athanor's credential grants
  no reach into that athanor — it only says which job this row is about.
  That is why the table carries no `athanor_id`: several of its kinds have
  no estate at all, and a claim is not the thing tenancy is decided by.

  `detail` carries the job's own progress under the holder's fence, so a
  takeover inherits what its predecessor had learned — the worker watch's
  consecutive misses and the worker boot it last heard — instead of
  starting the count again and never reaching its threshold.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @kinds ~w(retention bootstrap seed_release oauth_refresh worker_watch mcp_backend)

  @type t :: %__MODULE__{}

  schema "job_claims" do
    field :kind, :string
    field :key, :string
    field :owner, :string
    field :lease_until, :utc_datetime_usec
    field :fence, :integer
    field :detail, :string
    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The jobs a claim may be taken for. A closed roster: a kind outside it is
  a job nobody declared, and the claim facade refuses it rather than
  admitting a singleton no one reviewed.
  """
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds
end
