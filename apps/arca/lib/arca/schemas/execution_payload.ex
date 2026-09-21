# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ExecutionPayload do
  @moduledoc """
  A reference to an execution's retained input or result: the digest and
  size of the bytes, their place under the athanor's `payloads/` root,
  the attempt that produced them, and the retention class that bounds
  their life. Owned by the athanor.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "execution_payloads" do
    field :athanor_id, :string
    field :execution_id, :string
    field :kind, :string
    field :attempt, :string
    field :digest, :string
    field :bytes, :integer
    field :blob_ref, :string
    field :retention_class, :string
    field :inserted_at, :utc_datetime_usec
  end
end
