# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.NewcomerTest do
  @moduledoc """
  A person is made only by an admission (`Sanctum.Newcomer.admit/2`), and
  a linked sign-in method only unlocks a person who exists
  (`Sanctum.SignIn.unlock/1`).

  Setup makes the installation's first person, their keys, their athanor,
  their credential, their enrollment and the platform grant in one
  transaction, and answers that person again while they hold no sign-in
  method, with the enrollment that stands; from the commit that gives
  them one, the token opens nothing. Every local admission brings the new
  person's identity, enrolls them with it in its transaction, answers
  their recovery code, and admits no one where no directory is pinned. An open admission needs
  the door's `*` and passes the athanor caps, and a refusal anywhere in
  its transaction leaves no person, no athanor and no passkey. An
  invitation admits without the door, under its own checks and the same
  caps, and seats its person in the group it names in the transaction
  that redeems it, so a refusal leaves no person and the code unredeemed;
  one whose issuer's standing moved since it was issued, a declared
  restore's raise among them, admits no one.
  A remote
  newcomer is admitted by the door's verdict on their identifier, with no
  keys and no athanor, and a directory that cannot be read writes no row.
  A killed admission and a member that lost its slot write nothing.
  """

  # The setup token, the slot, the directory seam and the settings are
  # process-wide.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Sanctum.Test.Newcomers, only: [identity: 0, identity: 1]

  alias Arca.Schemas.{
    ExternalIdentity,
    IdentityAttempt,
    Invitation,
    Membership,
    Passkey,
    PersonIdentity,
    Session,
    User
  }

  alias Sanctum.Door.Store
  alias Sanctum.Newcomer
  alias Sanctum.Tenancy.{Athanors, Members}
  alias Sanctum.Test.{DirectoryServer, Newcomers, Settings}
  alias Sanctum.TestContext.Authenticator

  @token String.duplicate("5e", 32)

  setup_all do
    %{tls: DirectoryServer.tls()}
  end

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    previous = Application.fetch_env(:sanctum, :setup_token)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sanctum, :setup_token, value)
        :error -> Application.delete_env(:sanctum, :setup_token)
      end
    end)

    Application.put_env(:sanctum, :setup_token, @token)
    Newcomers.directory!()

    # The installation holds no person inside this test's transaction,
    # whatever the suite committed: the first person is the question.
    Arca.Repo.delete_all(User)
    :ok
  end

  # A newcomer's registration: the browser's answer to the options drawn
  # for a person who does not exist yet.
  defp registration do
    {:ok, options} = Sanctum.Passkeys.newcomer_options()
    auth = Authenticator.new("newcomer|#{System.unique_integer([:positive])}")
    Authenticator.registration(auth, options)
  end

  defp people, do: Arca.Repo.aggregate(User, :count)
  defp passkeys, do: Arca.Repo.aggregate(Passkey, :count)

  defp grants,
    do: Arca.Repo.aggregate(from(m in Membership, where: m.scope == "platform"), :count)

  defp athanors(user_id),
    do:
      Arca.Repo.aggregate(
        from(a in Arca.Schemas.Athanor, where: a.owner_user_id == ^user_id),
        :count
      )

  defp sessions(user_id), do: Arca.Repo.all(from(s in Session, where: s.user_id == ^user_id))

  defp attempts, do: Arca.Repo.aggregate(IdentityAttempt, :count)

  defp enrollment(user_id),
    do: Arca.Repo.get_by!(IdentityAttempt, user_id: user_id, kind: "enrollment")

  defp setup!(credential \\ {:command_line, "laptop", identity()}) do
    {:ok, admitted} = Newcomer.admit({:setup, @token}, credential)
    admitted
  end

  defp identifier, do: "per_" <> Prima.Digest.sha256_hex("newcomer-#{System.unique_integer()}")

  # Tells this process of every person row it inserts, rolled back or not:
  # a refusal that counts before the row writes none.
  defp watch_person_inserts! do
    test = self()
    handler = "newcomer-inserts-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test and metadata[:source] == "users" and
               String.starts_with?(metadata[:query] || "", "INSERT"),
             do: send(test, :person_inserted)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  describe "setup" do
    test "makes the first person with their keys, athanor and passkey, signs them in, and grants the platform role" do
      assert {:ok, %{person: person, readmitted: false, session_token: token}} =
               Newcomer.admit({:setup, @token}, {:passkey, registration(), identity()})

      assert person.admission == "setup"
      assert people() == 1

      assert %PersonIdentity{provenance: "local", live_public_key: <<_::binary>>} =
               Arca.Repo.get_by(PersonIdentity, user_id: person.id)

      assert {:ok, athanor} = Athanors.get_by_owner(person.id)
      assert athanor.kind == "person"
      assert Members.member?(person.id, athanor.id)
      assert person.personal_athanor_id == athanor.id

      assert Sanctum.Tenancy.platform_admin?(person.id)
      assert grants() == 1

      assert [%Passkey{state: "active"}] =
               Arca.Repo.all(from(p in Passkey, where: p.user_id == ^person.id))

      assert {:ok, %{user_id: user_id, provider: "passkey"}} = Sanctum.Session.get(token)
      assert user_id == person.id
    end

    test "enrolls the person in its transaction with the identity it brings, and answers their recovery code" do
      identity = identity("mira")

      assert {:ok, %{person: person, recovery: recovery}} =
               Newcomer.admit({:setup, @token}, {:command_line, "laptop", identity})

      attempt = enrollment(person.id)

      assert %{
               phase: "staged",
               name: "mira",
               request_id: request_id,
               directory_url: directory,
               kit_seed_sealed: <<_::binary>>
             } = attempt

      assert request_id == identity.request_id
      assert directory == Newcomers.directory()

      assert %{"directory" => ^directory, "recovery_keys" => [recovery_key]} =
               Jason.decode!(attempt.genesis)

      {:ok, {public, _private}} = Prima.Identity.derive_recovery_key(identity.recovery_secret)
      assert recovery_key == Prima.Identity.Encoding.b64(public)

      assert recovery == %{
               attempt_id: attempt.id,
               identifier: attempt.identifier,
               name: "mira",
               code: Prima.RecoveryCode.encode(attempt.identifier, identity.recovery_secret)
             }

      assert %PersonIdentity{enrollment: "pending", identifier: nil} =
               Arca.Repo.get_by(PersonIdentity, user_id: person.id)

      # The stored row holds the secret sealed, never in the clear.
      refute attempt.kit_seed_sealed =~ identity.recovery_secret
      refute inspect(Map.from_struct(attempt)) =~ recovery.code
    end

    test "a re-admission with another secret answers the first attempt and its code" do
      first = identity("first")
      %{person: person, recovery: recovery} = setup!({:command_line, "laptop", first})

      assert {:ok, %{person: %{id: same}, readmitted: true, recovery: ^recovery}} =
               Newcomer.admit({:setup, @token}, {:command_line, "laptop", identity("second")})

      assert same == person.id

      assert recovery.code ==
               Prima.RecoveryCode.encode(recovery.identifier, first.recovery_secret)

      assert attempts() == 1
      assert %{name: "first"} = enrollment(person.id)

      # Once the code is saved the re-admission answers the attempt and no code.
      {1, _} =
        Arca.Repo.update_all(from(a in IdentityAttempt, where: a.id == ^recovery.attempt_id),
          set: [phase: "completed", kit_seed_sealed: nil]
        )

      assert {:ok, %{recovery: saved}} =
               Newcomer.admit({:setup, @token}, {:command_line, "laptop", identity()})

      assert saved == Map.delete(recovery, :code)
    end

    test "a credential without the new person's identity is refused, and nothing is written" do
      %{recovery_secret: secret} = valid = identity()
      registration = registration()

      for credential <- [
            {:command_line, "laptop"},
            {:passkey, registration},
            {:command_line, "laptop", nil},
            {:passkey, registration, %{}},
            {:command_line, "laptop", %{valid | name: "Not A Name"}},
            {:command_line, "laptop", %{valid | recovery_secret: binary_part(secret, 0, 31)}},
            {:command_line, "laptop", %{valid | request_id: "no spaces allowed"}}
          ] do
        assert {:error, {:invalid_argument, sentence}} =
                 Newcomer.admit({:setup, @token}, credential),
               inspect(credential)

        assert is_binary(sentence)
      end

      assert people() == 0
      assert passkeys() == 0
      assert attempts() == 0
    end

    test "with no directory pinned, no local person is admitted, refused before the passkey is verified" do
      Prima.Test.Env.delete_app_env(:sanctum, :directory_url)
      watch_person_inserts!()

      # A registration that would not verify: the refusal comes first.
      assert {:error, :no_directory} =
               Newcomer.admit({:setup, @token}, {:passkey, %{"not" => "verified"}, identity()})

      assert {:error, :no_directory} =
               Newcomer.admit({:setup, @token}, {:command_line, "laptop", identity()})

      Prima.Test.Env.put_app_env(:sanctum, :directory_url, "")

      assert {:error, :no_directory} =
               Newcomer.admit({:setup, @token}, {:command_line, "laptop", identity()})

      refute_received :person_inserted
      assert people() == 0
      assert attempts() == 0
    end

    test "the person and their enrollment commit together or not at all" do
      %{recovery: %{attempt_id: attempt_id}} = setup!()
      {:ok, _} = Store.allow("wildcard", "*", "ops")
      taken = Arca.Repo.get!(IdentityAttempt, attempt_id).request_id

      written = fn ->
        {people(), passkeys(), attempts(), Arca.Repo.aggregate(PersonIdentity, :count),
         Arca.Repo.aggregate(Arca.Schemas.Athanor, :count)}
      end

      before = written.()

      # An enrollment that cannot be opened, its request id taken, rolls the
      # person, their keys, athanor and passkey back with it.
      assert {:error, {:invalid_argument, _}} =
               Newcomer.admit(
                 :open,
                 {:passkey, registration(), %{identity() | request_id: taken}}
               )

      assert written.() == before

      # Admitted, each person holds exactly the enrollment their admission opened.
      assert {:ok, %{person: second, recovery: %{attempt_id: opened}}} =
               Newcomer.admit(:open, {:passkey, registration(), identity()})

      assert enrollment(second.id).id == opened
      assert attempts() == 2
    end

    test "answers the same person again, with a new command-line session, while they hold no sign-in method" do
      first = setup!()
      assert %{readmitted: false, session_token: token} = first

      assert {:ok, %{person: again, readmitted: true, session_token: second}} =
               Newcomer.admit({:setup, @token}, {:command_line, "laptop", identity()})

      assert again.id == first.person.id
      refute second == token
      assert people() == 1
      assert grants() == 1
      assert athanors(again.id) == 1

      assert [_, _] = both = sessions(again.id)
      assert Enum.all?(both, &match?(%Session{cli_machine: "laptop", provider: "setup"}, &1))
    end

    test "two setups: the second answers the first person, and once they hold a passkey the token opens nothing" do
      %{person: first} = setup!()

      assert {:ok, %{person: %{id: same}, readmitted: true}} =
               Newcomer.admit({:setup, @token}, {:passkey, registration(), identity()})

      assert same == first.id

      assert [%Passkey{state: "active"}] =
               Arca.Repo.all(from(p in Passkey, where: p.user_id == ^first.id))

      assert {:error, :setup_closed} =
               Newcomer.admit({:setup, @token}, {:command_line, "laptop", identity()})

      assert {:error, :setup_closed} =
               Newcomer.admit({:setup, @token}, {:passkey, registration(), identity()})

      assert people() == 1
      assert passkeys() == 1
      assert length(sessions(first.id)) == 2
    end

    test "opens nothing once the person links a sign-in method" do
      %{person: first} = setup!()

      {:ok, %{linked: true}} =
        Arca.Users.link_identity(Prima.Actor.system(), first.id, %{
          key: "github|https://github.com|setup-link",
          provider: "github",
          issuer: "https://github.com",
          subject: "setup-link"
        })

      assert {:error, :setup_closed} =
               Newcomer.admit({:setup, @token}, {:command_line, "laptop", identity()})

      assert length(sessions(first.id)) == 1
    end

    test "opens nothing once the person connects a device, which marks their first method" do
      %{person: first} = setup!()

      # A pairing's completion sets the mark a first passkey sets
      # (`Arca.PairingInvitations`), under the person's lock.
      {:ok, :marked} =
        Arca.Repo.transaction(fn -> Arca.PersonIdentities.first_method!(first.id) end)

      assert {:error, :setup_closed} =
               Newcomer.admit({:setup, @token}, {:command_line, "laptop", identity()})
    end

    test "a token that is not the configured one, a missing one, or none configured, opens nothing and writes nothing" do
      assert {:error, :setup_closed} =
               Newcomer.admit(
                 {:setup, String.duplicate("0", 64)},
                 {:command_line, "laptop", identity()}
               )

      assert {:error, :setup_closed} =
               Newcomer.admit({:setup, "short"}, {:command_line, "laptop", identity()})

      for credential <- [
            {:command_line, "laptop", identity()},
            {:passkey, registration(), identity()},
            :none
          ] do
        assert {:error, :setup_closed} = Newcomer.admit({:setup, nil}, credential)
      end

      Application.delete_env(:sanctum, :setup_token)

      assert {:error, :setup_closed} =
               Newcomer.admit({:setup, @token}, {:command_line, "laptop", identity()})

      assert people() == 0
    end

    test "setup_open/1 answers before any ceremony what the admission would, one refusal for both" do
      assert :ok = Newcomer.setup_open(@token)
      assert {:error, :setup_closed} = Newcomer.setup_open(String.duplicate("0", 64))
      assert {:error, :setup_closed} = Newcomer.setup_open(nil)

      # The person setup made, with no sign-in method yet, is answered again.
      {:ok, _admitted} = Newcomer.admit({:setup, @token}, {:command_line, "laptop", identity()})
      assert :ok = Newcomer.setup_open(@token)

      # Their first passkey closes it.
      assert {:ok, %{readmitted: true}} =
               Newcomer.admit({:setup, @token}, {:passkey, registration(), identity()})

      assert {:error, :setup_closed} = Newcomer.setup_open(@token)

      Application.delete_env(:sanctum, :setup_token)
      assert {:error, :setup_closed} = Newcomer.setup_open(@token)
      assert people() == 1
    end

    test "racing a restore: a pending claim refuses setup, and setup first leaves the restore no node" do
      restore = %{
        kind: "restore",
        request_id: "req_#{System.unique_integer([:positive])}",
        identifier: identifier(),
        directory_url: "https://dir.example",
        entry: "recover-request",
        request_digest: Prima.Digest.sha256("recover-#{System.unique_integer()}"),
        expected_revision: 0,
        token_digest: Prima.Digest.sha256("token-#{System.unique_integer()}"),
        staged_live_public_key: :crypto.strong_rand_bytes(32),
        staged_operational_public_key: :crypto.strong_rand_bytes(32),
        staged_live_key_sealed: "sealed-live",
        staged_operational_key_sealed: "sealed-op"
      }

      {:ok, attempt} = Arca.IdentityAttempts.open(Prima.Actor.system(), restore)

      assert {:error, :restore_reserved} =
               Newcomer.admit({:setup, @token}, {:command_line, "laptop", identity()})

      assert people() == 0

      {:ok, _} =
        Arca.IdentityAttempts.advance(Prima.Actor.system(), attempt.id, "staged", "submitted")

      {:ok, _} =
        Arca.IdentityAttempts.advance(Prima.Actor.system(), attempt.id, "submitted", "refused")

      %{person: _first} = setup!()

      assert {:error, :not_empty} =
               Arca.IdentityAttempts.open(Prima.Actor.system(), %{
                 restore
                 | request_id: "req_after",
                   token_digest: Prima.Digest.sha256("token-after")
               })
    end

    test "a member that lost its slot makes no first person and grants nothing" do
      keys = [
        {Arca.ControlPlane, :standing},
        {Arca.ControlPlane, :generation},
        {Arca.ControlPlane, :slot}
      ]

      saved = Map.new(keys, &{&1, :persistent_term.get(&1, :absent)})
      claim = Application.get_env(:arca, :control_plane_claim_enabled)

      on_exit(fn ->
        for {key, value} <- saved do
          if value == :absent,
            do: :persistent_term.erase(key),
            else: :persistent_term.put(key, value)
        end

        if is_nil(claim),
          do: Application.delete_env(:arca, :control_plane_claim_enabled),
          else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
      end)

      Application.put_env(:arca, :control_plane_claim_enabled, true)
      node = "newcomer-#{System.unique_integer([:positive])}"
      {:ok, slot} = Arca.ControlPlane.take(node, node <> "#old", 60_000)

      {1, _} =
        Arca.Repo.update_all(from(l in Arca.Schemas.CellLease, where: l.node == ^slot.node),
          set: [owner: "successor", generation: slot.generation + 1]
        )

      assert {:error, :not_owner} =
               Newcomer.admit({:setup, @token}, {:passkey, registration(), identity()})

      assert people() == 0
      assert grants() == 0
      assert passkeys() == 0
    end
  end

  describe "an open admission" do
    test "needs the door's *, and writes nothing and leaves no request without it" do
      %{person: _first} = setup!()

      assert {:error, {:door, :not_allowed}} =
               Newcomer.admit(:open, {:passkey, registration(), identity()})

      assert people() == 1
      assert Store.requests() == []
    end

    test "is not the first person: onto an empty installation it is not set up" do
      {:ok, _} = Store.allow("wildcard", "*", "ops")

      assert {:error, :not_set_up} = Newcomer.admit(:open, {:passkey, registration(), identity()})
      assert people() == 0
      assert passkeys() == 0
    end

    test "makes a local person with keys, an athanor and a passkey, and no grant" do
      %{person: _first} = setup!()
      {:ok, _} = Store.allow("wildcard", "*", "ops")

      assert {:ok,
              %{
                person: person,
                readmitted: false,
                session_token: token,
                recovery: %{name: "opened", code: "CYFR-" <> _, attempt_id: attempt_id}
              }} = Newcomer.admit(:open, {:passkey, registration(), identity("opened")})

      assert %{id: ^attempt_id, phase: "staged", name: "opened"} = enrollment(person.id)
      assert person.admission == "open"
      refute Sanctum.Tenancy.platform_admin?(person.id)
      assert grants() == 1
      assert {:ok, _athanor} = Athanors.get_by_owner(person.id)

      assert %PersonIdentity{provenance: "local"} =
               Arca.Repo.get_by(PersonIdentity, user_id: person.id)

      assert {:ok, %{user_id: _}} = Sanctum.Session.get(token)
    end

    test "at a cap is refused before the person's row: none is inserted, no athanor, no passkey" do
      %{person: _first} = setup!()
      {:ok, _} = Store.allow("wildcard", "*", "ops")
      Settings.put("max_athanors", 1)
      credential = registration()
      watch_person_inserts!()

      assert {:error, {:limit_reached, :max_athanors, 1}} =
               Newcomer.admit(:open, {:passkey, credential, identity()})

      refute_received :person_inserted
      assert people() == 1
      assert passkeys() == 0
    end

    test "past the mint rate is refused before the person's row" do
      %{person: _first} = setup!()
      {:ok, _} = Store.allow("wildcard", "*", "ops")
      {:ok, %{person: _second}} = Newcomer.admit(:open, {:passkey, registration(), identity()})
      Settings.put("mint_per_hour", 1)
      credential = registration()
      watch_person_inserts!()

      assert {:error, {:limit_reached, :mint_per_hour, 1}} =
               Newcomer.admit(:open, {:passkey, credential, identity()})

      refute_received :person_inserted
      assert people() == 2
    end

    test "a registration that verifies while the admission's transaction fails leaves no person and no passkey" do
      %{person: _first} = setup!()
      {:ok, _} = Store.allow("wildcard", "*", "ops")

      # One authenticator answering two ceremonies: the same credential,
      # under two registrations drawn for two people.
      seed = "same-credential-#{System.unique_integer([:positive])}"

      registered = fn ->
        {:ok, options} = Sanctum.Passkeys.newcomer_options()
        Authenticator.registration(Authenticator.new(seed), options)
      end

      {:ok, %{person: _admitted}} = Newcomer.admit(:open, {:passkey, registered.(), identity()})

      person_athanors = fn ->
        Arca.Repo.aggregate(from(a in Arca.Schemas.Athanor, where: a.kind == "person"), :count)
      end

      before = {people(), person_athanors.(), Arca.Repo.aggregate(PersonIdentity, :count)}

      # The second verifies; its transaction writes the person, their keys
      # and their athanor, and the credential's write is refused there, so
      # all of it rolls back.
      assert {:error, {:conflict, _}} =
               Newcomer.admit(:open, {:passkey, registered.(), identity()})

      assert {people(), person_athanors.(), Arca.Repo.aggregate(PersonIdentity, :count)} == before
      assert passkeys() == 1
    end

    test "the same registration presented again makes no one" do
      %{person: _first} = setup!()
      {:ok, _} = Store.allow("wildcard", "*", "ops")
      credential = registration()
      {:ok, _} = Newcomer.admit(:open, {:passkey, credential, identity()})

      assert {:error, :registration_refused} =
               Newcomer.admit(:open, {:passkey, credential, identity()})

      assert people() == 2
      assert passkeys() == 1
    end

    test "takes a passkey only" do
      %{person: _first} = setup!()
      {:ok, _} = Store.allow("wildcard", "*", "ops")

      for credential <- [{:command_line, "laptop", identity()}, :none] do
        assert {:error, {:invalid_argument, _}} = Newcomer.admit(:open, credential)
      end

      assert {:error, {:invalid_argument, _}} = Newcomer.admit({:setup, @token}, :none)
      assert people() == 1
    end
  end

  describe "an invitation admission" do
    setup do
      %{person: admin} = setup!()
      issuer = member!()
      group = group!(issuer)
      %{admin: admin, issuer: issuer, group: group}
    end

    defp member! do
      n = System.unique_integer([:positive])

      {:ok, user} =
        Sanctum.Test.People.linked(%{
          id: "github|https://github.com|issuer-#{n}",
          provider: "github"
        })

      user
    end

    defp group!(creator) do
      {:ok, group} =
        Athanors.create_group(creator.id, "Invited #{System.unique_integer([:positive])}")

      group
    end

    defp invite!(issuer, athanor_id) do
      ctx = Sanctum.TestContext.session!(issuer.id)
      {:ok, %{invitation: invitation, code: code}} = Sanctum.Invitations.create(ctx, athanor_id)
      {invitation.id, code}
    end

    defp invitation_row(id), do: Arca.Repo.get!(Invitation, id)

    defp raise_generation!(user_id) do
      {1, _} =
        Arca.Repo.update_all(from(u in User, where: u.id == ^user_id),
          inc: [security_generation: 1]
        )
    end

    test "makes a local person with keys, an athanor, a passkey and the seat it names, redeemed by them, without the door",
         %{issuer: issuer, group: group} do
      {id, code} = invite!(issuer, group.id)

      assert {:ok,
              %{
                person: person,
                readmitted: false,
                session_token: token,
                recovery: %{name: "invited", code: "CYFR-" <> _, attempt_id: attempt_id}
              }} =
               Newcomer.admit(
                 {:invitation, code},
                 {:passkey, registration(), identity("invited")}
               )

      assert %{id: ^attempt_id, phase: "staged", name: "invited"} = enrollment(person.id)
      assert person.admission == "invitation"
      refute Sanctum.Tenancy.platform_admin?(person.id)
      assert {:ok, _own} = Athanors.get_by_owner(person.id)

      assert %PersonIdentity{provenance: "local"} =
               Arca.Repo.get_by(PersonIdentity, user_id: person.id)

      assert [%Passkey{state: "active"}] =
               Arca.Repo.all(from(p in Passkey, where: p.user_id == ^person.id))

      assert {:ok, %{added_by: added_by}} = Members.active_seat(person.id, group.id)
      assert added_by == issuer.id
      assert %{redeemed_by: redeemed_by, redeemed_at: %DateTime{}} = invitation_row(id)
      assert redeemed_by == person.id
      assert {:ok, %{user_id: _}} = Sanctum.Session.get(token)
      assert Store.requests() == []

      # The code admits once.
      assert {:error, :invitation_invalid} =
               Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})
    end

    test "one naming no athanor seats its person in no group", %{admin: admin} do
      {_id, code} = invite!(admin, nil)

      assert {:ok, %{person: person}} =
               Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})

      own = Sanctum.Test.People.athanor!(person)
      assert {:ok, [%{athanor_id: athanor_id}]} = Members.list_by_user(person.id)
      assert athanor_id == own.id
    end

    test "an expired, a redeemed and a revoked code admit no one: no person, no passkey, no seat",
         %{issuer: issuer, group: group} do
      {expired, expired_code} = invite!(issuer, group.id)

      {1, _} =
        Arca.Repo.update_all(from(i in Invitation, where: i.id == ^expired),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      {_redeemed, redeemed_code} = invite!(issuer, group.id)

      {:ok, _} =
        Newcomer.admit({:invitation, redeemed_code}, {:passkey, registration(), identity()})

      {revoked, revoked_code} = invite!(issuer, group.id)
      {:ok, _} = Sanctum.Invitations.revoke(Sanctum.TestContext.session!(issuer.id), revoked)
      before = {people(), passkeys(), Members.count_by_athanor(group.id)}
      watch_person_inserts!()

      for code <- [expired_code, redeemed_code, revoked_code] do
        assert {:error, :invitation_invalid} =
                 Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})
      end

      refute_received :person_inserted
      assert {people(), passkeys(), Members.count_by_athanor(group.id)} == before

      for id <- [expired, revoked],
          do: assert(%{redeemed_by: nil} = invitation_row(id))
    end

    test "an issuer who lost their seat, and one who was denied, admit no one",
         %{issuer: issuer, group: group} do
      leaver = member!()
      {:ok, :added} = Members.add(group, [user_id: leaver.id], issuer.id)
      {left, left_code} = invite!(leaver, group.id)
      {denied, denied_code} = invite!(issuer, group.id)

      :ok = Members.remove_member(group, user_id: leaver.id)
      {:ok, _} = Sanctum.Tenancy.Users.deny(issuer)
      before = {people(), passkeys()}

      for code <- [left_code, denied_code] do
        assert {:error, :invitation_invalid} =
                 Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})
      end

      assert {people(), passkeys()} == before
      for id <- [left, denied], do: assert(%{redeemed_by: nil} = invitation_row(id))
    end

    test "an invitation issued before a declared restore admits no one after it, " <>
           "even one the restore's revocation missed: no person, no passkey, no seat",
         %{admin: admin, issuer: issuer, group: group} do
      {admin_invitation, admin_code} = invite!(admin, nil)
      {group_invitation, group_code} = invite!(issuer, group.id)
      ids = [admin_invitation, group_invitation]

      {:ok, _} = Arca.SecurityTransitions.mark_restore(Prima.Actor.system())
      assert {:ok, %{restore_id: _}} = Arca.SecurityTransitions.restore(slot: :none)
      before = {people(), passkeys(), Members.count_by_athanor(group.id)}
      watch_person_inserts!()

      for code <- [admin_code, group_code] do
        assert {:error, :invitation_invalid} =
                 Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})
      end

      # A row the restore's revocation missed is retired still: the
      # restore raised its issuer's standing past the one it recorded.
      {2, _} =
        Arca.Repo.update_all(from(i in Invitation, where: i.id in ^ids), set: [revoked_at: nil])

      for code <- [admin_code, group_code] do
        assert {:error, :invitation_invalid} = Sanctum.Invitations.lookup(code)

        assert {:error, :invitation_invalid} =
                 Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})
      end

      refute_received :person_inserted
      assert {people(), passkeys(), Members.count_by_athanor(group.id)} == before
      for id <- ids, do: assert(%{redeemed_by: nil} = invitation_row(id))
    end

    test "an issuer whose standing moved since issue admits no one, though every other check holds",
         %{admin: admin, issuer: issuer, group: group} do
      {admin_invitation, admin_code} = invite!(admin, nil)
      {group_invitation, group_code} = invite!(issuer, group.id)

      for code <- [admin_code, group_code],
          do: assert({:ok, _shown} = Sanctum.Invitations.lookup(code))

      # Each issuer stays active, the administrator still administers and
      # the member is still seated: only the generation moves.
      for person <- [admin, issuer], do: raise_generation!(person.id)
      before = {people(), passkeys(), Members.count_by_athanor(group.id)}
      watch_person_inserts!()

      for code <- [admin_code, group_code] do
        assert {:error, :invitation_invalid} = Sanctum.Invitations.lookup(code)

        assert {:error, :invitation_invalid} =
                 Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})
      end

      refute_received :person_inserted
      assert {people(), passkeys(), Members.count_by_athanor(group.id)} == before

      for id <- [admin_invitation, group_invitation],
          do: assert(%{redeemed_by: nil, revoked_at: nil} = invitation_row(id))

      # One issued at the standing they hold now admits.
      {_id, code} = invite!(issuer, group.id)

      assert {:ok, _} =
               Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})
    end

    test "the group's member cap refused leaves no person, no passkey and the code unredeemed",
         %{issuer: issuer, group: group} do
      {id, code} = invite!(issuer, group.id)
      Settings.put("max_members_per_group", 1)
      before = {people(), passkeys()}

      assert {:error, {:limit_reached, :max_members_per_group, 1}} =
               Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})

      assert {people(), passkeys()} == before
      assert %{redeemed_by: nil, redeemed_at: nil} = invitation_row(id)
      assert Members.count_by_athanor(group.id) == {:ok, 1}
    end

    test "the athanor cap refuses before the person's row, and the code stays unredeemed",
         %{issuer: issuer, group: group} do
      {id, code} = invite!(issuer, group.id)
      {:ok, athanors} = Athanors.count()
      Settings.put("max_athanors", athanors)
      watch_person_inserts!()

      assert {:error, {:limit_reached, :max_athanors, ^athanors}} =
               Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})

      refute_received :person_inserted
      assert %{redeemed_by: nil} = invitation_row(id)
    end

    test "takes a passkey only, and a code that is no code is :invitation_invalid", %{
      issuer: issuer,
      group: group
    } do
      {_id, code} = invite!(issuer, group.id)

      for credential <- [{:command_line, "laptop", identity()}, :none] do
        assert {:error, {:invalid_argument, _}} = Newcomer.admit({:invitation, code}, credential)
      end

      assert {:error, :invitation_invalid} =
               Newcomer.admit({:invitation, nil}, {:passkey, registration(), identity()})
    end
  end

  describe "a remote newcomer" do
    setup %{tls: tls} do
      DirectoryServer.listen!()
      DirectoryServer.seam!(tls)
      directory = DirectoryServer.start!(tls)
      %{person: first} = setup!()
      %{directory: directory, first: first}
    end

    defp remote(identity) do
      %{
        identifier: identity.identifier,
        directory_url: identity.url,
        genesis_hash: Prima.Identity.hash(identity.genesis),
        head_hash: DirectoryServer.key_epoch(identity)
      }
    end

    test "with the directory unreachable is :identity_stale, and no row is written", %{
      directory: directory
    } do
      identity = DirectoryServer.identity!(directory.dir, directory.url)
      {:ok, _} = Store.allow("identifier", identity.identifier, "ops")

      # Nothing cached for the identifier, and its directory is gone.
      DirectoryServer.Server.stop(directory.server)

      assert {:error, :identity_stale} = Newcomer.admit({:remote, remote(identity)}, :none)
      assert people() == 1
      refute Arca.Repo.get_by(PersonIdentity, identifier: identity.identifier)
    end

    test "the door does not admit leaves one request and no row", %{directory: directory} do
      identity = DirectoryServer.identity!(directory.dir, directory.url)
      DirectoryServer.cached!(identity)

      assert {:error, {:door, :not_allowed}} = Newcomer.admit({:remote, remote(identity)}, :none)
      assert [%{kind: "identifier", value: value}] = Store.requests()
      assert value == identity.identifier
      assert people() == 1
    end

    test "is made with no keys and no athanor, linked to their CYFR identity, and their invitations activate",
         %{directory: directory, first: first} do
      identity = DirectoryServer.identity!(directory.dir, directory.url)
      DirectoryServer.cached!(identity)
      {:ok, _} = Store.allow("identifier", identity.identifier, "ops")

      {:ok, group} = Athanors.create_group(first.id, "Invited")
      {:ok, :invited} = Members.add(group, [identifier: identity.identifier], first.id)

      assert {:ok, %{person: person, readmitted: false} = admitted} =
               Newcomer.admit({:remote, remote(identity)}, :none)

      refute Map.has_key?(admitted, :session_token)
      assert person.admission == "remote"

      assert %PersonIdentity{provenance: "remote", live_key_sealed: nil} =
               Arca.Repo.get_by(PersonIdentity, identifier: identity.identifier)

      assert [%ExternalIdentity{provider: "cyfr"}] =
               Arca.Repo.all(from(i in ExternalIdentity, where: i.user_id == ^person.id))

      assert Sanctum.Tenancy.Users.personal_athanor_id(person.id) == :none
      assert Members.member?(person.id, group.id)
      refute Sanctum.Tenancy.platform_admin?(person.id)

      # Admitted again, the identity names the person made first.
      assert {:ok, %{person: %{id: same}}} = Newcomer.admit({:remote, remote(identity)}, :none)
      assert same == person.id
      assert people() == 2
    end
  end

  describe "a linked sign-in method" do
    setup do
      %{person: first} = setup!()
      %{first: first}
    end

    test "an identity no person has linked is :no_person, and leaves no door request" do
      assert {:error, :no_person} =
               Sanctum.SignIn.unlock(%{
                 id: "github|https://github.com|nobody",
                 provider: "github",
                 email: "nobody@example.com",
                 verified: true
               })

      assert people() == 1
      assert Store.list() == []
    end

    test "unlocks the person who linked it and refreshes only a proved contact email", %{
      first: first
    } do
      key = "github|https://github.com|first"

      {:ok, %{linked: true}} =
        Arca.Users.link_identity(Prima.Actor.system(), first.id, %{
          key: key,
          provider: "github",
          issuer: "https://github.com",
          subject: "first"
        })

      assert {:ok, %{id: id, email: nil}} =
               Sanctum.SignIn.unlock(%{id: key, email: "said@example.com", verified: :unknown})

      assert id == first.id

      assert {:ok, %{email: "proved@example.com", email_verified: true}} =
               Sanctum.SignIn.unlock(%{id: key, email: "proved@example.com", verified: true})

      assert people() == 1
    end

    test "a denied person is refused, and no session is opened", %{first: first} do
      {:ok, _} =
        Sanctum.Test.People.linked(%{id: "github|https://github.com|eve", provider: "github"})

      {:ok, eve} = Sanctum.Tenancy.Users.get_by_identity("github|https://github.com|eve")
      {:ok, _} = Store.deny("person", eve.id, first.id)

      assert {:error, {:door, :denied}} =
               Sanctum.SignIn.unlock(%{id: "github|https://github.com|eve", provider: "github"})

      assert sessions(eve.id) == []
    end
  end
end

defmodule Sanctum.NewcomerKilledTest do
  @moduledoc """
  An admission killed mid-transaction, on a real connection outside the
  sandbox: the process dies after the person's row and keys are written
  and before the commit, and nothing of it remains.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Sanctum.Test.Newcomers, only: [identity: 0]

  alias Arca.Schemas.{IdentityAttempt, Membership, PersonIdentity, User}
  alias Ecto.Adapters.SQL.Sandbox

  @token String.duplicate("7a", 32)

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  setup do
    previous = Application.fetch_env(:sanctum, :setup_token)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sanctum, :setup_token, value)
        :error -> Application.delete_env(:sanctum, :setup_token)
      end
    end)

    Application.put_env(:sanctum, :setup_token, @token)
    Sanctum.Test.Newcomers.directory!()

    # The admission is over an empty installation: nothing committed may
    # hold a person when it starts.
    assert 0 == unboxed(fn -> Arca.Repo.aggregate(User, :count) end)
    :ok
  end

  test "an admission killed before its commit leaves no person, no keys, no grant and no enrollment" do
    test = self()
    handler = "newcomer-killed-#{System.unique_integer([:positive])}"

    # Inside the admission's transaction, at its athanor's write: the
    # person's row, their keys and their grant are written and uncommitted.
    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:source] == "athanors" and Process.get(:newcomer_admitting) and
               not Process.get(:newcomer_paused, false) do
            Process.put(:newcomer_paused, true)
            send(test, {:admitting, self()})

            receive do
              :never -> :ok
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    admitting =
      spawn(fn ->
        unboxed(fn ->
          Process.put(:newcomer_admitting, true)
          Sanctum.Newcomer.admit({:setup, @token}, {:command_line, "laptop", identity()})
        end)
      end)

    assert_receive {:admitting, ^admitting}, 15_000
    ref = Process.monitor(admitting)
    Process.exit(admitting, :kill)
    assert_receive {:DOWN, ^ref, :process, ^admitting, :killed}, 5_000

    assert {0, 0, 0, 0} ==
             unboxed(fn ->
               {Arca.Repo.aggregate(User, :count), Arca.Repo.aggregate(PersonIdentity, :count),
                Arca.Repo.aggregate(from(m in Membership, where: m.scope == "platform"), :count),
                Arca.Repo.aggregate(IdentityAttempt, :count)}
             end)
  end
end

defmodule Sanctum.NewcomerInvitationUnboxedTest do
  @moduledoc """
  An invitation's admission on real connections outside the sandbox: two
  admissions of one code released together make one person, an
  admission killed after its redemption and before its commit leaves no
  person and the code unredeemed, and, on PostgreSQL, an issuer who
  leaves the group after the admission's first check is read again under
  the group's lock the seat takes, so the admission makes no one.

  The two racers are released against the installation claims' order row,
  which every mint locks first, held by the test: each has passed the
  check before its transaction and waits there (seen waiting on
  PostgreSQL; on SQLite behind the write lock the holder's transaction
  takes), so the redemption's own transaction decides between them.

  The issuer, their group and the invitation are committed; every row a
  case makes is deleted outside the sandbox when it ends. The athanor's
  fill that follows an admission is the suite's port that fills nothing
  (`Sanctum.Test.Components`), installed for the case and put back.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Arca.Test.Adapter, only: [postgres?: 0]
  import Sanctum.Test.Newcomers, only: [identity: 0]

  alias Arca.Schemas.{
    Athanor,
    ExternalIdentity,
    IdentityAttempt,
    Invitation,
    Membership,
    Passkey,
    PersonIdentity,
    ServerMeta,
    Session,
    User
  }

  alias Arca.Test.LockWait
  alias Ecto.Adapters.SQL.Sandbox
  alias Sanctum.Newcomer
  alias Sanctum.TestContext.Authenticator

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  setup do
    Sanctum.Test.Newcomers.directory!()
    previous = Sanctum.Consent.Components.impl!()
    on_exit(fn -> Sanctum.Consent.Components.install!(previous) end)
    Sanctum.Consent.Components.install!(Sanctum.Test.Components)

    key = "github|https://github.com|invitation-unboxed-#{System.unique_integer([:positive])}"
    registrations = for _ <- 1..2, do: registered()
    newcomers = Enum.map(registrations, &elem(&1, 0))
    on_exit(fn -> unboxed(fn -> cleanup!(key, newcomers) end) end)

    {issuer, group, invitation, code} =
      unboxed(fn ->
        {:ok, issuer} = Sanctum.Test.People.linked(%{id: key, provider: "github"})
        {:ok, group} = Sanctum.Tenancy.Athanors.create_group(issuer.id, "Unboxed #{issuer.id}")
        ctx = Sanctum.Context.build(user_id: issuer.id)
        {:ok, %{invitation: invitation, code: code}} = Sanctum.Invitations.create(ctx, group.id)
        {issuer, group, invitation, code}
      end)

    {:ok,
     key: key,
     issuer: issuer,
     group: group,
     invitation: invitation,
     code: code,
     registrations: registrations}
  end

  # The admission `credential` brings, in a task of its own, paused at its
  # athanor's insert, inside its transaction: the person's row, the
  # redemption and their keys are written and uncommitted. Answers the
  # task once it is paused; `:go` lets it go on.
  defp paused_admission(code, credential) do
    test = self()
    handler = "invitation-paused-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:source] == "athanors" and
               String.starts_with?(metadata[:query] || "", "INSERT") and
               Process.get(:invitation_admitting) and
               not Process.get(:invitation_paused, false) do
            Process.put(:invitation_paused, true)
            send(test, {:admitting, self()})

            receive do
              :go -> :ok
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    task =
      Task.async(fn ->
        unboxed(fn ->
          Process.put(:invitation_admitting, true)
          Newcomer.admit({:invitation, code}, {:passkey, credential, identity()})
        end)
      end)

    assert_receive {:admitting, pid}, 15_000
    assert pid == task.pid
    task
  end

  # A newcomer's registration and the person id it was drawn for, which
  # the case's cleanup names.
  defp registered do
    {:ok, %{registration: token} = options} = unboxed(&Sanctum.Passkeys.newcomer_options/0)
    {:ok, json} = Base.url_decode64(token, padding: false)
    %{"user" => person_id} = Jason.decode!(json)

    credential =
      Authenticator.registration(
        Authenticator.new("invitation-unboxed|#{System.unique_integer([:positive])}"),
        options
      )

    {person_id, credential}
  end

  defp backend do
    if postgres?(), do: hd(hd(Arca.Repo.query!("SELECT pg_backend_pid()").rows))
  end

  defp rows(ids, group_id, invitation_id) do
    unboxed(fn ->
      %{
        people: Arca.Repo.all(from(u in User, where: u.id in ^ids, select: u.id)),
        keys: Arca.Repo.aggregate(from(p in PersonIdentity, where: p.user_id in ^ids), :count),
        passkeys: Arca.Repo.aggregate(from(p in Passkey, where: p.user_id in ^ids), :count),
        seats:
          Arca.Repo.aggregate(
            from(m in Membership, where: m.user_id in ^ids and m.athanor_id == ^group_id),
            :count
          ),
        redeemed_by: Arca.Repo.get!(Invitation, invitation_id).redeemed_by
      }
    end)
  end

  test "two admissions of one code released together make one person", %{
    group: group,
    invitation: invitation,
    code: code,
    registrations: [{first_id, first}, {second_id, second}]
  } do
    test = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            from(m in ServerMeta, where: m.key == ^Arca.SchemaFingerprint.key(), select: m.key)
            |> Arca.QueryHelpers.for_update()
            |> Arca.Repo.one!()

            send(test, :held)

            receive do
              :release -> :ok
            end
          end)
        end)
      end)

    assert_receive :held, 5_000

    racers =
      for credential <- [first, second] do
        Task.async(fn ->
          unboxed(fn ->
            send(test, {:racer, backend()})
            Newcomer.admit({:invitation, code}, {:passkey, credential, identity()})
          end)
        end)
      end

    for _racer <- racers do
      assert_receive {:racer, pid}, 5_000
      if postgres?(), do: LockWait.await_lock_wait!(pid, [~s("server_meta"), "FOR UPDATE"])
    end

    for racer <- racers,
        do: refute(Task.yield(racer, 300), "a racer decided while the order row was held")

    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 10_000)

    assert [{:error, :invitation_invalid}, {:ok, %{person: %{id: winner}}}] =
             racers |> Enum.map(&Task.await(&1, 30_000)) |> Enum.sort()

    assert rows([first_id, second_id], group.id, invitation.id) == %{
             people: [winner],
             keys: 1,
             passkeys: 1,
             seats: 1,
             redeemed_by: winner
           }
  end

  test "an admission killed after its redemption and before its commit leaves no person and the code unredeemed",
       %{
         group: group,
         invitation: invitation,
         code: code,
         registrations: [{person_id, credential} | _]
       } do
    %Task{pid: admitting} = paused_admission(code, credential)
    Process.unlink(admitting)
    ref = Process.monitor(admitting)
    Process.exit(admitting, :kill)
    assert_receive {:DOWN, ^ref, :process, ^admitting, :killed}, 5_000

    assert rows([person_id], group.id, invitation.id) == %{
             people: [],
             keys: 0,
             passkeys: 0,
             seats: 0,
             redeemed_by: nil
           }
  end

  @tag :postgres
  test "an issuer who leaves the group after the admission's first check admits no one", %{
    key: key,
    issuer: issuer,
    group: group,
    invitation: invitation,
    code: code,
    registrations: [{person_id, credential} | _]
  } do
    # A second member, so the issuer's leave archives nothing.
    unboxed(fn ->
      {:ok, peer} = Sanctum.Test.People.linked(%{id: key <> "-peer", provider: "github"})
      {:ok, :added} = Sanctum.Tenancy.Members.add(group, [user_id: peer.id], issuer.id)
    end)

    admission = paused_admission(code, credential)

    assert :ok =
             unboxed(fn ->
               Sanctum.Tenancy.Members.remove_member(group, user_id: issuer.id)
             end)

    send(admission.pid, :go)
    assert {:error, :invitation_invalid} = Task.await(admission, 30_000)

    assert rows([person_id], group.id, invitation.id) == %{
             people: [],
             keys: 0,
             passkeys: 0,
             seats: 0,
             redeemed_by: nil
           }
  end

  # Every row the case made: the people its identity keys name, the
  # newcomers its registrations were drawn for, their athanors, the group,
  # and the invitation.
  defp cleanup!(key, newcomers) do
    issuers =
      Arca.Repo.all(
        from(i in ExternalIdentity, where: i.key in ^[key, key <> "-peer"], select: i.user_id)
      )

    people = issuers ++ newcomers

    athanors =
      Arca.Repo.all(
        from(a in Athanor,
          where: a.owner_user_id in ^people or a.created_by in ^people,
          select: a.id
        )
      )

    Arca.Repo.delete_all(from(i in Invitation, where: i.issued_by in ^issuers))
    Arca.Repo.delete_all(from(s in Session, where: s.user_id in ^people))
    Arca.Repo.delete_all(from(p in Passkey, where: p.user_id in ^people))
    Arca.Repo.delete_all(from(a in IdentityAttempt, where: a.user_id in ^people))
    Arca.Repo.delete_all(from(p in PersonIdentity, where: p.user_id in ^people))

    Arca.Repo.delete_all(
      from(m in Membership, where: m.user_id in ^people or m.athanor_id in ^athanors)
    )

    Arca.Repo.delete_all(from(i in ExternalIdentity, where: i.user_id in ^people))
    Arca.Repo.delete_all(from(u in User, where: u.id in ^people))
    Arca.Repo.delete_all(from(a in Athanor, where: a.id in ^athanors))
  end
end
