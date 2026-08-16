# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.McpServer do
  @moduledoc """
  Ecto schema for the `mcp_servers` table (backs `Arca.McpServerStorage`).
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "mcp_servers" do
    field :name, :string
    field :url, :string
    field :config_json, :string
    field :enabled, :boolean
    field :athanor_id, :string
    timestamps(type: :utc_datetime_usec)
  end
end
