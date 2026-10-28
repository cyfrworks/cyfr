# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SignInTest do
  @moduledoc """
  What a sign-in records, and linking a sign-in method. A linked method
  unlocks the person who linked it (`Sanctum.SignIn.unlock/1`): the door
  is asked about that person, their contact email is refreshed only from
  a claim the provider proved, and no person is ever made — an identity
  no person holds is `:no_person` and leaves no door request. A method is
  linked to a standing person under a fresh proof, and their last one
  goes only while they keep a way in.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.PersonIdentity
  alias Sanctum.SignIn
  alias Sanctum.Tenancy.{Athanors, Members, Users}
  alias Sanctum.Test.People

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp info(n, overrides \\ %{}) do
    Map.merge(
      %{
        id: "github|https://github.com|#{n}",
        provider: :github,
        email: "user#{n}@example.com",
        verified: true,
        name: "User #{n}"
      },
      overrides
    )
  end

  # A person whose keys another CYFR holds, linked to their CYFR identity.
  defp remote!(n) do
    identifier = "per_" <> Prima.Digest.sha256_hex("sign-in-#{n}")
    key = Sanctum.Auth.Identity.cyfr_key("https://dir.example", identifier)
    now = DateTime.utc_now()

    {:ok, user} =
      Arca.Test.People.mint(
        Prima.Actor.system(),
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          admission: "remote",
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        %{
          key: key,
          provider: "cyfr",
          issuer: "https://dir.example",
          subject: identifier,
          first_seen_at: now,
          last_seen_at: now
        }
      )

    {:ok, _} =
      Arca.PersonIdentities.create(Prima.Actor.system(), %{
        user_id: user.id,
        provenance: "remote",
        identifier: identifier,
        directory_url: "https://dir.example"
      })

    %{user: user, key: key, identifier: identifier}
  end

  describe "unlock/1" do
    test "answers the person who linked the method, and makes no one for an unlinked one" do
      n = System.unique_integer([:positive])
      {:ok, person} = People.linked(info(n))
      people = Arca.Repo.aggregate(Arca.Schemas.User, :count)

      assert {:ok, %{id: id}} = SignIn.unlock(info(n))
      assert id == person.id

      assert {:error, :no_person} = SignIn.unlock(info(n + 1))
      assert Arca.Repo.aggregate(Arca.Schemas.User, :count) == people
      assert Sanctum.Door.Store.list() == []
    end

    test "records the sign-in: last seen and the name, and an email only when the provider proved it" do
      n = System.unique_integer([:positive])
      {:ok, person} = People.linked(info(n, %{email: "first#{n}@example.com"}))

      {1, _} =
        Arca.Repo.update_all(from(u in Arca.Schemas.User, where: u.id == ^person.id),
          set: [last_seen_at: ~U[2026-01-01 00:00:00.000000Z]]
        )

      assert {:ok, unproved} =
               SignIn.unlock(
                 info(n, %{email: "said#{n}@example.com", verified: :unknown, name: "Said"})
               )

      assert unproved.email == "first#{n}@example.com"
      assert unproved.display_name == "Said"
      assert DateTime.compare(unproved.last_seen_at, ~U[2026-01-01 00:00:00.000000Z]) == :gt

      proved = "said#{n}@example.com"

      assert {:ok, %{email: ^proved, email_verified: true}} =
               SignIn.unlock(info(n, %{email: "Said#{n}@Example.com", verified: true}))

      assert {:ok, %{email: ^proved}} =
               SignIn.unlock(info(n, %{email: "other#{n}@example.com", verified: false}))
    end

    test "asks the door about the person: a denied one, or one no longer active, is refused" do
      n = System.unique_integer([:positive])
      {:ok, person} = People.linked(info(n))
      {:ok, deny} = Sanctum.Door.Store.deny("person", person.id, "ops")

      assert {:error, {:door, :denied}} = SignIn.unlock(info(n))
      :ok = Sanctum.Door.Store.remove(deny.id)
      assert {:ok, _} = SignIn.unlock(info(n))

      {:ok, _} = Users.deny(person)
      assert {:error, {:door, :denied}} = SignIn.unlock(info(n))
    end

    test "a remote person is admitted by * or their identifier, and an unadmitted one leaves one request" do
      n = System.unique_integer([:positive])
      %{user: user, key: key, identifier: identifier} = remote!(n)

      assert {:error, {:door, :not_allowed}} = SignIn.unlock(%{id: key, provider: "cyfr"})
      assert [%{kind: "identifier", value: ^identifier} = request] = Sanctum.Door.Store.requests()

      {:ok, _} = Sanctum.Door.Store.resolve(request.id, :allow, "ops")
      assert {:ok, %{id: id}} = SignIn.unlock(%{id: key, provider: "cyfr"})
      assert id == user.id
    end

    test "activates the invitations the person's CYFR identity holds" do
      n = System.unique_integer([:positive])
      {:ok, owner} = People.linked(info(n))
      %{user: user, key: key, identifier: identifier} = remote!(n)
      {:ok, _} = Sanctum.Door.Store.allow("identifier", identifier, "ops")
      {:ok, group} = Athanors.create_group(owner.id, "Invited #{n}")

      {:ok, _} =
        Members.create(%{
          person_identifier: identifier,
          scope: "athanor",
          status: "invited",
          athanor_id: group.id,
          added_by: owner.id
        })

      refute Members.member?(user.id, group.id)
      assert {:ok, _} = SignIn.unlock(%{id: key, provider: "cyfr"})
      assert Members.member?(user.id, group.id)
    end
  end

  test "record_namespace/2 lands the claim on the users row and refuses a slug another identity holds" do
    {:ok, %{id: uid, personal_athanor_id: pid}} = People.linked(info(6))

    assert {:ok, user} = SignIn.record_namespace(uid, "user6ns")
    assert user.namespace == "user6ns"
    assert {:ok, %{id: id}} = Users.get_by_namespace("user6ns")
    assert id == uid
    # the athanor was theirs since admission; the claim does not re-address it
    assert {:ok, %{personal_athanor_id: ^pid}} = Users.get(uid)
    assert {:ok, %{kind: "person"}} = Athanors.get(pid)
    assert Sanctum.Namespace.lookup(uid) == "user6ns"

    # Idempotent; a different slug from the registry keeps the recorded one.
    assert {:ok, %{namespace: "user6ns"}} = SignIn.record_namespace(uid, "user6ns")
    assert {:ok, %{namespace: "user6ns"}} = SignIn.record_namespace(uid, "user6other")

    # Another person cannot take it, and a malformed slug is refused.
    {:ok, %{id: jid}} = People.linked(info(7))

    assert {:error, :namespace_owned_by_another_identity} =
             SignIn.record_namespace(jid, "user6ns")

    assert {:error, :invalid_slug} = SignIn.record_namespace(jid, "Not A Slug")

    assert {:error, :not_found} = SignIn.record_namespace("usr_ghost", "ghost")
  end

  describe "linking a door" do
    # `*` admits the remote people these cases make, as their CYFR
    # sign-in was admitted.
    setup do
      Arca.Cache.init()
      {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")
      on_exit(fn -> Arca.Cache.delete_match({:established, :_, :_}) end)
      :ok
    end

    # A person seated in a group of their own, and a context their own
    # session establishes there.
    defp seated!(overrides \\ %{}) do
      n = System.unique_integer([:positive])
      {:ok, user} = People.linked(info(n, overrides))
      {:ok, athanor} = Athanors.create_group(user.id, "Link #{n}")
      {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: athanor.id)
      %{user: user, athanor: athanor, ctx: session_ctx(user, athanor)}
    end

    defp session_ctx(user, athanor) do
      built =
        Sanctum.Context.build(
          user_id: user.id,
          email: user.email,
          provider: "github",
          athanor_id: athanor.id,
          permissions: [:*],
          auth_method: :oidc,
          authenticated: true
        )

      {:ok, session} = Sanctum.TestContext.create_session(built)

      {:ok, ctx} =
        Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)

      ctx
    end

    defp oidc(n, overrides \\ %{}) do
      Map.merge(
        %{
          key: "oidcc|https://idp.test|link-#{n}",
          provider: "oidcc",
          email: "link-#{n}@idp.test",
          verified: true
        },
        overrides
      )
    end

    defp ticket!(person, identity) do
      {:ok, ticket} = SignIn.link_ticket(person.ctx, identity)
      ticket
    end

    # The link asked under the person's session, its record confirmed
    # through the confirmations' own store with `proof` (a proof no passkey
    # gave: `client_id` names the paired client it was given on, if any),
    # and the link repeated naming the record.
    defp linked_on(person, ticket, proof) do
      assert {:error, {:confirmation_required, %{id: id, operation: "person.link_door"}}} =
               SignIn.link_door(person.ctx, "oidcc", ticket)

      assert {:ok, %{state: "confirmed"}} =
               Arca.PendingConfirmations.confirm(
                 Sanctum.Context.actor(person.ctx),
                 Prima.Confirmation.ref(id),
                 proof
               )

      SignIn.link_door(%{person.ctx | confirmation_id: id}, "oidcc", ticket)
    end

    # A device paired to the person in their athanor through the ceremony:
    # its key made first, the invitation opened for its digest under the
    # person's proof, completed with that key. Answers its client id.
    defp paired_client!(person) do
      {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)
      digest = Prima.Device.key_digest(device_key)

      {:ok, invitation} =
        person.ctx
        |> Sanctum.TestContext.confirmed(
          :device_pairing,
          Sanctum.Pairing.invitation_change(digest)
        )
        |> Sanctum.Pairing.begin(%{"key_digest" => digest})

      source = "192.0.2.#{rem(System.unique_integer([:positive]), 250) + 1}"
      glass = Sanctum.Context.build(%{authenticated: false, client_ip: source})
      submission = %{device_key: device_key}

      {:ok, %{challenge: challenge}} =
        Sanctum.Pairing.complete(glass, invitation.invitation_secret, submission)

      proof = Prima.DeviceCert.Proof.encode(Prima.DeviceCert.Proof.sign(challenge, private))

      {:ok, %{client_id: client_id}} =
        Sanctum.Pairing.complete(
          glass,
          invitation.invitation_secret,
          Map.put(submission, :proof, proof)
        )

      client_id
    end

    # The person's first-method latch: set once a passkey or a paired
    # device ever existed for them.
    defp first_method_at(user_id) do
      Arca.Repo.one(
        from(p in PersonIdentity, where: p.user_id == ^user_id, select: p.first_method_at)
      )
    end

    test "a ticket is minted for a standing session and a linkable method" do
      person = seated!()
      n = System.unique_integer([:positive])

      assert {:ok, ticket} = SignIn.link_ticket(person.ctx, oidc(n))
      assert byte_size(ticket) == 43

      assert {:error, :not_linkable} =
               SignIn.link_ticket(person.ctx, oidc(n, %{key: "email|x|y", provider: "email"}))

      assert {:error, :not_linkable} =
               SignIn.link_ticket(
                 person.ctx,
                 oidc(n, %{key: "github|https://github.com|#{n}", provider: "oidcc"})
               )

      assert {:error, :unauthenticated} =
               SignIn.link_ticket(%{person.ctx | session_token_hash: nil}, oidc(n))

      assert {:error, :unauthenticated} =
               SignIn.link_ticket(%{person.ctx | plane: :guest}, oidc(n))

      # The door judges people, never a method: linking asks it nothing and
      # leaves no request.
      assert Sanctum.Door.Store.requests() == []
    end

    test "under a fresh proof the door is linked once, and the ticket is spent" do
      person = seated!()
      n = System.unique_integer([:positive])
      ticket = ticket!(person, oidc(n))

      assert {:ok, %{linked: true, door: door}} =
               Sanctum.TestContext.confirming(
                 person.ctx,
                 &SignIn.link_door(&1, "oidcc", ticket)
               )

      assert door == %{
               key: oidc(n).key,
               provider: "oidcc",
               issuer: "https://idp.test",
               subject: "link-#{n}"
             }

      assert {:ok, %{id: user_id}} = Users.get_by_identity(oidc(n).key)
      assert user_id == person.user.id

      # The ticket is spent, and the person's email is the one they had.
      assert {:error, {:invalid_argument, _}} = SignIn.link_door(person.ctx, "oidcc", ticket)
      assert {:ok, %{email: email}} = Users.get(person.user.id)
      assert email == person.user.email
    end

    test "a session alone is asked to confirm, and the ticket stays for the repeat" do
      person = seated!()
      n = System.unique_integer([:positive])
      ticket = ticket!(person, oidc(n))

      assert {:error, {:confirmation_required, %{operation: "person.link_door"}}} =
               SignIn.link_door(person.ctx, "oidcc", ticket)

      assert {:error, {:confirmation_required, _}} =
               SignIn.link_door(person.ctx, "oidcc", ticket)

      assert {:error, :not_found} = Users.get_by_identity(oidc(n).key)
    end

    test "once a passkey exists, a re-authentication no passkey or device gave links no door" do
      person = seated!()
      _auth = Sanctum.TestContext.passkey!(person.user.id)
      assert %DateTime{} = first_method_at(person.user.id)
      n = System.unique_integer([:positive])

      assert linked_on(person, ticket!(person, oidc(n)), %{proof: "oidc_reauth"}) ==
               {:error, Sanctum.Pairing.addition_refusal()}

      assert {:error, :not_found} = Users.get_by_identity(oidc(n).key)
    end

    test "once a device is paired, a confirmation given on that device links the door" do
      person = seated!()
      client_id = paired_client!(person)
      assert %DateTime{} = first_method_at(person.user.id)
      n = System.unique_integer([:positive])

      assert {:ok, %{linked: true}} =
               linked_on(person, ticket!(person, oidc(n)), %{
                 proof: "email_code",
                 client_id: client_id
               })

      assert {:ok, %{id: user_id}} = Users.get_by_identity(oidc(n).key)
      assert user_id == person.user.id
    end

    test "before any passkey or device, a re-authentication links the door" do
      person = seated!()
      assert first_method_at(person.user.id) == nil
      n = System.unique_integer([:positive])

      assert {:ok, %{linked: true}} =
               linked_on(person, ticket!(person, oidc(n)), %{proof: "oidc_reauth"})

      assert {:ok, %{id: user_id}} = Users.get_by_identity(oidc(n).key)
      assert user_id == person.user.id
    end

    test "a ticket answers only its person, their session and its provider" do
      person = seated!()
      n = System.unique_integer([:positive])
      ticket = ticket!(person, oidc(n))
      other = seated!()
      same_person_other_session = session_ctx(person.user, person.athanor)
      made_up = Prima.Identity.Encoding.b64(:crypto.strong_rand_bytes(32))

      for {ctx, provider, presented} <- [
            {other.ctx, "oidcc", ticket},
            {same_person_other_session, "oidcc", ticket},
            {person.ctx, "github", ticket},
            {person.ctx, "oidcc", made_up}
          ] do
        assert {:error, {:invalid_argument, message}} =
                 SignIn.link_door(ctx, provider, presented)

        assert message =~ "not yours, has expired or was already used"
      end

      # A door is linked by its ticket, never by a matching email.
      assert {:error, :not_found} = Users.get_by_identity(oidc(n).key)
      assert {:error, {:invalid_argument, _}} = SignIn.link_door(person.ctx, "email", ticket)
      assert {:error, {:invalid_argument, _}} = SignIn.link_door(person.ctx, "passkey", ticket)

      assert {:error, :not_linkable} =
               SignIn.link_ticket(
                 person.ctx,
                 oidc(n, %{key: "passkey|https://idp.test|#{n}", provider: "passkey"})
               )
    end

    test "another person's identity is a conflict" do
      person = seated!()
      other = seated!()
      {:ok, [taken]} = Arca.Users.identities(Prima.Actor.system(), other.user.id)

      ticket =
        ticket!(person, %{key: taken.key, provider: "github", email: nil, verified: :unknown})

      assert {:error, {:conflict, _}} = SignIn.link_door(person.ctx, "github", ticket)
    end

    test "a remote person links a door only under a fresh proof here, and its sessions carry the fresh head's key_epoch" do
      tls = Sanctum.Test.DirectoryServer.tls()
      Sanctum.Test.DirectoryServer.listen!()
      Sanctum.Test.DirectoryServer.seam!(tls)
      directory = Sanctum.Test.DirectoryServer.start!(tls)
      identity = Sanctum.Test.DirectoryServer.identity!(directory.dir, directory.url)

      # No email, as the `cyfr` door admits a person: no one-time code can
      # reach them, so before a passkey here they hold no fresh method at
      # this home (`Sanctum.Passkeys.fresh_method?/1`) and their first one
      # waits for the administrator.
      person = seated!(%{email: nil, verified: :unknown})
      :ok = Sanctum.Test.DirectoryServer.remote_person!(person.user.id, identity)
      refute Sanctum.Passkeys.fresh_method?(person.ctx)
      # A session minted now records the head read fresh from the directory.
      person = %{person | ctx: session_ctx(person.user, person.athanor)}
      n = System.unique_integer([:positive])
      ticket = ticket!(person, oidc(n))

      # A session alone attaches no door: the proof is asked here.
      assert {:error, {:confirmation_required, _}} =
               SignIn.link_door(person.ctx, "oidcc", ticket)

      assert {:error, :not_found} = Users.get_by_identity(oidc(n).key)

      # A passkey registered here, which the administrator authorized for
      # them, proves it.
      authorized_passkey!(person, identity)

      assert {:ok, %{linked: true}} =
               Sanctum.TestContext.confirming(person.ctx, &SignIn.link_door(&1, "oidcc", ticket))

      assert {:ok, %{id: user_id}} = Users.get_by_identity(oidc(n).key)
      assert user_id == person.user.id

      # The person stays remote, whichever door they come through, and a
      # session minted through the linked door binds the head's key_epoch.
      assert {:ok, %{provenance: "remote"}} =
               Arca.PersonIdentities.get(Prima.Actor.system(), user_id)

      linked = session_ctx(person.user, person.athanor)

      assert {:ok, %{identity_key_epoch: epoch}} =
               Arca.SessionStorage.get_session(linked.session_token_hash)

      assert epoch == Sanctum.Test.DirectoryServer.key_epoch(identity)

      # Retired at the next fresh head once a rotation moves the key epoch.
      Sanctum.Test.DirectoryServer.rotate!(directory.dir, identity)
      {:ok, _} = Sanctum.IdentityFreshness.fresh!(identity.identifier)
      assert {:error, :not_found} = Arca.SessionStorage.get_session(linked.session_token_hash)
    end

    test "a door a remote person linked here signs them in no more once a recovery replaced their live key, and is no fresh method" do
      tls = Sanctum.Test.DirectoryServer.tls()
      Sanctum.Test.DirectoryServer.listen!()
      Sanctum.Test.DirectoryServer.seam!(tls)
      directory = Sanctum.Test.DirectoryServer.start!(tls)
      identity = Sanctum.Test.DirectoryServer.identity!(directory.dir, directory.url)

      person = seated!(%{email: nil, verified: :unknown})
      :ok = Sanctum.Test.DirectoryServer.remote_person!(person.user.id, identity)
      person = %{person | ctx: session_ctx(person.user, person.athanor)}
      # A door that names no email, so no one-time code is a fresh method
      # of theirs here either.
      door = oidc(System.unique_integer([:positive]), %{email: nil, verified: :unknown})
      ticket = ticket!(person, door)
      authorized_passkey!(person, identity)

      assert {:ok, %{linked: true}} =
               Sanctum.TestContext.confirming(person.ctx, &SignIn.link_door(&1, "oidcc", ticket))

      # Linked, the door signs the person in.
      assert {:ok, %{id: user_id}, _session} = door_sign_in(door)
      assert user_id == person.user.id

      # The person recovers at their directory with new keys. This home has
      # not read the new head yet, so the door still names them here until
      # the sign-in's own fresh read finds the recovery, which retires the
      # door before any session is issued through it.
      Sanctum.Test.DirectoryServer.recover!(directory.dir, identity)
      assert {:ok, %{id: ^user_id}} = Users.get_by_identity(door.key)

      assert {:error, :unauthenticated} = door_sign_in(door)
      assert {:error, :not_found} = Users.get_by_identity(door.key)

      # With the passkey the recovery retired, the door was their fresh
      # method here; it is not one any more.
      refute Sanctum.Passkeys.fresh_method?(person.ctx)

      # The method names no one here now: signing in through it again makes
      # no one, and is refused as no person's.
      assert {:error, :no_person} = door_sign_in(door)
      assert {:error, :not_found} = Users.get_by_identity(door.key)
    end

    # A sign-in through a linked method as the browser callback runs it
    # (`PrismWeb.AuthController`): the method's context names the identity
    # and the door itself, the person is unlocked, the context is renamed
    # to the person and resolved, and the session is issued.
    defp door_sign_in(identity) do
      ctx =
        Sanctum.Context.build(
          user_id: identity.key,
          door: identity.key,
          email: identity.email,
          provider: identity.provider,
          athanor_id: nil,
          permissions: Sanctum.Context.person_permissions()
        )

      user_info = %{
        id: identity.key,
        provider: identity.provider,
        email: identity.email,
        verified: identity.verified,
        name: nil
      }

      with {:ok, user} <- SignIn.unlock(user_info),
           {:ok, ctx} <- Sanctum.Tenancy.resolve_status(%{ctx | user_id: user.id}, force: true),
           {:ok, session} <- Sanctum.Session.create(ctx) do
        {:ok, user, session}
      end
    end

    # The person's software passkey registered here and activated as the
    # administrator's authorization activates it, bound to their recovery
    # epoch: the remote person's one way to a fresh proof here.
    defp authorized_passkey!(person, identity) do
      auth = Sanctum.TestContext.Authenticator.for_person(person.user.id)
      {:ok, options} = Sanctum.Passkeys.register(person.ctx, %{})
      credential = Sanctum.TestContext.Authenticator.registration(auth, options)

      assert {:ok, %{status: "awaiting_administrator", passkey_id: id} = pending} =
               Sanctum.Passkeys.register(person.ctx, %{credential: credential})

      epoch = Sanctum.Test.DirectoryServer.key_epoch(identity)

      {:ok, _} =
        Arca.Passkeys.activate(Prima.Actor.system(), id,
          registration_digest: pending.registration_digest,
          identity_key_epoch: epoch,
          identity_recovery_epoch: Sanctum.Test.DirectoryServer.recovery_epoch(identity)
        )

      auth
    end

    test "unlinking takes the person's own door under proof, never their last while no passkey" do
      person = seated!()
      {:ok, [github]} = Arca.Users.identities(Prima.Actor.system(), person.user.id)

      assert {:error, {:conflict, message}} = SignIn.unlink_door(person.ctx, github.key)
      assert message =~ "hold no passkey"
      assert message =~ "link another sign-in method"

      other = seated!()
      {:ok, [theirs]} = Arca.Users.identities(Prima.Actor.system(), other.user.id)

      assert {:error, {:not_found, "sign-in method", _}} =
               SignIn.unlink_door(person.ctx, theirs.key)

      # With a second door linked, the first goes under its own proof.
      n = System.unique_integer([:positive])
      ticket = ticket!(person, oidc(n))

      {:ok, _} =
        Sanctum.TestContext.confirming(person.ctx, &SignIn.link_door(&1, "oidcc", ticket))

      assert {:error, {:confirmation_required, %{operation: "person.unlink_door"}}} =
               SignIn.unlink_door(person.ctx, github.key)

      assert {:ok, %{unlinked: %{key: key}}} =
               Sanctum.TestContext.confirming(person.ctx, &SignIn.unlink_door(&1, github.key))

      assert key == github.key
      assert {:error, :not_found} = Users.get_by_identity(github.key)

      # The person holds a passkey here now, so the last door may go too.
      assert {:ok, %{unlinked: _}} =
               Sanctum.TestContext.confirming(
                 person.ctx,
                 &SignIn.unlink_door(&1, oidc(n).key)
               )

      assert {:ok, []} = Arca.Users.identities(Prima.Actor.system(), person.user.id)
    end

    test "the last door goes only while the door admits the person without it" do
      person = seated!()
      {:ok, [github]} = Arca.Users.identities(Prima.Actor.system(), person.user.id)
      # A passkey here, so only the door's admission is in question.
      auth = Sanctum.TestContext.passkey!(person.user.id)

      # A deny naming the person, written while their session stands: the
      # door would admit them through no way at all, so the last method is
      # kept, before any proof is asked.
      {:ok, deny} = Sanctum.Door.Store.deny("person", person.user.id, "ops")
      assert {:error, {:conflict, message}} = SignIn.unlink_door(person.ctx, github.key)
      assert message =~ "ask the operator"
      assert message =~ "link another sign-in method"
      assert {:ok, _person} = Users.get_by_identity(github.key)

      # A local person is admitted unless denied: with the deny gone, the
      # method goes, and the passkey signs them in.
      :ok = Sanctum.Door.Store.remove(deny.id)

      assert {:ok, %{unlinked: %{key: key}}} =
               Sanctum.TestContext.confirming(person.ctx, &SignIn.unlink_door(&1, github.key))

      assert key == github.key
      held = Sanctum.Passkeys.sign_in_challenge()

      assert {:ok, %{session_token: _}} =
               Sanctum.Passkeys.sign_in(
                 held,
                 Sanctum.TestContext.Authenticator.assertion(auth, held.challenge)
               )
    end
  end
end
