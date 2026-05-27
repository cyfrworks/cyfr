# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ConvertComponentDependencyOptionalToBoolean do
  use Ecto.Migration

  # `component_dependencies.optional` was created as an integer (0/1) flag while
  # every other boolean flag (`api_keys.revoked`, `mcp_servers.enabled`, …) uses a
  # real `:boolean` column. The schema now declares it `:boolean`. SQLite is
  # dynamically typed — its existing 0/1 values already read back as false/true
  # through the Ecto `:boolean` type — so this is a Postgres-only column-type
  # conversion (Postgres cannot cast integer→boolean implicitly, hence the
  # explicit USING clause).
  def up do
    if repo().__adapter__() == Ecto.Adapters.Postgres do
      execute("ALTER TABLE component_dependencies ALTER COLUMN optional DROP DEFAULT")

      execute(
        "ALTER TABLE component_dependencies ALTER COLUMN optional TYPE boolean USING (optional <> 0)"
      )

      execute("ALTER TABLE component_dependencies ALTER COLUMN optional SET DEFAULT false")
    end
  end

  def down do
    if repo().__adapter__() == Ecto.Adapters.Postgres do
      execute("ALTER TABLE component_dependencies ALTER COLUMN optional DROP DEFAULT")

      execute(
        "ALTER TABLE component_dependencies ALTER COLUMN optional TYPE integer USING (CASE WHEN optional THEN 1 ELSE 0 END)"
      )

      execute("ALTER TABLE component_dependencies ALTER COLUMN optional SET DEFAULT 0")
    end
  end
end
