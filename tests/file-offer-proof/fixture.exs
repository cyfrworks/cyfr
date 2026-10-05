# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The file-offer proof's part in the running server, evaluated inside it by
# `bin/cyfr rpc` (tests/file-offer-proof/run.sh `offer_fixture`). The file
# evaluates to a function of the argument list; each command answers one
# line, `OFFER=` and a JSON object. Every step a person takes is the
# proof's, in the browser (proof.mjs). What is here seeds the three people,
# their group and the sender's files through the paths a sign-in and the
# console take, and reads back what the steps committed. Of the files'
# bytes it reads the accepted copy's alone, and answers its digest, its
# size and its first bytes, never the rest.
#
#   person EMAIL SUB NAME
#       The GitHub identity SUB with the verified EMAIL and the name NAME,
#       signed in as the device flow signs one in, from the door on
#       (`Sanctum.Door`, `Sanctum.SignIn.admitted/2`, the session), as the
#       release fixture's `person` does (tests/release-boot/fixture.exs):
#       the person, their own athanor, its route segment, their namespace
#       and the session token.
#
#   admit SESSION_TOKEN EMAIL
#       EMAIL let in at the door by the session's person, an operator, as
#       the console lets one in (`door.allow` through the gate).
#
#   group SESSION_TOKEN USER_ID NAME
#       A group NAME created by the session's person and the person USER_ID
#       added to it, as the console does both (`athanor.create`, then
#       `member.add` through the gate).
#
#   file SESSION_TOKEN PATH BASE64
#       The bytes BASE64 written at PATH in the athanor the session is
#       focused on, as the Files page uploads a file (`file.write` through
#       the gate).
#
#   settle USER_ID...
#       Each person's own athanor once its first fill has completed: the
#       fill, announced at sign-in, writes into its tree, and the storage
#       counts are read from the whole tree. Waits, at most two minutes in
#       all, until each reads `ready` or `failed`, then answers each
#       athanor's state.
#
#   facts SENDER_ID RECIPIENT_ID OUTSIDER_ID
#       What the three people's own athanors hold, each read under that
#       person's own actor: the offers sent from the sender's athanor and
#       those addressed to the recipient and to the outsider, the receipts
#       in the recipient's and the outsider's athanors, the bytes each
#       offer's snapshot and custody copy hold, each athanor's storage
#       usage (the whole tree as the storage cap walks it, `data/` and
#       `payloads/`, and the cap's cached total), and, for each receipt
#       that records a published path, the bytes at that path read under
#       the recipient's actor. The rows are the store's own reads
#       (`Arca.FileOffers`), since `file.offers` lists no receipt once it
#       has completed.
#
# A step that does not answer `{:ok, _}` raises, and the rpc exits non-zero
# naming it.

fn args ->
  answer = fn map -> "OFFER=" <> Jason.encode!(map) end

  # The person's context as a session reaches it, focused on their own
  # athanor.
  person_ctx = fn user_id ->
    {:ok, user} = Sanctum.Tenancy.Users.get(user_id)

    ctx =
      Sanctum.Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: nil,
        permissions: Sanctum.Context.person_permissions()
      )

    {:ok, ctx} = Sanctum.Tenancy.resolve_status(%{ctx | namespace: user.namespace}, force: true)
    {:ok, own} = Sanctum.Tenancy.Users.personal_athanor_id(user.id)
    {:ok, ctx} = Sanctum.Context.focus(ctx, own)
    ctx
  end

  actor = fn user_id -> user_id |> person_ctx.() |> Sanctum.Context.actor() end

  segment = fn athanor_id ->
    {:ok, athanor} = Sanctum.Tenancy.Athanors.get(athanor_id)
    Sanctum.Tenancy.Athanors.route_slug(athanor)
  end

  # A tool called as the console calls it for the session's person
  # (`PrismWeb.Ops.call_tool/3`, through the gate).
  console = fn token, tool, arguments ->
    {:ok, ctx} = Sanctum.Caller.establish({:session, token})

    case PrismWeb.Ops.call_tool(ctx, tool, arguments) do
      {:ok, result} -> result
      {:error, reason} -> raise "#{tool} was refused: #{inspect(reason)}"
    end
  end

  bytes_under = fn who, path ->
    {:ok, %{bytes: bytes}} = Arca.usage(who, path)
    bytes
  end

  usage = fn who ->
    {:ok, cap} = Arca.Usage.athanor_bytes(who)

    %{
      total: bytes_under.(who, []),
      data: bytes_under.(who, ["data"]),
      payloads: bytes_under.(who, ["payloads"]),
      cap: cap
    }
  end

  offer_fact = fn row ->
    Map.take(row, [
      :offer_id,
      :filename,
      :size,
      :digest,
      :status,
      :sender_user_id,
      :recipient_user_id
    ])
  end

  receipt_fact = fn row ->
    Map.take(row, [
      :offer_id,
      :filename,
      :size,
      :digest,
      :status,
      :folder,
      :attempt_path,
      :attempt_state,
      :ever_issued,
      :recipient_user_id,
      :sender_user_id
    ])
  end

  case args do
    ["person", email, sub, name] ->
      identity = Sanctum.Auth.Identity.builtin_key(:github, sub)

      user_info = %{
        id: identity,
        provider: :github,
        email: email,
        verified: true,
        name: name
      }

      {:ok, verdict} = Sanctum.Door.admit_identity(identity, user_info)
      {:ok, user} = Sanctum.SignIn.admitted(user_info, verdict)
      ctx = person_ctx.(user.id)
      {:ok, session} = Sanctum.Session.create(ctx)
      {:ok, user} = Sanctum.Tenancy.Users.get(user.id)

      answer.(%{
        user_id: user.id,
        email: user.email,
        name: user.display_name,
        namespace: user.namespace,
        athanor_id: ctx.athanor_id,
        segment: segment.(ctx.athanor_id),
        token: session.token
      })

    ["admit", token, email] ->
      entry = console.(token, "door/allow", %{"value" => email, "kind" => "email"})
      answer.(%{allowed: email, entry: Map.get(entry, :id)})

    ["group", token, user_id, name] ->
      group = console.(token, "athanor/create", %{"name" => name})

      added =
        console.(token, "member/add", %{"athanor" => group.id, "user_id" => user_id})

      answer.(%{id: group.id, slug: group.slug, route: group.route, added: added.state})

    ["file", token, path, base64] ->
      console.(token, "file/write", %{
        "path" => path,
        "content" => base64,
        "encoding" => "base64"
      })

      answer.(%{path: path, size: byte_size(Base.decode64!(base64))})

    ["settle" | user_ids] ->
      deadline = System.monotonic_time(:millisecond) + 120_000

      states =
        Map.new(user_ids, fn user_id ->
          ctx = person_ctx.(user_id)

          # Sign-in only announces the fill, so an athanor not yet claimed
          # reads `:unfilled`, and a store that cannot answer `:unavailable`:
          # both are waited past, as `:filling` is. `:ready` is the fill
          # completed; `:failed` is a fill that ended without completing.
          state =
            Enum.reduce_while(Stream.repeatedly(fn -> :tick end), nil, fn :tick, _ ->
              case Sanctum.Provisioning.status(ctx) do
                settled when settled in [:ready, :failed] ->
                  {:halt, settled}

                waiting ->
                  if System.monotonic_time(:millisecond) > deadline do
                    {:halt, waiting}
                  else
                    Process.sleep(250)
                    {:cont, waiting}
                  end
              end
            end)

          {user_id, state}
        end)

      answer.(%{states: states})

    ["facts", sender_id, recipient_id, outsider_id] ->
      sender = actor.(sender_id)
      recipient = actor.(recipient_id)
      outsider = actor.(outsider_id)

      {:ok, outbox} = Arca.FileOffers.outbox(sender)
      {:ok, inbox} = Arca.FileOffers.inbox(recipient)
      {:ok, outsider_inbox} = Arca.FileOffers.inbox(outsider)
      {:ok, outsider_outbox} = Arca.FileOffers.outbox(outsider)
      {:ok, receipts} = Arca.FileOffers.receipts(recipient)
      {:ok, outsider_receipts} = Arca.FileOffers.receipts(outsider)

      offer_ids = (outbox ++ inbox) |> Enum.map(& &1.offer_id) |> Enum.uniq()

      landed =
        for %{attempt_path: path, status: status} = receipt <- receipts,
            is_binary(path) and status in ["published", "completed"] do
          {:ok, bytes} = Arca.get(recipient, String.split(path, "/"))

          %{
            offer_id: receipt.offer_id,
            path: path,
            size: byte_size(bytes),
            sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
            head: binary_part(bytes, 0, min(byte_size(bytes), 48))
          }
        end

      answer.(%{
        outbox: Enum.map(outbox, offer_fact),
        inbox: Enum.map(inbox, offer_fact),
        outsider_inbox: Enum.map(outsider_inbox, offer_fact),
        outsider_outbox: Enum.map(outsider_outbox, offer_fact),
        receipts: Enum.map(receipts, receipt_fact),
        outsider_receipts: Enum.map(outsider_receipts, receipt_fact),
        snapshots: Map.new(offer_ids, &{&1, bytes_under.(sender, ["payloads", "offers", &1])}),
        custody: Map.new(offer_ids, &{&1, bytes_under.(recipient, ["payloads", "receipts", &1])}),
        usage: %{
          sender: usage.(sender),
          recipient: usage.(recipient),
          outsider: usage.(outsider)
        },
        landed: landed
      })
  end
end
