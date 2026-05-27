# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.WidenSecretNameColumns do
  use Ecto.Migration

  # Secret names are user-supplied and effectively unbounded — SQLite (dynamic
  # typing) stores them as TEXT with no length cap. On Postgres, Ecto's `:string`
  # maps to `varchar(255)`, which rejects long names and diverges from SQLite.
  # Widen the secret-name columns to `text` so both adapters accept the same
  # values. Postgres-only; SQLite's affinity already makes this a no-op.
  def up do
    if repo().__adapter__() == Ecto.Adapters.Postgres do
      alter table(:secrets) do
        modify :name, :text
      end

      alter table(:secret_grants) do
        modify :secret_name, :text
      end
    end
  end

  def down do
    if repo().__adapter__() == Ecto.Adapters.Postgres do
      alter table(:secrets) do
        modify :name, :string
      end

      alter table(:secret_grants) do
        modify :secret_name, :string
      end
    end
  end
end
