# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.DirectoryHandle do
  @moduledoc """
  Ecto schema for the `directory_handles` table (backs
  `Arca.DirectoryHandles`): one personal handle of the registry a CYFR
  serving a directory serves beside it, and the account that holds it.
  """

  use Ecto.Schema

  @primary_key {:handle, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "directory_handles" do
    field :identifier, :string
    field :inserted_at, :utc_datetime_usec
  end
end
