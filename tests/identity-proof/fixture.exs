# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# What the identity proof asks of a running server, evaluated inside it by
# `bin/cyfr rpc` (`identity_fixture` in cells.sh). The file evaluates to a
# function of the argument list; each command prints nothing and answers
# one line, `FIXTURE=` and a JSON object. An argument spelled `@PATH` is
# read from that file, so a credential never rides a command line. No
# command answers a seed, a kit line, a token or a private key.
#
#   first_sign_in EMAIL SUB
#       A GitHub identity's first sign-in through the door, as the device
#       flow's completion makes it: `{admitted: user_id}` or `{refused:
#       reason}`. On a restore-reserved installation it is refused.
#
#   genesis USER_ID
#       The person's identifier and the genesis their identity rests on
#       (`Arca.IdentityAttempts.genesis/2`), as the JSON map a relying home
#       is handed.
#
#   head USER_ID
#       The person's identity row: provenance, identifier, enrollment, head
#       and live public key (unpadded base64url).
#
#   resolve IDENTIFIER @GENESIS_FILE
#       This home reads the identity's head live at the directory its
#       genesis names and caches it (`Sanctum.IdentityFreshness.fresh!/2`):
#       what a relying home holds of a person, and nothing else.
#
#   fresh IDENTIFIER
#       The head this home trusts now (`fresh?/2`): the cached one within
#       `identity_freshness_seconds`, else read again; `{refused:
#       "identity_stale"}` past the bound with the directory unreachable.
#
#   thief_rotate USER_ID
#       What a thief holding a copy of the person's home does with it: a
#       rotation signed with the operational key the copy holds, extending
#       the head the copy names, sent to the directory. `{accepted: hash,
#       live_key}` or `{refused: reason, live_key}`.
#
#   log IDENTIFIER
#       The directory's log of the identity, at the cell that serves it:
#       its length, head and the kind of each entry.
#
#   restores
#       This installation's restore attempts: phase, outcome, request id
#       and the entry hash an acceptance recorded.
#
#   replay_recover
#       The recovery this installation's restore submitted, sent to the
#       directory again unchanged: the directory's answer, its recorded
#       outcome.
#
#   placeholder_athanor
#       An athanor no person owns, so a cap of one athanor refuses the next.
#
#   people
#       The person rows this installation holds, and for each its paired
#       clients and passkeys.
#
#   segment USER_ID
#       The route segment of the person's own athanor.
#
#   link_ticket @COOKIE_FILE KEY
#       The browser session the cookie in COOKIE_FILE holds, given a link
#       ticket for the GitHub identity KEY as a completed sign-in with that
#       door leaves one (`Sanctum.SignIn.link_ticket/2`, after the door
#       admits KEY), in its cookie session under the key the settings page
#       reads (`PrismWeb.AuthController.link_ticket_key/0`): `{cookie}`,
#       the new cookie value.

fn args ->
  answer = fn map -> "FIXTURE=" <> Jason.encode!(map) end
  system = Prima.Actor.system()
  b64 = &Prima.Identity.Encoding.b64/1

  read = fn
    "@" <> path -> File.read!(path) |> String.trim()
    value -> value
  end

  refusal = fn
    reason when is_atom(reason) -> Atom.to_string(reason)
    {reason, _detail} when is_atom(reason) -> Atom.to_string(reason)
    reason -> inspect(reason)
  end

  key_epoch = fn
    %{key_epoch: epoch} -> epoch
    head -> inspect(head)
  end

  case Enum.map(args, read) do
    ["first_sign_in", email, sub] ->
      identity = Sanctum.Auth.Identity.builtin_key(:github, sub)
      info = %{id: identity, provider: :github, email: email, verified: true, name: "Identity proof"}

      with {:ok, verdict} <- Sanctum.Door.admit_identity(identity, info),
           {:ok, user} <- Sanctum.SignIn.admitted(info, verdict) do
        answer.(%{admitted: user.id})
      else
        {:error, reason} -> answer.(%{refused: refusal.(reason)})
      end

    ["genesis", user_id] ->
      {:ok, %{genesis: genesis, identifier: identifier, directory_url: url}} =
        Arca.IdentityAttempts.genesis(system, user_id)

      answer.(%{identifier: identifier, directory_url: url, genesis: Jason.decode!(genesis)})

    ["head", user_id] ->
      {:ok, row} = Arca.PersonIdentities.get(system, user_id)

      answer.(%{
        provenance: row.provenance,
        identifier: row.identifier,
        enrollment: row.enrollment,
        head: row.head_hash,
        live_key: row.live_public_key && b64.(row.live_public_key)
      })

    ["resolve", identifier, genesis] ->
      case Sanctum.IdentityFreshness.fresh!(identifier, genesis: Jason.decode!(genesis)) do
        {:ok, head} -> answer.(%{key_epoch: key_epoch.(head)})
        {:refused, reason} -> answer.(%{refused: refusal.(reason)})
        {:error, reason} -> answer.(%{error: refusal.(reason)})
      end

    ["fresh", identifier] ->
      case Sanctum.IdentityFreshness.fresh?(identifier) do
        {:ok, head} -> answer.(%{key_epoch: key_epoch.(head)})
        {:refused, reason} -> answer.(%{refused: refusal.(reason)})
        {:error, reason} -> answer.(%{error: refusal.(reason)})
      end

    ["thief_rotate", user_id] ->
      {:ok, row} = Arca.PersonIdentities.get(system, user_id)
      {:ok, %{genesis: genesis}} = Arca.IdentityAttempts.genesis(system, user_id)

      case Sanctum.Person.sign_rotate(user_id, row.head_hash) do
        {:ok, %{entry: entry, staged_live_public_key: live}} ->
          case Sanctum.Directory.Client.append(row.identifier, genesis, entry) do
            {:ok, %{entry_hash: hash}} -> answer.(%{accepted: hash, live_key: b64.(live)})
            {:error, reason} -> answer.(%{refused: refusal.(reason), live_key: b64.(live)})
          end

        {:error, reason} ->
          answer.(%{refused: refusal.(reason)})
      end

    ["log", identifier] ->
      case Sanctum.Directory.resolve(%{identifier: identifier, after: nil, source: "127.0.0.1"}) do
        {:ok, page} ->
          kinds =
            for entry <- Map.get(page, :entries, []) do
              case Jason.decode(entry) do
                {:ok, %{"kind" => kind}} -> kind
                _other -> "unknown"
              end
            end

          answer.(%{length: Map.get(page, :length), head: Map.get(page, :head), kinds: kinds})

        {:error, reason} ->
          answer.(%{error: refusal.(reason)})
      end

    ["restores"] ->
      import Ecto.Query, only: [from: 2]

      rows =
        Arca.Repo.all(
          from(a in Arca.Schemas.IdentityAttempt,
            where: a.kind == "restore",
            order_by: a.inserted_at,
            select: %{
              phase: a.phase,
              outcome: a.outcome,
              request_id: a.request_id,
              entry_hash: a.entry_hash,
              staged: not is_nil(a.staged_live_key_sealed)
            }
          )
        )

      answer.(%{restores: rows})

    ["replay_recover"] ->
      import Ecto.Query, only: [from: 2]

      [attempt | _] =
        Arca.Repo.all(
          from(a in Arca.Schemas.IdentityAttempt,
            where: a.kind == "restore",
            order_by: [desc: a.inserted_at]
          )
        )

      request = Jason.decode!(attempt.entry)

      case Sanctum.Directory.Client.recover(attempt.identifier, attempt.genesis, request) do
        {:ok, %{entry_hash: hash}} ->
          answer.(%{entry_hash: hash, recorded: attempt.entry_hash})

        {:error, reason} ->
          answer.(%{refused: refusal.(reason), recorded: attempt.entry_hash})
      end

    ["placeholder_athanor"] ->
      {:ok, athanor} =
        Sanctum.Tenancy.Athanors.create_for_operator(%{
          kind: "group",
          name: "Placeholder",
          slug: "placeholder-#{System.unique_integer([:positive])}",
          created_by: "identity-proof"
        })

      answer.(%{athanor_id: athanor.id})

    ["people"] ->
      import Ecto.Query, only: [from: 2]
      {:ok, users} = Arca.Users.list(system, limit: 100)

      people =
        for user <- users do
          clients =
            Arca.Repo.aggregate(
              from(c in Arca.Schemas.PairedClient, where: c.user_id == ^user.id),
              :count
            )

          {:ok, passkeys} = Arca.Passkeys.list(system, user.id, state: :all)

          %{
            user_id: user.id,
            provider: user.provider,
            paired_clients: clients,
            passkeys: Enum.map(passkeys, & &1.state)
          }
        end

      answer.(%{people: people})

    ["segment", user_id] ->
      {:ok, user} = Sanctum.Tenancy.Users.get(user_id)
      {:ok, athanor} = Sanctum.Tenancy.Athanors.get(user.personal_athanor_id)
      answer.(%{segment: "@" <> athanor.slug})

    ["link_ticket", cookie, key] ->
      opts = Plug.Session.init(CyfrWeb.Endpoint.session_options())
      session_key = CyfrWeb.SignInResponse.session_key()

      held =
        Plug.Test.conn(:get, "/")
        |> Map.put(:secret_key_base, CyfrWeb.Endpoint.config(:secret_key_base))
        |> Plug.Test.put_req_cookie("_cyfr_key", cookie)
        |> Plug.Session.call(opts)
        |> Plug.Conn.fetch_session()

      {:ok, ctx} = Sanctum.Caller.establish(Plug.Conn.get_session(held, session_key))
      {:ok, _entry} = Sanctum.Door.Store.allow("user_id", key, "identity-proof")

      {:ok, ticket} =
        Sanctum.SignIn.link_ticket(ctx, %{key: key, provider: "github", email: nil})

      conn =
        held
        |> Plug.Conn.put_session(PrismWeb.AuthController.link_ticket_key(), %{
          "provider" => "github",
          "ticket" => ticket
        })
        |> Plug.Conn.send_resp(200, "")

      %{value: value} = Map.fetch!(conn.resp_cookies, "_cyfr_key")
      answer.(%{cookie: value})
  end
end
