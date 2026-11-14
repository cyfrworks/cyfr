# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.McpServer do
  @moduledoc """
  Ecto schema for the `mcp_servers` table (backs `Arca.McpServerStorage`).

  `transport` is `"http"`, a tool server elsewhere reached at `url`, or
  `"program"`, a program CYFR runs on the backends service, its backends
  in `config_json` and `url` nil. A program's `mark` says how it is
  spoken to: `"mcp"`, Emissary speaking MCP on its input and output, or
  `"driven"`, run by a person or a brain; an http row has none. A
  program's `home` is `"scratch"`, scrubbed at retirement, or `"kept"`, a
  home per login entry that survives it; `memory_bytes` and
  `home_max_bytes` are its bounds (nil: the service's own bound, the homes
  volume), `login_command` what a sign-in runs, and `login_entry_id` the
  login entry a kept `mcp` program's sessions run in. `hosts` is a program's network list as JSON text, the
  only hosts it reaches (`Opus.Programs.Definition`), nil for every public
  host.
  `epoch` rises with every change to the row, and so does `revision`, the
  counter a fenced publication compares (`Arca.FencedPublication`).
  `created_by` is the id of the person who created it, set once.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @transports ~w(http program)
  @marks ~w(mcp driven)
  @homes ~w(scratch kept)

  @doc "The `transport` vocabulary, the `mcp_servers_kind` check's."
  @spec transports() :: [String.t()]
  def transports, do: @transports

  @doc "The `mark` vocabulary, the `mcp_servers_kind` check's."
  @spec marks() :: [String.t()]
  def marks, do: @marks

  @doc "The `home` vocabulary, the `mcp_servers_home_known` check's."
  @spec homes() :: [String.t()]
  def homes, do: @homes

  schema "mcp_servers" do
    field :name, :string
    field :transport, :string
    field :mark, :string
    field :home, :string, default: "scratch"
    field :memory_bytes, :integer
    field :home_max_bytes, :integer
    field :login_command, :string
    field :login_entry_id, :string
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
