# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SignInTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Arca.InstallationClaims
  alias Arca.Schemas.{ExternalIdentity, PersonIdentity, User}
  alias Sanctum.SignIn
  alias Sanctum.Tenancy.{Athanors, Members, Users}

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

  test "an admitted person gets a users row, refreshed on every sign-in" do
    i = info(1)
    assert {:ok, user} = SignIn.admitted(i, :allowed)
    # The person's id is this server's; the identity that signed in names it.
    assert Arca.Schemas.User.person_id?(user.id)
    assert {:ok, %{id: same}} = Users.get_by_identity(i.id)
    assert same == user.id
    assert user.email == "user1@example.com"
    assert user.display_name == "User 1"
    assert user.email_verified
    first = user.first_seen_at

    assert {:ok, again} = SignIn.admitted(%{i | name: "Renamed"}, :allowed)
    assert again.id == user.id
    assert again.first_seen_at == first
    assert again.display_name == "Renamed"
    assert DateTime.compare(again.last_seen_at, first) in [:gt, :eq]
  end

  test "a person the cyfr door admits is remote here: no key, and no athanor of their own" do
    identifier = "per_" <> Prima.Digest.sha256_hex("remote-#{System.unique_integer()}")
    key = Sanctum.Auth.Identity.cyfr_key("https://dir.example", identifier)

    info = %{
      id: key,
      provider: "cyfr",
      email: nil,
      verified: :unknown,
      name: nil,
      remote: %{
        identifier: identifier,
        directory_url: "https://dir.example",
        head_hash: Prima.Digest.sha256("head")
      }
    }

    before = counts()
    assert {:ok, user} = SignIn.admitted(info, :allowed)

    row = identity_row!(user.id)
    assert row.provenance == "remote"
    assert row.identifier == identifier
    assert row.directory_url == "https://dir.example"
    assert is_nil(row.live_key_sealed) and is_nil(row.operational_key_sealed)
    assert Users.personal_athanor_id(user.id) == :none
    assert counts().people == before.people + 1

    # Admitted again by the same identifier: the same person, one row.
    assert {:ok, %{id: same}} = SignIn.admitted(info, :allowed)
    assert same == user.id
    assert identity_rows(user.id) == 1
    assert counts().people == before.people + 1
  end

  test "a local person keeps their provenance whichever door admits them" do
    i = info(System.unique_integer([:positive]))
    {:ok, user} = SignIn.admitted(i, :allowed)
    assert identity_row!(user.id).provenance == "local"

    # A later sign-in carrying another provenance changes nothing: the
    # person, and their key set, are as they were minted.
    identifier = "per_" <> Prima.Digest.sha256_hex("not-theirs-#{System.unique_integer()}")

    assert {:ok, %{id: same}} =
             SignIn.admitted(
               Map.put(i, :remote, %{identifier: identifier, directory_url: "https://dir.example"}),
               :allowed
             )

    assert same == user.id
    assert identity_row!(user.id).provenance == "local"
    assert is_binary(identity_row!(user.id).live_key_sealed)
  end

  test "an operator gets the platform row, minted once and audited once" do
    handler = "signin-test-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:cyfr, :sanctum, :tenancy, :platform_admin_bootstrap],
      fn _e, _m, meta, _c -> send(parent, {:bootstrap, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    i = info(2)
    assert {:ok, user} = SignIn.admitted(i, :admin)
    assert_receive {:bootstrap, %{user_id: uid}}
    assert uid == user.id

    rows = rows!(Members.list_by_user(user.id))
    assert Enum.any?(rows, &(&1.scope == "platform"))

    assert {:ok, _} = SignIn.admitted(i, :admin)
    refute_receive {:bootstrap, _}
    # the platform row and the seat in their own athanor, and nothing else:
    # no athanor is shared server-wide for an operator to be seated in
    assert length(rows!(Members.list_by_user(user.id))) == 2
  end

  test "an email dropped from the operator list loses the platform row on the next sign-in" do
    i = info(3)
    assert {:ok, user} = SignIn.admitted(i, :admin)
    assert Enum.any?(rows!(Members.list_by_user(user.id)), &(&1.scope == "platform"))

    assert {:ok, _} = SignIn.admitted(i, :allowed)
    refute Enum.any?(rows!(Members.list_by_user(user.id)), &(&1.scope == "platform"))
    # their own athanor is theirs whatever the operator list says
    assert Enum.any?(rows!(Members.list_by_user(user.id)), &(&1.scope == "athanor"))
  end

  test "invited rows for the person's verified email activate on first sign-in" do
    {:ok, group} = Athanors.create_group("github|https://github.com|creator", "Home Team")
    {:ok, :invited} = Members.add(group, [email: "User4@Example.com"], "creator")

    assert [%{status: "invited", email: "user4@example.com"}] =
             Enum.filter(rows!(Members.list_by_athanor(group.id)), &(&1.status == "invited"))

    i = info(4)
    assert {:ok, user} = SignIn.admitted(i, :allowed)

    assert Members.member?(user.id, group.id)
    refute Enum.any?(rows!(Members.list_by_athanor(group.id)), &(&1.status == "invited"))
  end

  test "only a proved address claims its invitations; the seat waits for the rest" do
    # Admission and seating are different questions. The door may let an
    # identity in on an unasserted address (`*`, or a `user_id` entry), but an
    # invited row is keyed on the email alone, so seating it needs the address
    # proved — otherwise an issuer asserting someone else's address inherits
    # their groups. The seat is held, not withdrawn.
    for {n, claim} <- [{5, :unknown}, {9, false}] do
      {:ok, group} = Athanors.create_group("github|https://github.com|creator2", "Team #{n}")
      {:ok, :invited} = Members.add(group, [email: "user#{n}@example.com"], "creator2")

      assert {:ok, user} = SignIn.admitted(info(n, %{verified: claim}), :allowed)

      refute Members.member?(user.id, group.id)
      assert Enum.any?(rows!(Members.list_by_athanor(group.id)), &(&1.status == "invited"))
    end

    {:ok, group} = Athanors.create_group("github|https://github.com|creator2", "Proved Team")
    {:ok, :invited} = Members.add(group, [email: "user11@example.com"], "creator2")

    assert {:ok, %{email_verified: true}} =
             SignIn.admitted(info(11, %{verified: true}), :allowed)

    assert {:ok, %{id: proved}} = Users.get_by_identity(info(11).id)
    assert Members.member?(proved, group.id)
    refute Enum.any?(rows!(Members.list_by_athanor(group.id)), &(&1.status == "invited"))
  end

  test "record_namespace/2 lands the claim on the users row and refuses a slug another identity holds" do
    i = info(6)
    assert {:ok, %{id: uid, personal_athanor_id: pid}} = SignIn.admitted(i, :allowed)

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
    j = info(7)
    assert {:ok, %{id: jid}} = SignIn.admitted(j, :allowed)

    assert {:error, :namespace_owned_by_another_identity} =
             SignIn.record_namespace(jid, "user6ns")

    assert {:error, :invalid_slug} = SignIn.record_namespace(jid, "Not A Slug")

    assert {:error, :not_found} = SignIn.record_namespace("usr_ghost", "ghost")
  end

  test "`*` on the door admits a stranger who then gets their own athanor — no platform bit, no group" do
    n = System.unique_integer([:positive])
    i = info(n, %{email: "stranger#{n}@example.com"})
    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "ops")

    assert {:ok, verdict} = Sanctum.Door.admit(i.id, i.email, true)
    assert verdict == :allowed

    assert {:ok, %{id: uid, personal_athanor_id: pid}} = SignIn.admitted(i, verdict)
    assert {:ok, user} = SignIn.record_namespace(uid, "stranger#{n}")

    assert {:ok, %{kind: "person", owner_user_id: owner}} = Athanors.get(pid)
    assert owner == user.id

    rows = rows!(Members.list_by_user(user.id))
    refute Enum.any?(rows, &(&1.scope == "platform"))
    assert Enum.map(Athanors.list_for_user(user.id), & &1.kind) == ["person"]
  end

  describe "the identity facts a sign-in grants or revokes on" do
    test "are this assertion's: its lowercased email, or the stored one when it carried none" do
      row = %Arca.Schemas.User{email: "stored@example.com", email_verified: true}

      assert %{email: "mixed@example.com", email_verified: true} =
               SignIn.expected_identity(%{email: "Mixed@Example.com", verified: true}, row)

      for absent <- [nil, ""] do
        assert %{email: "stored@example.com"} =
                 SignIn.expected_identity(%{email: absent, verified: true}, row)
      end

      # A concurrent first sign-in that lost the mint is answered the
      # winner's row; the winner's address never becomes the loser's.
      assert %{email: "loser@example.com"} =
               SignIn.expected_identity(%{email: "loser@example.com"}, row)

      for {claim, stored} <- [{true, true}, {false, false}, {:unknown, nil}, {nil, nil}] do
        assert %{email_verified: ^stored} =
                 SignIn.expected_identity(%{email: "a@example.com", verified: claim}, row)
      end
    end

    test "an earlier operator assertion overtaken by a later one grants nothing" do
      n = System.unique_integer([:positive])
      ops = info(n, %{email: "ops#{n}@example.com"})
      assert {:ok, user} = SignIn.identify(ops, :admin)
      asserted = SignIn.expected_identity(ops, user)

      # A later assertion for the same identity carries another address, and
      # the door no longer calls it an operator.
      later = %{ops | email: "someone#{n}@example.com"}
      assert {:ok, _} = SignIn.identify(later, :allowed)
      refute platform?(user.id)

      # The earlier sign-in's delayed grant lands on facts that are gone.
      assert {:error, :stale_identity} = Members.grant_platform(user.id, asserted)
      refute platform?(user.id)
    end

    test "an earlier non-operator assertion overtaken by an operator one revokes nothing" do
      n = System.unique_integer([:positive])
      plain = info(n, %{email: "plain#{n}@example.com"})
      assert {:ok, user} = SignIn.identify(plain, :allowed)
      asserted = SignIn.expected_identity(plain, user)

      assert {:ok, _} = SignIn.identify(%{plain | email: "ops#{n}@example.com"}, :admin)
      assert platform?(user.id)

      assert {:error, :stale_identity} =
               Members.revoke_platform(user.id, expected_identity: asserted)

      assert platform?(user.id)
    end

    test "an unchanged delayed verdict still lands" do
      n = System.unique_integer([:positive])
      ops = info(n)
      assert {:ok, user} = Users.upsert_from_provider(ops)
      asserted = SignIn.expected_identity(ops, user)

      # The same facts asserted again in between: the delayed grant stands.
      assert {:ok, _} = Users.upsert_from_provider(%{ops | name: "Renamed"})
      assert {:ok, :granted} = Members.grant_platform(user.id, asserted)
      assert {:ok, :held} = Members.grant_platform(user.id, asserted)
    end

    test "a grant that fails refuses the sign-in before anything after it" do
      n = System.unique_integer([:positive])

      # An explicitly unverified address is never granted, whatever verdict
      # the caller hands over.
      assert {:error, :stale_identity} = SignIn.admitted(info(n, %{verified: false}), :admin)

      assert {:ok, user} = Users.get_by_identity(info(n).id)
      refute platform?(user.id)
      assert user.personal_athanor_id == nil, "the sign-in went on past a refused grant"
    end
  end

  describe "the person's keys, minted with the person" do
    test "a first sign-in writes one local key set, and a later sign-in keeps it" do
      i = info(20)
      assert {:ok, user} = SignIn.admitted(i, :allowed)

      row = identity_row!(user.id)
      assert row.provenance == "local"
      assert row.enrollment == "none"
      assert byte_size(row.live_public_key) == 32
      assert byte_size(row.operational_public_key) == 32
      refute row.live_public_key == row.operational_public_key
      assert is_binary(row.live_key_sealed) and is_binary(row.operational_key_sealed)

      # The identifier is on the identity row, never on the users row, and
      # an unenrolled person has none.
      refute Map.has_key?(user, :identifier)
      assert {:ok, nil} = Users.identifier(user.id)

      assert {:ok, _} = SignIn.admitted(%{i | name: "Again"}, :allowed)
      assert identity_row!(user.id) == row
      assert identity_rows(user.id) == 1
    end

    test "Users.identifier/1 reads the identifier the identity row carries" do
      assert {:ok, user} = SignIn.admitted(info(21), :allowed)

      identifier = "per_" <> Prima.Digest.sha256_hex("identifier-#{user.id}")

      {1, _} =
        Arca.Repo.update_all(from(p in PersonIdentity, where: p.user_id == ^user.id),
          set: [
            identifier: identifier,
            enrollment: "enrolled",
            head_hash: Prima.Digest.sha256("genesis"),
            directory_url: "https://dir.example"
          ]
        )

      assert {:ok, ^identifier} = Users.identifier(user.id)
      assert {:error, :not_found} = Users.identifier("usr_ghost")
    end

    test "a key set that cannot be minted refuses the sign-in, and nothing is written" do
      keyring = Application.get_env(:sanctum, :crypto_keyring)
      on_exit(fn -> restore_env(:sanctum, :crypto_keyring, keyring) end)
      Application.delete_env(:sanctum, :crypto_keyring)

      i = info(22)
      before = counts()

      capture_log(fn -> assert {:error, :unavailable} = SignIn.admitted(i, :admin) end)

      # Not the person, not the door that admitted them, not a key, and not
      # the platform row the operator's verdict would have granted.
      assert {:error, :not_found} = Users.get_by_identity(i.id)
      assert counts() == before
    end

    test "a member that lost its slot mints no person" do
      standing = :persistent_term.get({Arca.ControlPlane, :standing}, :absent)
      claim = Application.get_env(:arca, :control_plane_claim_enabled)

      on_exit(fn ->
        if standing == :absent,
          do: :persistent_term.erase({Arca.ControlPlane, :standing}),
          else: :persistent_term.put({Arca.ControlPlane, :standing}, standing)

        restore_env(:arca, :control_plane_claim_enabled, claim)
      end)

      Application.put_env(:arca, :control_plane_claim_enabled, true)
      :persistent_term.put({Arca.ControlPlane, :standing}, :lost)

      i = info(23)
      before = counts()

      assert {:error, :not_owner} = SignIn.admitted(i, :allowed)
      assert {:error, :not_found} = Users.get_by_identity(i.id)
      assert counts() == before
    end
  end

  describe "an installation reserved for a restore" do
    setup do
      mode = if InstallationClaims.installed?(), do: InstallationClaims.mode()

      on_exit(fn ->
        if mode,
          do: InstallationClaims.install_mode!(mode),
          else: InstallationClaims.reset()
      end)

      # The node holds no person inside this test's transaction, whatever
      # another suite committed: the reservation is about the first one.
      Arca.Repo.delete_all(User)
      :ok = InstallationClaims.install_mode!(:restore_reserved)
      :ok
    end

    test "refuses every first door, the operator's included, before a person or a key" do
      oidc = %{
        id: "oidc|https://idp.example|31",
        provider: :oidc,
        email: "ops31@example.com",
        verified: true
      }

      before = counts()
      assert %{people: 0, keys: 0} = before

      for {assertion, verdict} <- [{info(30), :allowed}, {oidc, :admin}] do
        assert {:error, :restore_reserved} = SignIn.admitted(assertion, verdict)
        assert {:error, :not_found} = Users.get_by_identity(assertion.id)
      end

      assert counts() == before
    end

    test "refuses a direct mint before the key closure runs" do
      test = self()
      now = DateTime.utc_now()
      before = counts()

      closure = fn person ->
        send(test, :keys_minted)
        Sanctum.Person.mint_keys(person)
      end

      assert {:error, :restore_reserved} =
               Arca.Users.mint(
                 Prima.Actor.system(),
                 %{
                   id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
                   provider: "github",
                   first_seen_at: now,
                   last_seen_at: now,
                   created_at: now,
                   updated_at: now
                 },
                 %{
                   key: "github|https://github.com|direct",
                   provider: "github",
                   issuer: "https://github.com",
                   subject: "direct",
                   first_seen_at: now,
                   last_seen_at: now
                 },
                 also: closure
               )

      refute_received :keys_minted
      assert counts() == before
    end

    test "admits an ordinary first door again once the token is unset before any claim" do
      :ok = InstallationClaims.install_mode!(:ordinary)

      assert {:ok, user} = SignIn.admitted(info(32), :admin)
      assert identity_row!(user.id).provenance == "local"
    end

    test "stays reserved for a pending restore once the token is unset" do
      token = Prima.Digest.sha256("token-#{System.unique_integer([:positive])}")

      {:ok, _attempt} =
        Arca.IdentityAttempts.open(Prima.Actor.system(), %{
          kind: "restore",
          request_id: "req_#{System.unique_integer([:positive])}",
          identifier: "per_" <> Prima.Digest.sha256_hex("restored"),
          directory_url: "https://dir.example",
          entry: "recover-request",
          request_digest: Prima.Digest.sha256("recover"),
          expected_revision: 0,
          token_digest: token,
          staged_live_public_key: :crypto.strong_rand_bytes(32),
          staged_operational_public_key: :crypto.strong_rand_bytes(32),
          staged_live_key_sealed: "sealed-live",
          staged_operational_key_sealed: "sealed-operational"
        })

      :ok = InstallationClaims.install_mode!(:ordinary)
      before = counts()

      assert {:error, :restore_reserved} = SignIn.admitted(info(33), :admin)
      assert counts() == before
      assert before.people == 0
    end
  end

  describe "linking a door" do
    setup do
      Arca.Cache.init()
      {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")
      on_exit(fn -> Arca.Cache.delete_match({:established, :_, :_, :_}) end)
      :ok
    end

    # A person seated in a group of their own, and a context their own
    # session establishes there.
    defp seated!(overrides \\ %{}) do
      n = System.unique_integer([:positive])
      {:ok, user} = Users.upsert_from_provider(info(n, overrides))
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
        Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

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

    test "a ticket is minted for a standing session and a linkable door the door admits" do
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

      # The door is asked, and its refusal is the operator's to act on.
      [entry] = Sanctum.Door.Store.list()
      :ok = Sanctum.Door.Store.remove(entry.id)
      assert {:error, {:door, :not_allowed}} = SignIn.link_ticket(person.ctx, oidc(n))
      assert Enum.any?(Sanctum.Door.Store.requests(), &(&1.value == oidc(n).key))
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

    test "another person's identity is a conflict, and a door closed since is not linked" do
      person = seated!()
      other = seated!()
      {:ok, [taken]} = Arca.Users.identities(Prima.Actor.system(), other.user.id)

      ticket =
        ticket!(person, %{key: taken.key, provider: "github", email: nil, verified: :unknown})

      assert {:error, {:conflict, _}} = SignIn.link_door(person.ctx, "github", ticket)

      n = System.unique_integer([:positive])
      ticket = ticket!(person, oidc(n, %{verified: :unknown}))
      [entry] = Enum.filter(Sanctum.Door.Store.list(), &(&1.kind == "wildcard"))
      :ok = Sanctum.Door.Store.remove(entry.id)

      assert {:error, {:door, :not_allowed}} =
               Sanctum.TestContext.confirming(
                 person.ctx,
                 &SignIn.link_door(&1, "oidcc", ticket)
               )

      assert {:error, :not_found} = Users.get_by_identity(oidc(n).key)
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
      assert message =~ "link another door"

      other = seated!()
      {:ok, [theirs]} = Arca.Users.identities(Prima.Actor.system(), other.user.id)
      assert {:error, {:not_found, "door", _}} = SignIn.unlink_door(person.ctx, theirs.key)

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

      [wildcard] = Enum.filter(Sanctum.Door.Store.list(), &(&1.kind == "wildcard"))
      :ok = Sanctum.Door.Store.remove(wildcard.id)

      # An entry naming only this door's identity admits no one once the
      # door is gone, so it is refused before any proof is asked.
      {:ok, _} = Sanctum.Door.Store.allow("user_id", github.key, "ops")
      assert {:error, {:conflict, message}} = SignIn.unlink_door(person.ctx, github.key)
      assert message =~ "ask the operator"
      assert message =~ "link another door"
      assert {:ok, _person} = Users.get_by_identity(github.key)

      admits? = fn ->
        case SignIn.unlink_door(person.ctx, github.key) do
          {:error, {:confirmation_required, _}} -> true
          {:error, {:conflict, _}} -> false
        end
      end

      verified = fn claim ->
        {1, _} =
          Arca.Repo.update_all(from(u in User, where: u.id == ^person.user.id),
            set: [email_verified: claim]
          )
      end

      # An email entry admits the address only while it is verified.
      {:ok, email} = Sanctum.Door.Store.allow("email", person.user.email, "ops")
      assert admits?.()
      verified.(false)
      refute admits?.()
      :ok = Sanctum.Door.Store.remove(email.id)

      # `*` admits an address not known to be unverified.
      {:ok, wildcard} = Sanctum.Door.Store.allow("wildcard", "*", "ops")
      refute admits?.()
      verified.(nil)
      assert admits?.()
      :ok = Sanctum.Door.Store.remove(wildcard.id)
      refute admits?.()

      # Their own id: the door goes, and the passkey door admits them by it.
      {:ok, _} = Sanctum.Door.Store.allow("user_id", person.user.id, "ops")

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

  describe "concurrent sign-ins, on connections of their own" do
    setup do
      # These race on real connections: the shared sandbox connection would
      # serialize the very interleavings under test.
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, :manual)
      :ok
    end

    test "differing first sign-ins of one identity leave a grant only on the operator's facts" do
      for order <- [[:admin, :allowed], [:allowed, :admin]], _round <- 1..3 do
        n = System.unique_integer([:positive])
        ops = info(n, %{email: "ops#{n}@example.com"})
        plain = %{ops | email: "plain#{n}@example.com"}
        assertion = %{admin: ops, allowed: plain}

        results =
          order
          |> Enum.map(fn verdict ->
            Task.async(fn ->
              {verdict, unboxed(fn -> SignIn.identify(assertion[verdict], verdict) end)}
            end)
          end)
          |> Enum.map(&Task.await(&1, 25_000))

        {:ok, user} = unboxed(fn -> Users.get_by_identity(ops.id) end)
        on_exit(fn -> purge!(user.id) end)

        # Whoever wrote last, the operator bit is on exactly when the row
        # carries the operator's address.
        assert unboxed(fn -> platform?(user.id) end) == (user.email == ops.email)

        # And no sign-in that went on did so on facts other than its own.
        for {verdict, {:ok, row}} <- results do
          assert row.email == assertion[verdict].email
        end

        for {_verdict, {:error, reason}} <- results, do: assert(reason == :stale_identity)
      end
    end

    test "concurrent operator sign-ins write one grant and announce it once" do
      handler = "signin-race-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:cyfr, :sanctum, :tenancy, :platform_admin_bootstrap],
        fn _e, _m, meta, _c -> send(parent, {:bootstrap, meta.user_id}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      n = System.unique_integer([:positive])
      ops = info(n)
      {:ok, user} = unboxed(fn -> Users.upsert_from_provider(ops) end)
      on_exit(fn -> purge!(user.id) end)

      # Two racers, as `Arca.MembersLockTest` explains: more SQLite waiters
      # than a partition's dirty I/O schedulers starve the lock's holder.
      results =
        1..2
        |> Enum.map(fn _ ->
          Task.async(fn -> unboxed(fn -> SignIn.identify(ops, :admin) end) end)
        end)
        |> Enum.map(&Task.await(&1, 25_000))

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert_receive {:bootstrap, uid}
      assert uid == user.id
      refute_receive {:bootstrap, _}, 200

      assert 1 ==
               unboxed(fn ->
                 {:ok, rows} = Members.list_by_user(user.id)
                 Enum.count(rows, &(&1.scope == "platform"))
               end)
    end
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, fun)

  defp purge!(user_id) do
    import Ecto.Query

    unboxed(fn ->
      Arca.Repo.delete_all(from(m in Arca.Schemas.Membership, where: m.user_id == ^user_id))
      Arca.Repo.delete_all(from(s in Arca.Schemas.Session, where: s.user_id == ^user_id))

      Arca.Repo.delete_all(from(i in Arca.Schemas.ExternalIdentity, where: i.user_id == ^user_id))

      Arca.Repo.delete_all(from(u in Arca.Schemas.User, where: u.id == ^user_id))
    end)
  end

  defp platform?(user_id) do
    {:ok, rows} = Members.list_by_user(user_id)
    Enum.any?(rows, &(&1.scope == "platform"))
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp identity_row!(user_id), do: Arca.Repo.get_by!(PersonIdentity, user_id: user_id)

  defp identity_rows(user_id),
    do: Arca.Repo.aggregate(from(p in PersonIdentity, where: p.user_id == ^user_id), :count)

  # What a first sign-in writes: the person, the door that names them, their
  # key set and, for an operator, the platform row.
  defp counts do
    %{
      people: Arca.Repo.aggregate(User, :count),
      doors: Arca.Repo.aggregate(ExternalIdentity, :count),
      keys: Arca.Repo.aggregate(PersonIdentity, :count),
      platform:
        Arca.Repo.aggregate(
          from(m in Arca.Schemas.Membership, where: m.scope == "platform"),
          :count
        )
    }
  end

  defp rows!({:ok, rows}), do: rows
end
