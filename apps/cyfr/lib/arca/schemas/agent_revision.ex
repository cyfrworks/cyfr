# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.AgentRevision do
  @moduledoc """
  One revision of an agent file, by the digest of its bytes: what a turn
  pins and can retrieve after the file has moved on. Owned by the
  athanor; written by `Arca.AgentRevisions` alone.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "agent_revisions" do
    field :athanor_id, :string
    field :digest, :string
    field :bytes, :binary
    field :inserted_at, :utc_datetime_usec
  end
end
