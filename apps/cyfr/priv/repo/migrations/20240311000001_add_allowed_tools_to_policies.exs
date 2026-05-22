# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.AddAllowedToolsToPolicies do
  use Ecto.Migration

  def change do
    alter table(:policies) do
      # JSON array of tool patterns (e.g. ["component.*", "storage.read"])
      add :allowed_tools, :text
      # JSON array of path prefixes (e.g. ["agent/"])
      add :allowed_storage_paths, :text
    end
  end
end
