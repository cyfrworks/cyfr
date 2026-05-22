# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.RenameAllowedStoragePathsToAllowedPaths do
  use Ecto.Migration

  def change do
    rename table(:policies), :allowed_storage_paths, to: :allowed_paths
  end
end
