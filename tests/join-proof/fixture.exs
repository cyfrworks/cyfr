# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# What the join proof asks of a running server, evaluated inside it by
# `bin/cyfr rpc` (`join_fixture` in run.sh), beside the identity proof's
# own fixture (tests/identity-proof/fixture.exs). The file evaluates to a
# function of the argument list; each command prints nothing and answers
# one line, `FIXTURE=` and a JSON object. An argument spelled `@PATH` is
# read from that file, so a secret never rides a command line. No command
# answers a session token, a key or a confirmation's secret it was not
# handed.
#
#   console TOKEN TOOL ARGUMENTS_JSON [@CONFIRMATION_FILE]
#       TOOL called as the console calls it for the session TOKEN's person
#       (`PrismWeb.Ops.call_tool/4`, through the gate), repeated under the
#       confirmation the file names when one is given: `{ok}`,
#       `{confirmation_required: secret}` (which the caller keeps to
#       itself), or `{error}`.
#
#   person IDENTIFIER
#       The person this home admitted under IDENTIFIER: their row's
#       provenance, the athanors they own here (`athanors`), their own
#       athanor here by its route (`athanor_route`), the shared threads they sit in
#       (`threads`), their sessions (the athanor
#       each is bound to and the `key_epoch` it records) and their
#       passkeys here (state and the recovery epoch each is bound to), or
#       `{none: true}`.
#
#   pending_passkey USER_ID
#       The person's one pending passkey registration here: its id and
#       its registration digest, which an administrator authorizes.
#
#   post USER_ID THREAD_ID TEXT
#       A message of TEXT by the person in the shared thread THREAD_ID,
#       posted under their seat there (`Sanctum.SharedThreads.post/3`):
#       `{message_id}` or `{refused}`.
#
#   read THREAD_ID
#       The shared thread's messages, as `{texts: [...]}`.
#
#   tables
#       The tables of this home's database.
#
#   receipts IDENTIFIER
#       The login receipts this home recorded for the person under
#       IDENTIFIER: one per admission.
#
#   certifications USER_ID
#       What this home certified for the person's devices at other homes:
#       each record's other home, client, `key_epoch`, expiry and state.
#
#   directory
#       The directory this deployment enrolls at.
#
#   carry_actions IDENTIFIER
#       The sign-in carries the person under IDENTIFIER began here: each
#       action's destination, phase, outcome and whether it was asserted.
#
#   confirmations IDENTIFIER
#       The person's pending confirmations here, each its operation and
#       state.
#
#   paired IDENTIFIER
#       The person's paired clients here, each its athanor and standing.
#
#   door USER_ID SUB
#       The GitHub identity SUB linked to the person USER_ID, as a
#       completed GitHub sign-in links one (`Arca.Users.link_identity/3`),
#       so the release fixture's `person` command signs that person in by
#       it (tests/release-boot/fixture.exs): `{linked}`, false when the
#       identity was already theirs.

fn args ->
  import Ecto.Query, only: [from: 2]

  answer = fn map -> "FIXTURE=" <> Jason.encode!(map) end
  system = Prima.Actor.system()

  read = fn
    "@" <> path -> File.read!(path) |> String.trim()
    value -> value
  end

  # The person this home holds under an identifier, local or remote.
  user_ids = fn identifier ->
    case Arca.PersonIdentities.lookup_identifier(system, identifier) do
      {:ok, %{user_id: user_id}} -> [user_id]
      _none -> []
    end
  end

  refusal = fn
    reason when is_atom(reason) -> Atom.to_string(reason)
    {reason, _detail} when is_atom(reason) -> Atom.to_string(reason)
    %Prima.Refusal{reason: reason} when is_atom(reason) -> Atom.to_string(reason)
    reason -> inspect(reason)
  end

  case Enum.map(args, read) do
    ["console", token, tool, arguments | confirmation] ->
      {:ok, ctx} = Sanctum.Caller.establish({:session, token})
      opts = for id <- confirmation, do: {:confirmation_id, id}

      case PrismWeb.Ops.call_tool(ctx, tool, Jason.decode!(arguments), opts) do
        {:ok, result} ->
          answer.(%{ok: result})

        {:error, {:confirmation_required, %{id: id}}} ->
          answer.(%{confirmation_required: id})

        {:error, reason} ->
          answer.(%{error: refusal.(reason)})
      end

    ["person", identifier] ->
      case Arca.PersonIdentities.lookup_identifier(system, identifier) do
        {:ok, identity} ->
          user_id = identity.user_id

          athanors =
            Arca.Repo.all(
              from(a in Arca.Schemas.Athanor,
                where: a.owner_user_id == ^user_id and a.status == "active",
                select: a.id
              )
            )

          threads =
            Arca.Repo.all(
              from(m in Arca.Schemas.SharedThreadMember,
                where: m.user_id == ^user_id and m.status == "active",
                select: m.thread_id
              )
            )

          sessions =
            Arca.Repo.all(
              from(s in Arca.Schemas.Session,
                where: s.user_id == ^user_id,
                select: %{athanor_id: s.athanor_id, key_epoch: s.identity_key_epoch}
              )
            )

          passkeys =
            Arca.Repo.all(
              from(p in Arca.Schemas.Passkey,
                where: p.user_id == ^user_id,
                order_by: p.inserted_at,
                select: %{id: p.id, state: p.state, recovery_epoch: p.identity_recovery_epoch}
              )
            )

          athanor_route =
            case Sanctum.Tenancy.Athanors.get_by_owner(user_id) do
              {:ok, athanor} -> Sanctum.Tenancy.Athanors.route_slug(athanor)
              _none -> nil
            end

          answer.(%{
            user_id: user_id,
            provenance: identity.provenance,
            athanors: Enum.sort(athanors),
            athanor_route: athanor_route,
            threads: Enum.sort(threads),
            sessions: sessions,
            passkeys: passkeys
          })

        {:error, :not_found} ->
          answer.(%{none: true})
      end

    ["pending_passkey", user_id] ->
      case Arca.Repo.one(
             from(p in Arca.Schemas.Passkey,
               where: p.user_id == ^user_id and p.state == "pending",
               order_by: [desc: p.inserted_at],
               limit: 1
             )
           ) do
        nil -> answer.(%{none: true})
        row -> answer.(%{passkey_id: row.id, registration_digest: row.registration_digest})
      end

    ["post", user_id, thread_id, text] ->
      case Sanctum.SharedThreads.post(user_id, thread_id, text) do
        {:ok, message} -> answer.(%{message_id: message.id})
        {:error, reason} -> answer.(%{refused: refusal.(reason)})
      end

    ["read", thread_id] ->
      {:ok, messages} = Arca.SharedMessages.list(system, thread_id)
      answer.(%{texts: Enum.map(messages, & &1.content)})

    ["tables"] ->
      names =
        case Arca.Repo.adapter() do
          Ecto.Adapters.Postgres ->
            Ecto.Adapters.SQL.query!(
              Arca.Repo,
              "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'",
              []
            )

          _sqlite ->
            Ecto.Adapters.SQL.query!(
              Arca.Repo,
              "SELECT name FROM sqlite_master WHERE type = 'table'",
              []
            )
        end
        |> Map.fetch!(:rows)
        |> List.flatten()
        |> Enum.sort()

      answer.(%{tables: names})

    ["receipts", identifier] ->
      user_ids =
        case Arca.PersonIdentities.lookup_identifier(system, identifier) do
          {:ok, %{user_id: user_id}} -> [user_id]
          _none -> []
        end

      receipts =
        Arca.Repo.all(
          from(a in Arca.Schemas.CarryAction,
            where: a.kind == "login_receipt" and a.user_id in ^user_ids,
            select: %{action_id: a.action_id, source: a.source_home, key_epoch: a.key_epoch}
          )
        )

      answer.(%{receipts: receipts})

    ["certifications", user_id] ->
      rows =
        Arca.Repo.all(
          from(c in Arca.Schemas.DeviceCertification,
            where: c.user_id == ^user_id,
            select: %{
              audience: c.audience_home,
              client_id: c.client_id,
              key_epoch: c.key_epoch,
              expires_at: c.expires_at,
              state: c.state
            }
          )
        )

      answer.(%{certifications: rows})

    ["directory"] ->
      answer.(%{directory_url: Application.get_env(:sanctum, :directory_url)})

    ["carry_actions", identifier] ->
      user_ids = user_ids.(identifier)

      actions =
        Arca.Repo.all(
          from(a in Arca.Schemas.CarryAction,
            where: a.kind == "source" and a.user_id in ^user_ids,
            order_by: a.inserted_at,
            select: %{
              action_id: a.action_id,
              destination: a.destination_home,
              phase: a.phase,
              outcome: a.outcome,
              asserted: not is_nil(a.assertion_digest)
            }
          )
        )

      answer.(%{actions: actions})

    ["confirmations", identifier] ->
      user_ids = user_ids.(identifier)

      rows =
        Arca.Repo.all(
          from(c in Arca.Schemas.PendingConfirmation,
            where: c.user_id in ^user_ids,
            order_by: c.opened_at,
            select: %{operation: c.operation, state: c.state, proof: c.proof}
          )
        )

      answer.(%{confirmations: rows})

    ["paired", identifier] ->
      user_ids = user_ids.(identifier)

      rows =
        Arca.Repo.all(
          from(p in Arca.Schemas.PairedClient,
            where: p.user_id in ^user_ids,
            select: %{id: p.id, athanor_id: p.athanor_id, standing: p.standing}
          )
        )

      answer.(%{paired: rows})

    ["door", user_id, sub] ->
      key = Sanctum.Auth.Identity.builtin_key(:github, sub)

      {:ok, %{provider: provider, issuer: issuer, subject: subject}} =
        Sanctum.Auth.Identity.parse(key)

      {:ok, %{linked: linked}} =
        Arca.Users.link_identity(system, user_id, %{
          key: key,
          provider: provider,
          issuer: issuer,
          subject: subject
        })

      answer.(%{linked: linked})
  end
end
