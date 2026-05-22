# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.AddManifestToComponents do
  use Ecto.Migration

  def change do
    alter table(:components) do
      add :manifest, :text
    end
  end
end
