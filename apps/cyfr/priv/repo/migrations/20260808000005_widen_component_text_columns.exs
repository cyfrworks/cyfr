# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.WidenComponentTextColumns do
  use Ecto.Migration

  # Free-text component metadata has no natural 255-byte bound — a
  # description over that length registered fine on SQLite (which ignores
  # varchar sizes) and failed only on Postgres. Widen to text so both
  # adapters accept the same manifests. SQLite needs no change.
  def up do
    if postgres?() do
      alter table(:components) do
        modify :description, :text
        modify :tags, :text
        modify :exports, :text
      end
    end
  end

  def down do
    # Narrowing back to varchar(255) could truncate stored rows; keep text.
    :ok
  end

  defp postgres?, do: repo().__adapter__() == Ecto.Adapters.Postgres
end
