# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ServerMeta do
  @moduledoc """
  One fact about this server, by key: the schema the database was built
  from, the keyring fingerprint it was sealed with, the boot that owns the
  control plane. Not an
  athanor's — the row describes the deployment. Managed by
  `Arca.ServerMetaStorage`.
  """

  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "server_meta" do
    field :value, :string
    field :updated_at, :utc_datetime_usec
  end
end
