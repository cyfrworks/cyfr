# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.DropLegacyPolicyTables do
  use Ecto.Migration

  # The callee-keyed policy plane these tables backed is deleted: consent
  # revisions carry the resolved policy blob, and enforcement reads the
  # authority's edge + node limits directly. Nothing reads or writes these
  # rows anymore.
  def up do
    drop_if_exists(table(:policies))
    drop_if_exists(table(:component_configs))
  end

  def down do
    # Deliberately irreversible: the plane that read these tables no longer
    # exists, and resurrecting empty tables would only invite something to
    # write policies nothing can consume.
    :ok
  end
end
