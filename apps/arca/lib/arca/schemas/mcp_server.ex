# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.McpServer do
  @moduledoc """
  Ecto schema for the `mcp_servers` table (backs `Arca.McpServerStorage`).

  `transport` is `"http"` (the server is reached at `url`) or `"stdio"` (its
  backends, in `config_json`, run on the MCP bridge and `url` is nil).
  `epoch` rises with every change to the row. `created_by` is the id of the
  person who created it, set once.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "mcp_servers" do
    field :name, :string
    field :transport, :string
    field :url, :string
    field :config_json, :string
    field :enabled, :boolean
    field :epoch, :integer
    field :created_by, :string
    field :athanor_id, :string
    timestamps(type: :utc_datetime_usec)
  end
end
