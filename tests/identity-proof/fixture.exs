# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# What the identity proof asks of a running server, evaluated inside it by
# `bin/cyfr rpc` (`identity_fixture` in cells.sh). The file evaluates to a
# function of the argument list; each command prints nothing and answers
# one line, `FIXTURE=` and a JSON object. No command answers a token, a
# recovery code or a key.
#
#   people
#       The people this CYFR holds: each one's id, identifier, admission
#       and status, the sessions bound to them (each by the kid and head it
#       was bound to) and their paired clients (each by kid, kind and
#       standing).
#
#   head IDENTIFIER
#       The account's head cached here (`Arca.DirectoryHeads`): its hash,
#       whether it is marked gone, and the keys its verified state lists.
#
#   resolve IDENTIFIER
#       The account's log read live at this CYFR's directory and cached
#       (`Sanctum.IdentityFreshness.fresh!/2`): `{head}`, or `{refused}`.
#
#   fresh IDENTIFIER
#       The head this CYFR trusts now (`Sanctum.IdentityFreshness.fresh?/2`):
#       the cached one within `identity_freshness_seconds`, else read again;
#       `{head}`, or `{refused}` (`identity_stale`, `identity_gone`).
#
#   tombstone IDENTIFIER
#       The operator's tombstone at the directory this CYFR serves
#       (`Sanctum.Directory.tombstone/1`, the path the operation
#       `directory.tombstone` takes): `{tombstoned}` or `{refused}`.

fn args ->
  import Ecto.Query, only: [from: 2]

  answer = fn map -> "FIXTURE=" <> Jason.encode!(map) end

  head_answer = fn
    {:ok, head} -> %{head: head.head_hash}
    {:refused, reason} -> %{refused: reason}
    {:error, reason} -> %{refused: inspect(reason)}
  end

  case args do
    ["people"] ->
      people =
        Arca.Repo.all(
          from(u in Arca.Schemas.User,
            left_join: i in Arca.Schemas.PersonIdentity,
            on: i.user_id == u.id,
            order_by: u.created_at,
            select: %{user_id: u.id, identifier: i.identifier, admission: u.admission, status: u.status}
          )
        )
        |> Enum.map(fn person ->
          sessions =
            Arca.Repo.all(
              from(s in Arca.Schemas.Session,
                where: s.user_id == ^person.user_id,
                select: %{kid: s.kid, head: s.head, client_id: s.client_id}
              )
            )

          clients =
            Arca.Repo.all(
              from(c in Arca.Schemas.PairedClient,
                where: c.user_id == ^person.user_id,
                select: %{kid: c.kid, kind: c.source_kind, standing: c.standing}
              )
            )

          Map.merge(person, %{sessions: sessions, clients: clients})
        end)

      answer.(%{people: people})

    ["head", identifier] ->
      case Arca.DirectoryHeads.get(Prima.Actor.system(), identifier) do
        {:ok, head} ->
          keys =
            case Sanctum.IdentityFreshness.state(head) do
              {:ok, state} -> Enum.map(state.keys, &%{kid: &1.kid, kind: &1.kind})
              {:error, reason} -> inspect(reason)
            end

          answer.(%{head: head.head_hash, gone: not is_nil(head.gone_at), keys: keys})

        {:error, reason} ->
          answer.(%{refused: inspect(reason)})
      end

    ["resolve", identifier] ->
      identifier
      |> Sanctum.IdentityFreshness.fresh!(directory: Sanctum.directory_url())
      |> head_answer.()
      |> answer.()

    ["fresh", identifier] ->
      identifier |> Sanctum.IdentityFreshness.fresh?() |> head_answer.() |> answer.()

    ["tombstone", identifier] ->
      case Sanctum.Directory.tombstone(identifier) do
        :ok -> answer.(%{tombstoned: identifier})
        {:error, reason} -> answer.(%{refused: inspect(reason)})
      end
  end
end
