# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.NewcomerTest do
  @moduledoc """
  A person is made only by an admission (`Sanctum.Newcomer.admit/2`), and
  a linked sign-in method only unlocks a person who exists
  (`Sanctum.SignIn.unlock/1`).

  Setup makes the installation's first person, their keys, their athanor,
  their credential and the platform grant in one transaction, and answers
  that person again while they hold no sign-in method; from the commit
  that gives them one, the token opens nothing. An open admission needs
  the door's `*` and passes the athanor caps, and a refusal anywhere in
  its transaction leaves no person, no athanor and no passkey. A remote
  newcomer is admitted by the door's verdict on their identifier, with no
  keys and no athanor, and a directory that cannot be read writes no row.
  A killed admission and a member that lost its slot write nothing.
  """

  # The setup token, the slot, the directory seam and the settings are
  # process-wide.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{ExternalIdentity, Membership, Passkey, PersonIdentity, Session, User}
  alias Sanctum.Door.Store
  alias Sanctum.Newcomer
  alias Sanctum.Tenancy.{Athanors, Members}
  alias Sanctum.Test.{DirectoryServer, Settings}
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

  defp setup!(credential \\ {:command_line, "laptop"}) do
    {:ok, admitted} = Newcomer.admit({:setup, @token}, credential)
    admitted
  end

  defp identifier, do: "per_" <> Prima.Digest.sha256_hex("newcomer-#{System.unique_integer()}")

  describe "setup" do
    test "makes the first person with their keys, athanor and passkey, signs them in, and grants the platform role" do
      assert {:ok, %{person: person, readmitted: false, session_token: token}} =
               Newcomer.admit({:setup, @token}, {:passkey, registration()})

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

    test "answers the same person again, with a new command-line session, while they hold no sign-in method" do
      first = setup!()
      assert %{readmitted: false, session_token: token} = first

      assert {:ok, %{person: again, readmitted: true, session_token: second}} =
               Newcomer.admit({:setup, @token}, {:command_line, "laptop"})

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
               Newcomer.admit({:setup, @token}, {:passkey, registration()})

      assert same == first.id

      assert [%Passkey{state: "active"}] =
               Arca.Repo.all(from(p in Passkey, where: p.user_id == ^first.id))

      assert {:error, :setup_closed} = Newcomer.admit({:setup, @token}, {:command_line, "laptop"})

      assert {:error, :setup_closed} =
               Newcomer.admit({:setup, @token}, {:passkey, registration()})

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

      assert {:error, :setup_closed} = Newcomer.admit({:setup, @token}, {:command_line, "laptop"})
      assert length(sessions(first.id)) == 1
    end

    test "opens nothing once the person connects a device, which marks their first method" do
      %{person: first} = setup!()

      # A pairing's completion sets the mark a first passkey sets
      # (`Arca.PairingInvitations`), under the person's lock.
      {:ok, :marked} =
        Arca.Repo.transaction(fn -> Arca.PersonIdentities.first_method!(first.id) end)

      assert {:error, :setup_closed} = Newcomer.admit({:setup, @token}, {:command_line, "laptop"})
    end

    test "a token that is not the configured one, or none configured, opens nothing and writes nothing" do
      assert {:error, :setup_closed} =
               Newcomer.admit({:setup, String.duplicate("0", 64)}, {:command_line, "laptop"})

      assert {:error, :setup_closed} =
               Newcomer.admit({:setup, "short"}, {:command_line, "laptop"})

      Application.delete_env(:sanctum, :setup_token)
      assert {:error, :setup_closed} = Newcomer.admit({:setup, @token}, {:command_line, "laptop"})
      assert people() == 0
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
               Newcomer.admit({:setup, @token}, {:command_line, "laptop"})

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

      assert {:error, :not_owner} = Newcomer.admit({:setup, @token}, {:passkey, registration()})
      assert people() == 0
      assert grants() == 0
      assert passkeys() == 0
    end
  end

  describe "an open admission" do
    test "needs the door's *, and writes nothing and leaves no request without it" do
      %{person: _first} = setup!()

      assert {:error, {:door, :not_allowed}} = Newcomer.admit(:open, {:passkey, registration()})
      assert people() == 1
      assert Store.requests() == []
    end

    test "is not the first person: onto an empty installation it is not set up" do
      {:ok, _} = Store.allow("wildcard", "*", "ops")

      assert {:error, :not_set_up} = Newcomer.admit(:open, {:passkey, registration()})
      assert people() == 0
      assert passkeys() == 0
    end

    test "makes a local person with keys, an athanor and a passkey, and no grant" do
      %{person: _first} = setup!()
      {:ok, _} = Store.allow("wildcard", "*", "ops")

      assert {:ok, %{person: person, readmitted: false, session_token: token}} =
               Newcomer.admit(:open, {:passkey, registration()})

      assert person.admission == "open"
      refute Sanctum.Tenancy.platform_admin?(person.id)
      assert grants() == 1
      assert {:ok, _athanor} = Athanors.get_by_owner(person.id)

      assert %PersonIdentity{provenance: "local"} =
               Arca.Repo.get_by(PersonIdentity, user_id: person.id)

      assert {:ok, %{user_id: _}} = Sanctum.Session.get(token)
    end

    test "at a cap writes nothing: no person, no athanor, no passkey" do
      %{person: _first} = setup!()
      {:ok, _} = Store.allow("wildcard", "*", "ops")
      Settings.put("max_athanors", 1)

      assert {:error, {:limit_reached, :max_athanors, 1}} =
               Newcomer.admit(:open, {:passkey, registration()})

      assert people() == 1
      assert passkeys() == 0
    end

    test "past the mint rate writes nothing" do
      %{person: _first} = setup!()
      {:ok, _} = Store.allow("wildcard", "*", "ops")
      {:ok, %{person: _second}} = Newcomer.admit(:open, {:passkey, registration()})
      Settings.put("mint_per_hour", 1)

      assert {:error, {:limit_reached, :mint_per_hour, 1}} =
               Newcomer.admit(:open, {:passkey, registration()})

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

      {:ok, %{person: _admitted}} = Newcomer.admit(:open, {:passkey, registered.()})

      person_athanors = fn ->
        Arca.Repo.aggregate(from(a in Arca.Schemas.Athanor, where: a.kind == "person"), :count)
      end

      before = {people(), person_athanors.(), Arca.Repo.aggregate(PersonIdentity, :count)}

      # The second verifies; its transaction writes the person, their keys
      # and their athanor, and the credential's write is refused there, so
      # all of it rolls back.
      assert {:error, {:conflict, _}} = Newcomer.admit(:open, {:passkey, registered.()})
      assert {people(), person_athanors.(), Arca.Repo.aggregate(PersonIdentity, :count)} == before
      assert passkeys() == 1
    end

    test "the same registration presented again makes no one" do
      %{person: _first} = setup!()
      {:ok, _} = Store.allow("wildcard", "*", "ops")
      credential = registration()
      {:ok, _} = Newcomer.admit(:open, {:passkey, credential})

      assert {:error, :registration_refused} = Newcomer.admit(:open, {:passkey, credential})
      assert people() == 2
      assert passkeys() == 1
    end

    test "takes a passkey only" do
      %{person: _first} = setup!()
      {:ok, _} = Store.allow("wildcard", "*", "ops")

      for credential <- [{:command_line, "laptop"}, :none] do
        assert {:error, {:invalid_argument, _}} = Newcomer.admit(:open, credential)
      end

      assert {:error, {:invalid_argument, _}} = Newcomer.admit({:setup, @token}, :none)
      assert people() == 1
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

  alias Arca.Schemas.{Membership, PersonIdentity, User}
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

    # The admission is over an empty installation: nothing committed may
    # hold a person when it starts.
    assert 0 == unboxed(fn -> Arca.Repo.aggregate(User, :count) end)
    :ok
  end

  test "an admission killed before its commit leaves no person, no keys and no grant" do
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
          Sanctum.Newcomer.admit({:setup, @token}, {:command_line, "laptop"})
        end)
      end)

    assert_receive {:admitting, ^admitting}, 15_000
    ref = Process.monitor(admitting)
    Process.exit(admitting, :kill)
    assert_receive {:DOWN, ^ref, :process, ^admitting, :killed}, 5_000

    assert {0, 0, 0} ==
             unboxed(fn ->
               {Arca.Repo.aggregate(User, :count), Arca.Repo.aggregate(PersonIdentity, :count),
                Arca.Repo.aggregate(from(m in Membership, where: m.scope == "platform"), :count)}
             end)
  end
end
