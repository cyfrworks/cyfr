# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# What the handle proof asks of a running server, evaluated inside it by
# `bin/cyfr rpc` (`handle_fixture` in run.sh). The file evaluates to a
# function of the argument list; each command prints nothing and answers
# one line, `FIXTURE=` and a JSON object. An argument spelled `@PATH` is
# read from that file. No command answers a session token, a push token,
# a key or a seed.
#
#   rows TABLE [COLUMN VALUE]
#       Every row of TABLE (one of the proof's tables), every column as
#       stored, or those whose COLUMN is VALUE, ordered by the first
#       column: `{rows: [...]}`. A column holding bytes that are not
#       printable text answers `{"bytes": base64}`.
#
#   set TABLE ID FIELD @VALUE_FILE
#       FIELD of the row of TABLE whose `id` is ID written to the JSON
#       value the file holds (`{"bytes": base64}` for bytes), behind the
#       server's back and with the database's foreign-key and check
#       constraints off for that write, as a tamper or the restore of one:
#       `{set: 1}`.
#
#   credential USER_ID REGISTRY SLUG
#       The push token the person's row of `registry_tokens` seals, opened
#       as `Sanctum.RegistryCredentials` opens it: every key it holds, the
#       token itself replaced by `{"sha256": hex}`.
#
#   token_to USER_ID REGISTRY SLUG PATH
#       That push token written to PATH (mode 0600), for the run's request
#       to the registry: `{written: true}`.
#
#   refusal REASON
#       `Prima.Refusal`'s sentence for REASON, and whether any other reason
#       a CYFR sign-in or a registry sync refuses with reads the same.

fn args ->
  answer = fn map -> "FIXTURE=" <> Jason.encode!(map) end

  read = fn
    "@" <> path -> File.read!(path) |> String.trim()
    value -> value
  end

  tables = ~w(users person_identities passkeys server_allowlist sessions registry_tokens)

  table! = fn table ->
    if table in tables, do: table, else: raise("no table #{inspect(table)} for this proof")
  end

  encode = fn
    value when is_binary(value) ->
      if String.printable?(value), do: value, else: %{"bytes" => Base.encode64(value)}

    value ->
      value
  end

  decode = fn
    %{"bytes" => b64} -> Base.decode64!(b64)
    value -> value
  end

  rows = fn table, where ->
    {sql, params} =
      case where do
        nil -> {"SELECT * FROM #{table} ORDER BY 1", []}
        {column, value} -> {"SELECT * FROM #{table} WHERE #{column} = ?1 ORDER BY 1", [value]}
      end

    %{columns: columns, rows: rows} = Arca.Repo.query!(sql, params)
    for row <- rows, do: Map.new(Enum.zip(columns, Enum.map(row, encode)))
  end

  columns = fn table ->
    %{rows: info} = Arca.Repo.query!("PRAGMA table_info(#{table})", [])
    for [_cid, name | _rest] <- info, do: name
  end

  credential = fn user_id, registry, slug ->
    %{rows: [[ciphertext]]} =
      Arca.Repo.query!(
        "SELECT credential_ciphertext FROM registry_tokens WHERE user_id = ?1 AND registry = ?2 AND namespace_slug = ?3",
        [user_id, registry, slug]
      )

    aad = Sanctum.CipherAAD.registry_token(user_id, registry, slug)
    {:ok, plain} = Sanctum.Cipher.decrypt(ciphertext, aad)
    Jason.decode!(plain)
  end

  case Enum.map(args, read) do
    ["rows", table] ->
      answer.(%{rows: rows.(table!.(table), nil)})

    ["rows", table, column, value] ->
      table = table!.(table)
      unless column in columns.(table), do: raise("no column #{column} in #{table}")
      answer.(%{rows: rows.(table, {column, value})})

    ["set", table, id, field, value] ->
      table = table!.(table)
      unless field in columns.(table), do: raise("no column #{field} in #{table}")
      value = value |> Jason.decode!() |> decode.()

      # On one connection, with the database's own checks off for this
      # write alone: a tamper writes what no code path could.
      count =
        Arca.Repo.checkout(fn ->
          Arca.Repo.query!("PRAGMA foreign_keys = OFF", [])
          Arca.Repo.query!("PRAGMA ignore_check_constraints = ON", [])

          try do
            %{num_rows: count} =
              Arca.Repo.query!("UPDATE #{table} SET #{field} = ?1 WHERE id = ?2", [value, id])

            count
          after
            Arca.Repo.query!("PRAGMA ignore_check_constraints = OFF", [])
            Arca.Repo.query!("PRAGMA foreign_keys = ON", [])
          end
        end)

      answer.(%{set: count})

    ["credential", user_id, registry, slug] ->
      held = credential.(user_id, registry, slug)
      token = Map.fetch!(held, "token")

      answer.(%{
        credential:
          Map.put(held, "token", %{
            "sha256" => Base.encode16(:crypto.hash(:sha256, token), case: :lower)
          })
      })

    ["token_to", user_id, registry, slug, path] ->
      token = Map.fetch!(credential.(user_id, registry, slug), "token")
      File.write!(path, token)
      File.chmod!(path, 0o600)
      answer.(%{written: true})

    ["refusal", reason] ->
      reason = String.to_existing_atom(reason)

      others =
        ~w(wrong_destination identity_stale unavailable invalid_carry no_request not_allowed
           wrong_identity banned registry_unavailable not_enrolled no_registry
           registry_token_missing unknown_identity directory_unavailable wrong_directory
           policy_required no_handle)a -- [reason]

      sentence = Prima.Refusal.message(reason)

      answer.(%{
        reason: reason,
        sentence: sentence,
        shared_with: for(other <- others, Prima.Refusal.message(other) == sentence, do: other)
      })
  end
end
