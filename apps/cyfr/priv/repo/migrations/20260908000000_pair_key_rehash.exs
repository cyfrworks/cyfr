# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.PairKeyRehash do
  use Ecto.Migration

  import Ecto.Query

  # A pair's canonical key is now the SHA-256 of the JSON encoding of its
  # two sorted member ids (`Sanctum.Tenancy.Athanors.pair_key/2`), where it
  # was a newline join. A key minted the old way is not recognised, so
  # every existing DM would be found by nothing and clicking the name
  # would mint a second estate beside it. Re-key every active frozen pair
  # from its two active seats; a pair with any other number of seats is
  # left alone — it is not a pair the new key could name.
  def up do
    frozen =
      from(a in "athanors",
        where: a.roster == "frozen" and a.status == "active",
        select: a.id
      )

    for athanor_id <- repo().all(frozen) do
      seats =
        from(m in "memberships",
          where: m.athanor_id == ^athanor_id and m.status == "active" and not is_nil(m.user_id),
          select: m.user_id
        )

      case repo().all(seats) do
        [_, _] = ids ->
          key =
            ids
            |> Enum.sort()
            |> Jason.encode!()
            |> then(&:crypto.hash(:sha256, &1))
            |> Base.url_encode64(padding: false)

          repo().update_all(from(a in "athanors", where: a.id == ^athanor_id),
            set: [pair_key: key]
          )

        _ ->
          :ok
      end
    end
  end

  # The old spelling is not recomputed on the way down: a key is a lookup
  # aid, and `create_pair/2` re-derives it from the seats it finds.
  def down, do: :ok
end
