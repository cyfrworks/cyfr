# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ConsentsBlobDigest do
  use Ecto.Migration

  import Ecto.Query

  # Add a required digest and backfill it from each stored policy's canonical
  # JCS bytes. Keep the hash format local to this migration so its output is
  # stable across application-helper changes.
  #
  # The empty default permits adding a NOT NULL column to a populated table.
  # Backfill replaces it; consent writers require a nonempty digest.
  def up do
    alter table(:consents) do
      add :blob_digest, :string, null: false, default: ""
    end

    flush()

    backfill()
  end

  defp backfill do
    "consents"
    |> select([c], {c.id, c.resolved_policy})
    |> repo().all()
    |> Enum.each(fn
      {id, policy} when is_binary(policy) ->
        digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, policy), case: :lower)

        "consents"
        |> where([c], c.id == ^id)
        |> repo().update_all(set: [blob_digest: digest])

      # Skip non-binary policies; their empty digest causes the loader to reject them.
      {_id, _absent} ->
        :ok
    end)
  end

  def down do
    alter table(:consents) do
      remove :blob_digest
    end
  end
end
