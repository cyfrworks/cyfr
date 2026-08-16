# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ComponentDependency do
  @moduledoc """
  Ecto schema for the `component_dependencies` table (backs
  `Arca.DependencyStorage`).
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "component_dependencies" do
    field :component_id, :string
    field :dependency_ref, :string
    field :dep_type, :string
    field :dep_namespace, :string
    field :dep_name, :string
    field :dep_version, :string
    field :optional, :boolean
    field :reason, :string
    field :athanor_id, :string
    timestamps(type: :utc_datetime_usec)
  end
end
