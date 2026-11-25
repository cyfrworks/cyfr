# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# What the box's proof with two CYFRs (box.sh) asks of a running server,
# evaluated inside it by `bin/cyfr rpc`: at x.test by release.sh's
# `cell_fixture`, at This box by the same file's text inside its container.
# The file evaluates to a function of the argument list; each command
# answers one line, `FIXTURE=` and a JSON object, and none answers a
# token or a key.
#
#   admit IDENTIFIER
#       The account IDENTIFIER made this CYFR's first person under its own
#       setup token, its head read at this CYFR's directory
#       (`Sanctum.Newcomer.admit/3`, the one path that makes a person): a
#       stand-in for an invitation, which the box's device then reaches by
#       its own hello and the door's verdict. `{admitted}` or `{refused}`.
#
#   sessions IDENTIFIER
#       What this CYFR holds of the account's person: whether there is
#       one, its paired clients (kid and standing), its sessions that a
#       token loads and have not expired (`live`, each by kid and client)
#       and its reservations of an unlock (`reserved`).

fn args ->
  import Ecto.Query, only: [from: 2]

  answer = fn map -> "FIXTURE=" <> Jason.encode!(map) end

  case args do
    ["admit", identifier] ->
      directory = Sanctum.directory_url()

      with {:ok, token} <- Application.fetch_env(:sanctum, :setup_token),
           {:ok, head} <- Sanctum.IdentityFreshness.fresh!(identifier, directory: directory),
           {:ok, %{person: person}} <-
             Sanctum.Newcomer.admit({:setup, token}, %{
               identifier: identifier,
               directory_url: directory,
               head_hash: head.head_hash
             }) do
        answer.(%{admitted: person.id})
      else
        other -> answer.(%{refused: inspect(other)})
      end

    ["sessions", identifier] ->
      now = DateTime.utc_now()

      user_id =
        Arca.Repo.one(
          from(i in Arca.Schemas.PersonIdentity,
            where: i.identifier == ^identifier,
            select: i.user_id
          )
        )

      sessions =
        if user_id do
          Arca.Repo.all(
            from(s in Arca.Schemas.Session,
              where: s.user_id == ^user_id and s.expires_at > ^now,
              select: %{kid: s.kid, client_id: s.client_id, provider: s.provider}
            )
          )
        else
          []
        end

      clients =
        if user_id do
          Arca.Repo.all(
            from(c in Arca.Schemas.PairedClient,
              where: c.user_id == ^user_id,
              select: %{kid: c.kid, standing: c.standing}
            )
          )
        else
          []
        end

      {reserved, live} = Enum.split_with(sessions, &(&1.provider == "unlock_reserved"))

      answer.(%{
        person: not is_nil(user_id),
        clients: clients,
        live: Enum.map(live, &Map.take(&1, [:kid, :client_id])),
        reserved: length(reserved)
      })
  end
end
