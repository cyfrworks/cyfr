# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.NewcomerTest do
  @moduledoc """
  A person is made only by an admission (`Sanctum.Newcomer.admit/2`), and
  a linked sign-in method only unlocks a person who exists
  (`Sanctum.SignIn.unlock/1`).

  Setup makes the installation's first person, their keys, their athanor,
  their credential, their enrollment and the platform administrator's
  mark on their row in one transaction, and answers that person again while no sign-in method of
  theirs works at the home's address, with the enrollment that stands, so
  after the home moves its administrator registers a passkey at the new
  address; from the commit that gives them a working method, the token
  opens nothing. Every local admission brings the new
  person's identity, enrolls them with it in its transaction, answers
  their recovery code, and admits no one where no directory is pinned. An open admission needs
  the door's `*` and passes the athanor caps, and a refusal anywhere in
  its transaction leaves no person, no athanor and no passkey. An
  invitation admits without the door, under its own checks and the same
  caps, and seats its person in the shared thread it names in the
  transaction that redeems it, so a refusal, the thread's people cap and
  a declared restore's hold on the thread among them, leaves no person
  and the code unredeemed; one whose issuer's standing moved since it was
  issued, a declared restore's raise among them, admits no one.
  A remote
  newcomer is admitted by the door's verdict on their identifier, with no
  keys and their own athanor, whose fill follows the commit, under the
  open admission's athanor cap and mint rate, and a directory that cannot
  be read writes no row; their identifier's invitations into shared
  threads become their seats; one whose sign-in carried an invitation is
  admitted by it unless a deny names them, with the redemption, their
  seat in its thread and their identifier's allow in the admission's
  transaction, so a deny committed after the check rolls the whole
  admission back.
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
    PairedClient,
    Passkey,
    PersonIdentity,
    RestorePerson,
    Session,
    SharedThreadMember,
    User
  }

  alias Sanctum.Door.Store
  alias Sanctum.{Newcomer, SharedThreads}
  alias Sanctum.Tenancy.Athanors
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
  defp registration, do: registration(authenticator())

  defp registration(auth) do
    {:ok, options} = Sanctum.Passkeys.newcomer_options()
    Authenticator.registration(auth, options)
  end

  defp authenticator, do: Authenticator.new("newcomer|#{System.unique_integer([:positive])}")

  # The home moves to `origin`: the address every ceremony is bound to.
  defp move_home!(origin), do: Prima.Test.Env.put_app_env(:sanctum, :public_url, origin)

  defp sign_in(auth) do
    challenge = Sanctum.Passkeys.sign_in_challenge()
    Sanctum.Passkeys.sign_in(challenge, Authenticator.assertion(auth, challenge.challenge))
  end

  defp people, do: Arca.Repo.aggregate(User, :count)
  defp passkeys, do: Arca.Repo.aggregate(Passkey, :count)

  # The people who carry the platform administrator's mark.
  defp administrators,
    do: Arca.Repo.aggregate(from(u in User, where: not is_nil(u.platform_admin_at)), :count)

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

  # A protected device's enrollment for `identity`, as
  # `Sanctum.DeviceUnlock` hands it to the admission once its proof
  # verified: the athanor and client reserved for it (the person's own
  # athanor `athanor_id` for a re-admission), its key and its holder.
  defp device(identity, athanor_id \\ nil) do
    {:device,
     %{
       athanor_id: athanor_id || Prima.UUID7.generate_id("ath"),
       client_id: Prima.UUID7.generate_id("pcl"),
       device_key: :crypto.strong_rand_bytes(32),
       request_id: identity.request_id,
       holder_kind: "chip",
       display_name: "laptop",
       user_id: nil
     }, identity}
  end

  defp setup!(credential \\ device(identity())) do
    {:ok, admitted} = Newcomer.admit({:setup, @token}, credential)
    admitted
  end

  # The person setup made, who holds no method at this home's address: the
  # device setup enrolled for them revoked since.
  defp methodless!(identity \\ identity()) do
    admitted = setup!(device(identity))
    revoke_devices!(admitted.person.id)
    admitted
  end

  defp revoke_devices!(user_id) do
    for client <-
          Arca.Repo.all(
            from(c in PairedClient, where: c.user_id == ^user_id and c.standing == "active")
          ) do
      {:ok, _revoked} =
        Arca.PairedClients.revoke(Prima.Actor.in_athanor(client.athanor_id), client.id)
    end

    :ok
  end

  defp own_athanor(user_id) do
    {:ok, %{id: athanor_id}} = Athanors.get_by_owner(user_id)
    athanor_id
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

  defp thread!(creator) do
    {:ok, thread} =
      SharedThreads.create(creator.id, "Invited #{System.unique_integer([:positive])}")

    thread
  end

  # The person's seat in the thread, as its row of people.
  defp seat(user_id, thread_id) do
    Arca.Repo.one(
      from(m in SharedThreadMember,
        where: m.thread_id == ^thread_id and m.user_id == ^user_id and m.status == "active"
      )
    )
  end

  defp people_rows(thread),
    do:
      Arca.Repo.aggregate(from(m in SharedThreadMember, where: m.thread_id == ^thread.id), :count)

  describe "setup" do
    test "makes the first person with their keys, athanor and passkey, signs them in, and grants the platform role" do
      assert {:ok, %{person: person, readmitted: false, session_token: token}} =
               Newcomer.admit({:setup, @token}, {:passkey, registration(), identity()})

      assert person.admission == "setup"
      assert people() == 1

      assert %PersonIdentity{provenance: "local", live_public_key: <<_::binary>>} =
               Arca.Repo.get_by(PersonIdentity, user_id: person.id)

      assert {:ok, _athanor} = Athanors.get_by_owner(person.id)

      assert Sanctum.Tenancy.platform_admin?(person.id)
      assert administrators() == 1

      assert [%Passkey{state: "active"}] =
               Arca.Repo.all(from(p in Passkey, where: p.user_id == ^person.id))

      assert {:ok, %{user_id: user_id, provider: "passkey"}} = Sanctum.Session.get(token)
      assert user_id == person.id
    end

    test "enrolls the person in its transaction with the identity it brings, and answers their recovery code" do
      identity = identity("mira")

      assert {:ok, %{person: person, recovery: recovery}} =
               Newcomer.admit({:setup, @token}, device(identity))

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
      %{person: person, recovery: recovery} = methodless!(first)

      assert {:ok, %{person: %{id: same}, readmitted: true, recovery: ^recovery}} =
               Newcomer.admit(
                 {:setup, @token},
                 device(identity("second"), own_athanor(person.id))
               )

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

      revoke_devices!(person.id)

      assert {:ok, %{recovery: saved}} =
               Newcomer.admit({:setup, @token}, device(identity(), own_athanor(person.id)))

      assert saved == Map.delete(recovery, :code)
    end

    test "a credential without the new person's identity is refused, and nothing is written" do
      %{recovery_secret: secret} = valid = identity()
      registration = registration()

      {:device, enrollment, _identity} = device(valid)

      for credential <- [
            {:device, enrollment},
            {:passkey, registration},
            {:device, enrollment, nil},
            {:passkey, registration, %{}},
            {:device, enrollment, %{valid | name: "Not A Name"}},
            {:device, enrollment, %{valid | recovery_secret: binary_part(secret, 0, 31)}},
            {:device, enrollment, %{valid | request_id: "no spaces allowed"}},
            # The command line's credential is gone: a shape no admission takes.
            {:command_line, "laptop", valid}
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
               Newcomer.admit({:setup, @token}, device(identity()))

      Prima.Test.Env.put_app_env(:sanctum, :directory_url, "")

      assert {:error, :no_directory} =
               Newcomer.admit({:setup, @token}, device(identity()))

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

    test "answers the same person again, with the device it brings and no session, while they hold no method" do
      first = setup!()
      assert %{readmitted: false} = first
      refute Map.has_key?(first, :session_token)

      # The device setup enrolled closes setup while it stands.
      assert {:error, :setup_closed} =
               Newcomer.admit({:setup, @token}, device(identity(), own_athanor(first.person.id)))

      revoke_devices!(first.person.id)

      assert {:ok, %{person: again, readmitted: true} = admitted} =
               Newcomer.admit({:setup, @token}, device(identity(), own_athanor(first.person.id)))

      refute Map.has_key?(admitted, :session_token)
      assert again.id == first.person.id
      assert people() == 1
      assert administrators() == 1
      assert athanors(again.id) == 1
      assert sessions(again.id) == []

      assert ["active", "revoked"] =
               Arca.Repo.all(
                 from(c in PairedClient,
                   where: c.user_id == ^again.id,
                   order_by: c.standing,
                   select: c.standing
                 )
               )
    end

    test "two setups: the second answers the first person, and once they hold a passkey the token opens nothing" do
      %{person: first} = methodless!()

      assert {:ok, %{person: %{id: same}, readmitted: true}} =
               Newcomer.admit({:setup, @token}, {:passkey, registration(), identity()})

      assert same == first.id

      assert [%Passkey{state: "active"}] =
               Arca.Repo.all(from(p in Passkey, where: p.user_id == ^first.id))

      assert {:error, :setup_closed} =
               Newcomer.admit({:setup, @token}, device(identity(), own_athanor(first.id)))

      assert {:error, :setup_closed} =
               Newcomer.admit({:setup, @token}, {:passkey, registration(), identity()})

      assert people() == 1
      assert passkeys() == 1
      assert length(sessions(first.id)) == 1
    end

    test "opens nothing once the person links a sign-in method" do
      %{person: first} = methodless!()

      {:ok, %{linked: true}} =
        Arca.Users.link_identity(Prima.Actor.system(), first.id, %{
          key: "github|https://github.com|setup-link",
          provider: "github",
          issuer: "https://github.com",
          subject: "setup-link"
        })

      assert {:error, :setup_closed} =
               Newcomer.admit({:setup, @token}, device(identity(), own_athanor(first.id)))

      assert sessions(first.id) == []
    end

    test "the first-method mark alone, which a connected device sets, leaves it open" do
      # The device setup enrolled set the mark; revoked, it is no method.
      %{person: first} = methodless!()

      assert %{first_method_at: %DateTime{}} =
               Arca.Repo.get_by!(PersonIdentity, user_id: first.id)

      assert {:ok, %{person: %{id: same}, readmitted: true}} =
               Newcomer.admit({:setup, @token}, device(identity(), own_athanor(first.id)))

      assert same == first.id
    end

    test "after the home moves, its administrator registers a passkey at the new address, which signs them in, and then it opens nothing" do
      move_home!("https://a.example")
      before = authenticator()

      %{person: admin} = setup!({:passkey, registration(before), identity("mira")})
      assert {:error, :setup_closed} = Newcomer.setup_open(@token)

      move_home!("https://b.example")
      assert {:error, :assertion_refused} = sign_in(before)
      now = authenticator()

      assert {:ok, %{person: %{id: same}, readmitted: true, session_token: token}} =
               Newcomer.admit({:setup, @token}, {:passkey, registration(now), identity()})

      assert same == admin.id
      assert {:ok, %{user_id: ^same, provider: "passkey"}} = Sanctum.Session.get(token)

      assert [
               %Passkey{rp_id: "a.example", state: "active"},
               %Passkey{rp_id: "b.example", state: "active"}
             ] =
               Arca.Repo.all(from(p in Passkey, where: p.user_id == ^same, order_by: p.rp_id))

      assert {:ok, %{session_token: signed_in}} = sign_in(now)
      assert {:ok, %{user_id: ^same}} = Sanctum.Session.get(signed_in)
      assert {:error, :assertion_refused} = sign_in(before)

      assert {:error, :setup_closed} = Newcomer.setup_open(@token)

      assert {:error, :setup_closed} =
               Newcomer.admit({:setup, @token}, device(identity(), own_athanor(admin.id)))

      assert people() == 1
      assert administrators() == 1
    end

    test "after the home moves, an administrator who linked a sign-in method is not let in again" do
      move_home!("https://a.example")
      %{person: admin} = setup!({:passkey, registration(), identity()})

      {:ok, %{linked: true}} =
        Arca.Users.link_identity(Prima.Actor.system(), admin.id, %{
          key: "github|https://github.com|moved-admin",
          provider: "github",
          issuer: "https://github.com",
          subject: "moved-admin"
        })

      move_home!("https://b.example")
      assert {:error, :setup_closed} = Newcomer.setup_open(@token)

      assert {:error, :setup_closed} =
               Newcomer.admit({:setup, @token}, {:passkey, registration(), identity()})

      assert passkeys() == 1
    end

    test "after the home moves, another person's passkey at the new address leaves the administrator's way in open" do
      move_home!("https://a.example")
      %{person: admin} = setup!({:passkey, registration(), identity("mira")})

      move_home!("https://b.example")
      {:ok, _} = Store.allow("wildcard", "*", "ops")

      assert {:ok, %{person: other, readmitted: false}} =
               Newcomer.admit(:open, {:passkey, registration(), identity()})

      refute other.id == admin.id
      assert {:ok, {:readmit, "mira"}} = Newcomer.setup_open(@token)

      assert {:ok, %{person: %{id: same}, readmitted: true}} =
               Newcomer.admit({:setup, @token}, device(identity(), own_athanor(admin.id)))

      assert same == admin.id
    end

    test "a token that is not the configured one, a missing one, or none configured, opens nothing and writes nothing" do
      assert {:error, :setup_closed} =
               Newcomer.admit(
                 {:setup, String.duplicate("0", 64)},
                 device(identity())
               )

      assert {:error, :setup_closed} =
               Newcomer.admit({:setup, "short"}, device(identity()))

      for credential <- [
            device(identity()),
            {:passkey, registration(), identity()},
            :none
          ] do
        assert {:error, :setup_closed} = Newcomer.admit({:setup, nil}, credential)
      end

      Application.delete_env(:sanctum, :setup_token)

      assert {:error, :setup_closed} =
               Newcomer.admit({:setup, @token}, device(identity()))

      assert people() == 0
    end

    test "setup_open/1 answers before any ceremony what the admission would, one refusal for both" do
      assert {:ok, :first} = Newcomer.setup_open(@token)
      assert {:error, :setup_closed} = Newcomer.setup_open(String.duplicate("0", 64))
      assert {:error, :setup_closed} = Newcomer.setup_open(nil)

      # The person setup made, with no sign-in method yet, is answered
      # again, by the name their enrollment holds.
      _admitted = methodless!(identity("mira"))

      assert {:ok, {:readmit, "mira"}} = Newcomer.setup_open(@token)

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
               Newcomer.admit({:setup, @token}, device(identity()))

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
      assert administrators() == 0
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
      assert administrators() == 1
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

      all_athanors = fn -> Arca.Repo.aggregate(Arca.Schemas.Athanor, :count) end
      before = {people(), all_athanors.(), Arca.Repo.aggregate(PersonIdentity, :count)}

      # The second verifies; its transaction writes the person, their keys
      # and their athanor, and the credential's write is refused there, so
      # all of it rolls back.
      assert {:error, {:conflict, _}} =
               Newcomer.admit(:open, {:passkey, registered.(), identity()})

      assert {people(), all_athanors.(), Arca.Repo.aggregate(PersonIdentity, :count)} == before
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

    test "takes a passkey or a protected device, never another credential" do
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
      thread = thread!(issuer)
      %{admin: admin, issuer: issuer, thread: thread}
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

    defp invite!(issuer, thread_id) do
      ctx = Sanctum.TestContext.session!(issuer.id)
      {:ok, %{invitation: invitation, code: code}} = Sanctum.Invitations.create(ctx, thread_id)
      {invitation.id, code}
    end

    defp invitation_row(id), do: Arca.Repo.get!(Invitation, id)

    defp raise_generation!(user_id) do
      {1, _} =
        Arca.Repo.update_all(from(u in User, where: u.id == ^user_id),
          inc: [security_generation: 1]
        )
    end

    test "makes a local person with keys, an athanor, a passkey and the seat in the thread it names, redeemed by them, without the door",
         %{issuer: issuer, thread: thread} do
      {id, code} = invite!(issuer, thread.id)

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

      assert %SharedThreadMember{added_by: added_by} = seat(person.id, thread.id)
      assert added_by == issuer.id
      assert {:ok, %{status: "active"}} = SharedThreads.get(person.id, thread.id)
      assert %{redeemed_by: redeemed_by, redeemed_at: %DateTime{}} = invitation_row(id)
      assert redeemed_by == person.id
      assert {:ok, %{user_id: _}} = Sanctum.Session.get(token)
      assert Store.requests() == []

      # The code admits once.
      assert {:error, :invitation_invalid} =
               Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})
    end

    test "one naming no thread seats its person in none", %{admin: admin} do
      {_id, code} = invite!(admin, nil)

      assert {:ok, %{person: person}} =
               Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})

      assert %{owner_user_id: owner} = Sanctum.Test.People.athanor!(person)
      assert owner == person.id
      assert {:ok, []} = SharedThreads.list(person.id)
    end

    test "an expired, a redeemed and a revoked code admit no one: no person, no passkey, no seat",
         %{issuer: issuer, thread: thread} do
      {expired, expired_code} = invite!(issuer, thread.id)

      {1, _} =
        Arca.Repo.update_all(from(i in Invitation, where: i.id == ^expired),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      {_redeemed, redeemed_code} = invite!(issuer, thread.id)

      {:ok, _} =
        Newcomer.admit({:invitation, redeemed_code}, {:passkey, registration(), identity()})

      {revoked, revoked_code} = invite!(issuer, thread.id)
      {:ok, _} = Sanctum.Invitations.revoke(Sanctum.TestContext.session!(issuer.id), revoked)
      before = {people(), passkeys(), people_rows(thread)}
      watch_person_inserts!()

      for code <- [expired_code, redeemed_code, revoked_code] do
        assert {:error, :invitation_invalid} =
                 Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})
      end

      refute_received :person_inserted
      assert {people(), passkeys(), people_rows(thread)} == before

      for id <- [expired, revoked],
          do: assert(%{redeemed_by: nil} = invitation_row(id))
    end

    test "an issuer who left the thread, and one who was denied, admit no one",
         %{issuer: issuer, thread: thread} do
      leaver = member!()
      stayer = member!()
      {:ok, :added} = SharedThreads.add(issuer.id, thread.id, user_id: leaver.id)
      {:ok, :added} = SharedThreads.add(issuer.id, thread.id, user_id: stayer.id)
      {left, left_code} = invite!(leaver, thread.id)
      {denied, denied_code} = invite!(issuer, thread.id)

      {:ok, %{ended: false}} = SharedThreads.leave(leaver.id, thread.id)
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
         %{admin: admin, issuer: issuer, thread: thread} do
      {admin_invitation, admin_code} = invite!(admin, nil)
      {thread_invitation, thread_code} = invite!(issuer, thread.id)
      ids = [admin_invitation, thread_invitation]

      {:ok, _} = Arca.SecurityTransitions.mark_restore(Prima.Actor.system())
      assert {:ok, %{restore_id: _}} = Arca.SecurityTransitions.restore(slot: :none)
      before = {people(), passkeys(), people_rows(thread)}
      watch_person_inserts!()

      for code <- [admin_code, thread_code] do
        assert {:error, :invitation_invalid} =
                 Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})
      end

      # A row the restore's revocation missed is retired still: the
      # restore raised its issuer's standing past the one it recorded.
      {2, _} =
        Arca.Repo.update_all(from(i in Invitation, where: i.id in ^ids), set: [revoked_at: nil])

      for code <- [admin_code, thread_code] do
        assert {:error, :invitation_invalid} = Sanctum.Invitations.lookup(code)

        assert {:error, :invitation_invalid} =
                 Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})
      end

      refute_received :person_inserted
      assert {people(), passkeys(), people_rows(thread)} == before
      for id <- ids, do: assert(%{redeemed_by: nil} = invitation_row(id))
    end

    test "an issuer whose standing moved since issue admits no one, though every other check holds",
         %{admin: admin, issuer: issuer, thread: thread} do
      {admin_invitation, admin_code} = invite!(admin, nil)
      {thread_invitation, thread_code} = invite!(issuer, thread.id)

      for code <- [admin_code, thread_code],
          do: assert({:ok, _shown} = Sanctum.Invitations.lookup(code))

      # Each issuer stays active, the administrator still administers and
      # the issuer is still seated: only the generation moves.
      for person <- [admin, issuer], do: raise_generation!(person.id)
      before = {people(), passkeys(), people_rows(thread)}
      watch_person_inserts!()

      for code <- [admin_code, thread_code] do
        assert {:error, :invitation_invalid} = Sanctum.Invitations.lookup(code)

        assert {:error, :invitation_invalid} =
                 Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})
      end

      refute_received :person_inserted
      assert {people(), passkeys(), people_rows(thread)} == before

      for id <- [admin_invitation, thread_invitation],
          do: assert(%{redeemed_by: nil, revoked_at: nil} = invitation_row(id))

      # One issued at the standing they hold now admits.
      {_id, code} = invite!(issuer, thread.id)

      assert {:ok, _} =
               Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})
    end

    test "the thread's people cap reached leaves no person, no passkey and the code unredeemed",
         %{issuer: issuer, thread: thread} do
      {id, code} = invite!(issuer, thread.id)
      Settings.put("max_people_per_thread", 1)
      before = {people(), passkeys()}

      assert {:error, {:limit_reached, :max_people_per_thread, 1}} =
               Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})

      assert {people(), passkeys()} == before
      assert %{redeemed_by: nil, redeemed_at: nil} = invitation_row(id)
      assert people_rows(thread) == 1
    end

    test "a thread a declared restore holds admits no one by its invitation, and the code stays unredeemed",
         %{issuer: issuer, thread: thread} do
      peer = member!()
      {:ok, :added} = SharedThreads.add(issuer.id, thread.id, user_id: peer.id)
      {id, code} = invite!(issuer, thread.id)

      # The peer still recovers from a declared restore, so the thread
      # admits no one new.
      Arca.Repo.insert!(%RestorePerson{
        restore_id: Prima.UUID7.generate_id("rst"),
        user_id: peer.id,
        open: true
      })

      before = {people(), passkeys()}

      assert {:error, :recovering_from_restore} =
               Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})

      assert {people(), passkeys()} == before
      assert %{redeemed_by: nil, redeemed_at: nil} = invitation_row(id)
      assert people_rows(thread) == 2
      assert :ok = Sanctum.Invitations.redeemable(code)
    end

    test "the athanor cap refuses before the person's row, and the code stays unredeemed",
         %{issuer: issuer, thread: thread} do
      {id, code} = invite!(issuer, thread.id)
      {:ok, athanors} = Athanors.count()
      Settings.put("max_athanors", athanors)
      watch_person_inserts!()

      assert {:error, {:limit_reached, :max_athanors, ^athanors}} =
               Newcomer.admit({:invitation, code}, {:passkey, registration(), identity()})

      refute_received :person_inserted
      assert %{redeemed_by: nil} = invitation_row(id)
    end

    test "takes a passkey or a protected device, never another credential, and a code that is no code is :invitation_invalid",
         %{
           issuer: issuer,
           thread: thread
         } do
      {_id, code} = invite!(issuer, thread.id)

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

    # An identity of the directory's, its head cached and the door's allow
    # on its identifier: one a remote admission admits.
    defp allowed!(directory) do
      identity = DirectoryServer.identity!(directory.dir, directory.url)
      DirectoryServer.cached!(identity)
      {:ok, _} = Store.allow("identifier", identity.identifier, "ops")
      identity
    end

    # The fill an admission asks for its person's athanor, told to the
    # asking process by a facts port that fills nothing, installed for the
    # case and put back.
    defp watch_fills! do
      previous = Sanctum.Consent.Components.impl!()
      on_exit(fn -> Sanctum.Consent.Components.install!(previous) end)
      Sanctum.Consent.Components.install!(Sanctum.NewcomerTest.FillWatch)
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

    test "is made with no keys and their own athanor, whose fill is asked, linked to their CYFR identity",
         %{directory: directory} do
      identity = allowed!(directory)
      watch_fills!()

      assert {:ok, %{person: person, readmitted: false} = admitted} =
               Newcomer.admit({:remote, remote(identity)}, :none)

      refute Map.has_key?(admitted, :session_token)
      assert person.admission == "remote"

      assert %PersonIdentity{provenance: "remote", live_key_sealed: nil} =
               Arca.Repo.get_by(PersonIdentity, identifier: identity.identifier)

      assert [%ExternalIdentity{provider: "cyfr"}] =
               Arca.Repo.all(from(i in ExternalIdentity, where: i.user_id == ^person.id))

      # Their own athanor, owned by them; its fill asked once the
      # admission committed.
      assert {:ok, %{id: athanor_id}} = Athanors.get_by_owner(person.id)
      assert_received {:fill_asked, ^athanor_id, "sign_in"}
      refute Sanctum.Tenancy.platform_admin?(person.id)

      # Admitted again, the identity names the person made first, and the
      # athanor they hold already.
      assert {:ok, %{person: %{id: same}}} = Newcomer.admit({:remote, remote(identity)}, :none)
      assert same == person.id
      assert people() == 2
      assert athanors(person.id) == 1
    end

    test "is refused at the athanor cap before the person's row, as an open admission is", %{
      directory: directory
    } do
      identity = allowed!(directory)
      {:ok, athanors} = Athanors.count()
      Settings.put("max_athanors", athanors)
      watch_person_inserts!()

      assert {:error, {:limit_reached, :max_athanors, ^athanors}} =
               Newcomer.admit({:remote, remote(identity)}, :none)

      refute_received :person_inserted
      assert people() == 1
      refute Arca.Repo.get_by(PersonIdentity, identifier: identity.identifier)
    end

    test "is refused past the mint rate before the person's row, as an open admission is", %{
      directory: directory
    } do
      {:ok, _} = Newcomer.admit({:remote, remote(allowed!(directory))}, :none)
      identity = allowed!(directory)
      Settings.put("mint_per_hour", 1)
      watch_person_inserts!()

      assert {:error, {:limit_reached, :mint_per_hour, 1}} =
               Newcomer.admit({:remote, remote(identity)}, :none)

      refute_received :person_inserted
      assert people() == 2
      refute Arca.Repo.get_by(PersonIdentity, identifier: identity.identifier)
    end

    test "their identifier's invitations become their seats once admitted",
         %{directory: directory, first: first} do
      identity = allowed!(directory)
      thread = thread!(first)
      {:ok, :added} = SharedThreads.add(first.id, thread.id, identifier: identity.identifier)

      assert [%SharedThreadMember{status: "invited"}] =
               Arca.Repo.all(
                 from(m in SharedThreadMember,
                   where: m.person_identifier == ^identity.identifier
                 )
               )

      assert {:ok, %{person: person}} = Newcomer.admit({:remote, remote(identity)}, :none)

      assert %SharedThreadMember{status: "active"} = seat(person.id, thread.id)
      assert people_rows(thread) == 2
      assert {:ok, [%{id: thread_id}]} = SharedThreads.list(person.id)
      assert thread_id == thread.id
    end

    test "with an invitation, is admitted by it: the redemption, the seat in its thread and the allow in one transaction",
         %{directory: directory, first: first} do
      identity = DirectoryServer.identity!(directory.dir, directory.url)
      DirectoryServer.cached!(identity)
      thread = thread!(first)
      {invitation, hash} = invitation!(first, thread)

      assert {:ok, %{person: person}} =
               Newcomer.admit({:remote, Map.put(remote(identity), :invitation, hash)}, :none)

      assert person.admission == "remote"
      assert %SharedThreadMember{added_by: seated_by} = seat(person.id, thread.id)
      assert seated_by == first.id
      assert {:ok, _own} = Athanors.get_by_owner(person.id)
      assert Arca.Repo.get!(Invitation, invitation.id).redeemed_by == person.id
      note = "invitation " <> invitation.id
      added_by = first.id

      assert [%{effect: "allow", status: "allowed", added_by: ^added_by, note: ^note}] =
               door(identity.identifier)

      # The allow admits the next sign-in, with no invitation.
      assert {:ok, :allowed} = Sanctum.Door.admit_person(person)
    end

    test "with an invitation, a denied identifier is refused and the invitation stays unspent",
         %{directory: directory, first: first} do
      identity = DirectoryServer.identity!(directory.dir, directory.url)
      DirectoryServer.cached!(identity)
      thread = thread!(first)
      {invitation, hash} = invitation!(first, thread)
      {:ok, deny} = Store.deny("identifier", identity.identifier, "ops")

      assert {:error, {:door, :denied}} =
               Newcomer.admit({:remote, Map.put(remote(identity), :invitation, hash)}, :none)

      assert people() == 1
      assert %{redeemed_at: nil} = Arca.Repo.get!(Invitation, invitation.id)
      assert door(identity.identifier) == [deny]
      assert people_rows(thread) == 1
    end

    test "with an invitation that can no longer be used, no one is admitted and nothing written",
         %{directory: directory, first: first} do
      identity = DirectoryServer.identity!(directory.dir, directory.url)
      DirectoryServer.cached!(identity)
      thread = thread!(first)
      {invitation, hash} = invitation!(first, thread)
      {:ok, _} = Sanctum.Invitations.revoke(Sanctum.TestContext.session!(first.id), invitation.id)

      assert {:error, :invitation_invalid} =
               Newcomer.admit({:remote, Map.put(remote(identity), :invitation, hash)}, :none)

      assert people() == 1
      assert door(identity.identifier) == []
      assert Store.requests() == []
    end

    test "with an invitation, a refusal after the redemption rolls the whole admission back",
         %{directory: directory, first: first} do
      identity = DirectoryServer.identity!(directory.dir, directory.url)
      DirectoryServer.cached!(identity)
      thread = thread!(first)
      {invitation, hash} = invitation!(first, thread)
      Settings.put("max_people_per_thread", 1)

      assert {:error, {:limit_reached, :max_people_per_thread, 1}} =
               Newcomer.admit({:remote, Map.put(remote(identity), :invitation, hash)}, :none)

      assert people() == 1
      assert %{redeemed_at: nil} = Arca.Repo.get!(Invitation, invitation.id)
      assert door(identity.identifier) == []
      assert people_rows(thread) == 1
      refute Arca.Repo.get_by(PersonIdentity, identifier: identity.identifier)
    end
  end

  defp invitation!(issuer, thread) do
    ctx = Sanctum.TestContext.session!(issuer.id)
    {:ok, %{invitation: invitation, code: code}} = Sanctum.Invitations.create(ctx, thread.id)
    {:ok, hash} = Sanctum.Invitations.code_hash(code)
    {invitation, hash}
  end

  defp door(identifier), do: Enum.filter(Store.list(), &(&1.value == identifier))

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

  alias Arca.Schemas.{IdentityAttempt, PersonIdentity, User}
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

  test "an admission killed before its commit leaves no person, no keys, no mark and no enrollment" do
    test = self()
    handler = "newcomer-killed-#{System.unique_integer([:positive])}"

    # Inside the admission's transaction, at its athanor's write: the
    # person's row with its mark and their keys are written and uncommitted.
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
          identity = identity()

          Sanctum.Newcomer.admit(
            {:setup, @token},
            {:device,
             %{
               athanor_id: Prima.UUID7.generate_id("ath"),
               client_id: Prima.UUID7.generate_id("pcl"),
               device_key: :crypto.strong_rand_bytes(32),
               request_id: identity.request_id,
               holder_kind: "chip",
               display_name: "laptop",
               user_id: nil
             }, identity}
          )
        end)
      end)

    assert_receive {:admitting, ^admitting}, 15_000
    ref = Process.monitor(admitting)
    Process.exit(admitting, :kill)
    assert_receive {:DOWN, ^ref, :process, ^admitting, :killed}, 5_000

    administrators = from(u in User, where: not is_nil(u.platform_admin_at))

    assert {0, 0, 0, 0} ==
             unboxed(fn ->
               {Arca.Repo.aggregate(User, :count), Arca.Repo.aggregate(PersonIdentity, :count),
                Arca.Repo.aggregate(administrators, :count),
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
  leaves the thread after the admission's first check is read again under
  the thread's lock the seat takes, so the admission makes no one.

  The two racers are released against the installation claims' order row,
  which every mint locks first, held by the test: each has passed the
  check before its transaction and waits there (seen waiting on
  PostgreSQL; on SQLite behind the write lock the holder's transaction
  takes), so the redemption's own transaction decides between them.

  The issuer, their shared thread and the invitation are committed; every row a
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
    Passkey,
    PersonIdentity,
    ServerMeta,
    Session,
    SharedThread,
    SharedThreadMember,
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

    {issuer, thread, invitation, code} =
      unboxed(fn ->
        {:ok, issuer} = Sanctum.Test.People.linked(%{id: key, provider: "github"})
        {:ok, thread} = Sanctum.SharedThreads.create(issuer.id, "Unboxed #{issuer.id}")
        ctx = Sanctum.Context.build(user_id: issuer.id)
        {:ok, %{invitation: invitation, code: code}} = Sanctum.Invitations.create(ctx, thread.id)
        {issuer, thread, invitation, code}
      end)

    {:ok,
     key: key,
     issuer: issuer,
     thread: thread,
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

  defp rows(ids, thread_id, invitation_id) do
    unboxed(fn ->
      %{
        people: Arca.Repo.all(from(u in User, where: u.id in ^ids, select: u.id)),
        keys: Arca.Repo.aggregate(from(p in PersonIdentity, where: p.user_id in ^ids), :count),
        passkeys: Arca.Repo.aggregate(from(p in Passkey, where: p.user_id in ^ids), :count),
        seats:
          Arca.Repo.aggregate(
            from(m in SharedThreadMember,
              where: m.user_id in ^ids and m.thread_id == ^thread_id
            ),
            :count
          ),
        redeemed_by: Arca.Repo.get!(Invitation, invitation_id).redeemed_by
      }
    end)
  end

  test "two admissions of one code released together make one person", %{
    thread: thread,
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

    assert rows([first_id, second_id], thread.id, invitation.id) == %{
             people: [winner],
             keys: 1,
             passkeys: 1,
             seats: 1,
             redeemed_by: winner
           }
  end

  test "an admission killed after its redemption and before its commit leaves no person and the code unredeemed",
       %{
         thread: thread,
         invitation: invitation,
         code: code,
         registrations: [{person_id, credential} | _]
       } do
    %Task{pid: admitting} = paused_admission(code, credential)
    Process.unlink(admitting)
    ref = Process.monitor(admitting)
    Process.exit(admitting, :kill)
    assert_receive {:DOWN, ^ref, :process, ^admitting, :killed}, 5_000

    assert rows([person_id], thread.id, invitation.id) == %{
             people: [],
             keys: 0,
             passkeys: 0,
             seats: 0,
             redeemed_by: nil
           }
  end

  @tag :postgres
  test "an issuer who leaves the thread after the admission's first check admits no one", %{
    key: key,
    issuer: issuer,
    thread: thread,
    invitation: invitation,
    code: code,
    registrations: [{person_id, credential} | _]
  } do
    # A second member, so the issuer's leave archives nothing.
    unboxed(fn ->
      {:ok, peer} = Sanctum.Test.People.linked(%{id: key <> "-peer", provider: "github"})
      {:ok, :added} = Sanctum.SharedThreads.add(issuer.id, thread.id, user_id: peer.id)
    end)

    admission = paused_admission(code, credential)

    assert {:ok, %{ended: false}} =
             unboxed(fn -> Sanctum.SharedThreads.leave(issuer.id, thread.id) end)

    send(admission.pid, :go)
    assert {:error, :invitation_invalid} = Task.await(admission, 30_000)

    assert rows([person_id], thread.id, invitation.id) == %{
             people: [],
             keys: 0,
             passkeys: 0,
             seats: 0,
             redeemed_by: nil
           }
  end

  # Every row the case made: the people its identity keys name, the
  # newcomers its registrations were drawn for, their athanors, the
  # thread with its people, and the invitation.
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

    threads =
      Arca.Repo.all(from(t in SharedThread, where: t.created_by in ^issuers, select: t.id))

    Arca.Repo.delete_all(
      from(m in SharedThreadMember, where: m.thread_id in ^threads or m.user_id in ^people)
    )

    Arca.Repo.delete_all(from(t in SharedThread, where: t.id in ^threads))
    Arca.Repo.delete_all(from(s in Session, where: s.user_id in ^people))
    Arca.Repo.delete_all(from(p in Passkey, where: p.user_id in ^people))
    Arca.Repo.delete_all(from(a in IdentityAttempt, where: a.user_id in ^people))
    Arca.Repo.delete_all(from(p in PersonIdentity, where: p.user_id in ^people))

    Arca.Repo.delete_all(from(i in ExternalIdentity, where: i.user_id in ^people))
    Arca.Repo.delete_all(from(u in User, where: u.id in ^people))
    Arca.Repo.delete_all(from(a in Athanor, where: a.id in ^athanors))
  end
end

defmodule Sanctum.NewcomerRemoteInvitationRaceTest do
  @moduledoc """
  A remote admission with an invitation, and a deny of the identifier that
  commits on another connection after the admission's check of the door
  and before its transaction writes the allow: the admission rolls back
  whole, making no person, with the invitation unspent and no seat in its
  thread.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{
    Athanor,
    DirectoryHead,
    ExternalIdentity,
    Invitation,
    PersonIdentity,
    SharedThread,
    SharedThreadMember,
    User
  }

  alias Arca.Schemas.ServerAllowlistEntry, as: Entry
  alias Ecto.Adapters.SQL.Sandbox
  alias Sanctum.Door.Store
  alias Sanctum.Newcomer
  alias Sanctum.Test.DirectoryServer

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  setup_all do
    %{tls: DirectoryServer.tls()}
  end

  setup %{tls: tls} do
    DirectoryServer.listen!()
    DirectoryServer.seam!(tls)
    directory = DirectoryServer.start!(tls)
    identity = DirectoryServer.identity!(directory.dir, directory.url)
    key = "github|https://github.com|remote-race-#{System.unique_integer([:positive])}"
    remote_key = Sanctum.Auth.Identity.cyfr_key(identity.url, identity.identifier)
    on_exit(fn -> unboxed(fn -> cleanup!([key, remote_key], identity.identifier) end) end)

    unboxed(fn ->
      DirectoryServer.cached!(identity)
      {:ok, issuer} = Sanctum.Test.People.linked(%{id: key, provider: "github"})
      {:ok, thread} = Sanctum.SharedThreads.create(issuer.id, "Remote race #{issuer.id}")
      ctx = Sanctum.Context.build(user_id: issuer.id)
      {:ok, %{invitation: invitation, code: code}} = Sanctum.Invitations.create(ctx, thread.id)
      {:ok, hash} = Sanctum.Invitations.code_hash(code)

      remote = %{
        identifier: identity.identifier,
        directory_url: identity.url,
        genesis_hash: Prima.Identity.hash(identity.genesis),
        head_hash: DirectoryServer.key_epoch(identity),
        invitation: hash
      }

      {:ok, remote: remote, remote_key: remote_key, thread: thread, invitation: invitation}
    end)
  end

  # Pauses the admitting process once its check of the door has read the
  # identifier's row: before its transaction opens.
  defp pause_after_check! do
    test = self()
    handler = "remote-race-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if Process.get(:admitting) and metadata[:source] == "server_allowlist" and
               String.starts_with?(metadata[:query] || "", "SELECT") do
            Process.delete(:admitting)
            send(test, {:checked, Arca.in_transaction?()})

            receive do
              :go -> :ok
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "a deny committed between the check and the allow rolls the admission back", %{
    remote: remote,
    remote_key: remote_key,
    thread: thread,
    invitation: invitation
  } do
    pause_after_check!()

    admitting =
      Task.async(fn ->
        unboxed(fn ->
          Process.put(:admitting, true)
          Newcomer.admit({:remote, remote}, :none)
        end)
      end)

    assert_receive {:checked, false}, 10_000
    {:ok, _deny} = unboxed(fn -> Store.deny("identifier", remote.identifier, "ops") end)
    send(admitting.pid, :go)

    assert {:error, {:door, :denied}} = Task.await(admitting, 25_000)

    assert unboxed(fn ->
             %{
               people:
                 Arca.Repo.aggregate(
                   from(i in ExternalIdentity, where: i.key == ^remote_key),
                   :count
                 ),
               identities:
                 Arca.Repo.aggregate(
                   from(p in PersonIdentity, where: p.identifier == ^remote.identifier),
                   :count
                 ),
               redeemed_by: Arca.Repo.get!(Invitation, invitation.id).redeemed_by,
               seats:
                 Arca.Repo.aggregate(
                   from(m in SharedThreadMember, where: m.thread_id == ^thread.id),
                   :count
                 ),
               door:
                 Arca.Repo.all(
                   from(e in Entry, where: e.value == ^remote.identifier, select: e.effect)
                 )
             }
           end) == %{people: 0, identities: 0, redeemed_by: nil, seats: 1, door: ["deny"]}
  end

  defp cleanup!(keys, identifier) do
    people =
      Arca.Repo.all(from(i in ExternalIdentity, where: i.key in ^keys, select: i.user_id))

    athanors =
      Arca.Repo.all(
        from(a in Athanor,
          where: a.owner_user_id in ^people or a.created_by in ^people,
          select: a.id
        )
      )

    Arca.Repo.delete_all(from(e in Entry, where: e.value in ^[identifier | people]))
    Arca.Repo.delete_all(from(h in DirectoryHead, where: h.identifier == ^identifier))
    Arca.Repo.delete_all(from(i in Invitation, where: i.issued_by in ^people))

    threads =
      Arca.Repo.all(from(t in SharedThread, where: t.created_by in ^people, select: t.id))

    Arca.Repo.delete_all(
      from(m in SharedThreadMember, where: m.thread_id in ^threads or m.user_id in ^people)
    )

    Arca.Repo.delete_all(from(t in SharedThread, where: t.id in ^threads))

    Arca.Repo.delete_all(from(p in PersonIdentity, where: p.user_id in ^people))
    Arca.Repo.delete_all(from(i in ExternalIdentity, where: i.user_id in ^people))
    Arca.Repo.delete_all(from(a in Athanor, where: a.id in ^athanors))
    Arca.Repo.delete_all(from(u in User, where: u.id in ^people))
  end
end

defmodule Sanctum.NewcomerTest.FillWatch do
  @moduledoc """
  A component-facts port that fills nothing and tells the process that
  asked for a fill which athanor it asked for, and why; every other fact
  answers as `Sanctum.Test.Components` answers it.
  """

  @behaviour Sanctum.Consent.Components

  alias Sanctum.Test.Components

  @impl true
  defdelegate resolve(ctx, component), to: Components
  @impl true
  defdelegate resolve_verified(ctx, component), to: Components
  @impl true
  defdelegate get_component(ctx, name, version, publisher, type), to: Components
  @impl true
  defdelegate agent_rows(ctx), to: Components
  @impl true
  defdelegate shipped_nodes(ctx, rows), to: Components
  @impl true
  defdelegate newer_shipped(ctx, row), to: Components
  @impl true
  defdelegate tincture_placement(ctx, row), to: Components

  @impl true
  def fill(%{id: athanor_id}, _ctx, entry_kind) do
    send(self(), {:fill_asked, athanor_id, entry_kind})
    :ok
  end
end
