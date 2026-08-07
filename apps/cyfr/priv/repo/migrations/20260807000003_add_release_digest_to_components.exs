# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Arca.Repo.Migrations.AddReleaseDigestToComponents do
  use Ecto.Migration

  # Activation identity: the artifact digest bound to the security-relevant
  # manifest blocks. Nullable — rows published before this column exist keep
  # NULL until a backfill task runs; nothing reads it yet.
  def change do
    alter table(:components) do
      add :release_digest, :string
    end
  end
end
