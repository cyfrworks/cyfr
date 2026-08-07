# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Mix.Tasks.Cyfr.BackfillReleaseDigests do
  @shortdoc "Compute release digests for component rows that predate them"

  @moduledoc """
  Backfill `components.release_digest` for rows published before release
  digests existed.

  Activation resolution is all-or-nothing: one digest-less row in a
  closure makes every consent over it unresolvable, so this runs before
  `mix cyfr.consent.bootstrap`. A row whose stored manifest cannot feed
  the digest (a float in a security block) is reported and skipped — it
  cannot take part in an activation until republished.
  """

  use Mix.Task

  import Ecto.Query

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    rows =
      Arca.Repo.all(from c in Arca.Schemas.Component, where: is_nil(c.release_digest))

    {done, failed} =
      Enum.reduce(rows, {0, []}, fn row, {done, failed} ->
        manifest = Compendium.Manifest.decode(row.manifest)

        case Compendium.ReleaseDigest.compute(row.digest, manifest) do
          {:ok, release_digest} ->
            Arca.Repo.update_all(
              from(c in Arca.Schemas.Component, where: c.id == ^row.id),
              set: [release_digest: release_digest]
            )

            {done + 1, failed}

          {:error, reason} ->
            {done, [{row.id, reason} | failed]}
        end
      end)

    Mix.shell().info("Backfilled #{done} release digest(s); #{length(failed)} unresolvable.")

    Enum.each(failed, fn {id, reason} ->
      Mix.shell().error("  #{id}: #{inspect(reason)}")
    end)
  end
end
