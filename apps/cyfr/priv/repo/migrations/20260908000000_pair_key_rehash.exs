# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.PairKeyRehash do
  use Ecto.Migration

  import Ecto.Query

  # Recompute pair keys as SHA-256 over JSON-encoded sorted member ids.
  # Only active frozen athanors with exactly two active members are updated.
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

  # Rollback leaves pair lookup keys unchanged.
  def down, do: :ok
end
