# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.McpServer do
  @moduledoc """
  Ecto schema for the `mcp_servers` table (backs `Arca.McpServerStorage`).

  `transport` is `"http"` (the server is reached at `url`), `"stdio"` (its
  backends, in `config_json`, run on the backends service and `url` is nil)
  or `"pipe"` (a program a catalyst drives; not built yet, and
  `Arca.McpServerStorage` refuses it). A program's `home` is `"scratch"`,
  scrubbed at retirement, or `"kept"` (not built yet, refused alike);
  `memory_bytes`, `home_max_bytes`, `login_command` and `hosts` (a JSON
  network list) are its program settings, written by nothing yet.
  `epoch` rises with every change to the row, and so does `revision`, the
  counter a fenced publication compares (`Arca.FencedPublication`).
  `created_by` is the id of the person who created it, set once.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @transports ~w(http stdio pipe)
  @homes ~w(scratch kept)

  @doc "The `transport` vocabulary, the `mcp_servers_transport_url` check's."
  @spec transports() :: [String.t()]
  def transports, do: @transports

  @doc "The `home` vocabulary, the `mcp_servers_home_known` check's."
  @spec homes() :: [String.t()]
  def homes, do: @homes

  schema "mcp_servers" do
    field :name, :string
    field :transport, :string
    field :home, :string, default: "scratch"
    field :memory_bytes, :integer
    field :home_max_bytes, :integer
    field :login_command, :string
    field :hosts, :string
    field :url, :string
    field :config_json, :string
    field :enabled, :boolean
    field :epoch, :integer
    field :revision, :integer, default: 0
    field :created_by, :string
    field :athanor_id, :string
    timestamps(type: :utc_datetime_usec)
  end
end
