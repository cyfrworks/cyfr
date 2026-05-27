# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Policy do
  @moduledoc """
  Ecto schema for the `policies` table.

  Backs `Arca.PolicyStorage`. The schema casts column values to canonical
  Elixir types (`%DateTime{}`, booleans) identically on SQLite and Postgres.
  JSON array columns stay `:string` and are encoded/decoded with `Jason` by the
  `Sanctum.PolicyStore` context layer.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "policies" do
    field :component_ref, :string
    field :component_type, :string
    field :allowed_domains, :string
    field :allowed_methods, :string
    field :allowed_tools, :string
    field :allowed_paths, :string
    field :allowed_actions, :string
    field :allowed_private_ips, :string
    field :rate_limit_requests, :integer
    field :rate_limit_window_seconds, :integer
    field :timeout, :string
    field :max_memory_bytes, :integer
    field :max_request_size, :integer
    field :max_response_size, :integer
    field :batch_timeout, :string
    field :max_concurrent_tasks, :integer
    field :is_public, :boolean
    field :org_id, :string
    field :project_id, :string
    timestamps(type: :utc_datetime_usec)
  end
end
