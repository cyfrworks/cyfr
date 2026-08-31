# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ConsentsBlobDigest do
  use Ecto.Migration

  import Ecto.Query

  # Nothing on a consent row detected a `resolved_policy` altered in place.
  #
  # `commit_digest` covers the decisions — shape digest, kind, invoke mode,
  # bindings, tool servers, override — not the blob those decisions produce.
  # `Consent.Loader`'s `check_blob_refs_equality/2` compares vault-ref pairs
  # only. So dependency caps, egress domains, storage actions and node
  # limits were all unverifiable after the fact, and a decision field that
  # reached the blob without reaching the digest (`durable_storage` did
  # exactly that) could be replayed under an already-approved digest.
  #
  # The backfill is exact and needs no fallback: JCS is canonical and
  # `resolved_policy` is stored verbatim, so re-hashing a stored blob
  # reproduces the digest the row would have been written with.
  #
  # The hash is spelled inline rather than through `Cyfr.Digest.sha256/1`
  # on purpose. A migration is frozen history: it must keep producing the
  # bytes it produced the day it ran, even if the helper's format is ever
  # revised. Everywhere else, the helper is the one spelling.
  # `null: false` holds on BOTH backends. The SQLite restriction is on
  # `ALTER COLUMN` (`modify`), which this does not use: `{:add, …}` passes
  # `column_options` straight through, so this emits
  # `ADD COLUMN "blob_digest" TEXT DEFAULT '' NOT NULL`, which SQLite
  # accepts. The empty default is what lets a table that already has rows
  # take a NOT NULL column at all; `backfill/0` immediately replaces it,
  # and `Arca.ConsentStorage.revision_row/2` refuses to write one — the
  # default exists for the ALTER, never for a writer.
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

      # `resolved_policy` is `null: false` in the baseline, so this arm is
      # unreachable — but a single-clause `fn` with a guard raises
      # `FunctionClauseError` mid-migration if it ever is reached, and a
      # migration that half-ran is worse than one row left at `""`, which
      # the loader refuses loudly anyway.
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
