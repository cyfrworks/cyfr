# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SessionStorageTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.SessionStorage

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp make_token_hash(suffix) do
    :crypto.hash(:sha256, "test_token_#{suffix}_#{:rand.uniform(100_000)}")
  end

  defp session_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        user_id: "user_1",
        email: "user@example.com",
        provider: "github",
        permissions: "[\"execute\",\"component:read\"]",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        token_prefix: "cyfr_"
      },
      overrides
    )
  end

  describe "create_session/2 and get_session/1" do
    test "stores and retrieves a session" do
      hash = make_token_hash("create")
      attrs = session_attrs()

      assert :ok = SessionStorage.create_session(hash, attrs, Arca.Test.Actor.issuance())

      assert {:ok, session} = SessionStorage.get_session(hash)
      assert session.user_id == "user_1"
      assert session.email == "user@example.com"
      assert session.provider == "github"
    end

    test "returns not_found for missing session" do
      hash = make_token_hash("missing")
      assert {:error, :not_found} = SessionStorage.get_session(hash)
    end

    test "returns not_found for expired session" do
      hash = make_token_hash("expired")
      attrs = session_attrs(%{expires_at: DateTime.add(DateTime.utc_now(), -1, :second)})

      :ok = SessionStorage.create_session(hash, attrs, Arca.Test.Actor.issuance())

      assert {:error, :not_found} = SessionStorage.get_session(hash)
    end
  end

  describe "athanor persistence" do
    test "persists and returns the session's athanor" do
      hash = make_token_hash("athanor")
      attrs = session_attrs(%{athanor_id: "ath_home"})

      assert :ok = SessionStorage.create_session(hash, attrs, Arca.Test.Actor.issuance())
      assert {:ok, session} = SessionStorage.get_session(hash)
      assert session.athanor_id == "ath_home"
    end

    test "update_athanor/2 repoints a live session; delete_by_user/1 drops every session" do
      hash = make_token_hash("repoint")

      :ok =
        SessionStorage.create_session(
          hash,
          session_attrs(%{athanor_id: "ath_a"}),
          Arca.Test.Actor.issuance()
        )

      assert :ok = SessionStorage.update_athanor(hash, "ath_b")
      assert {:ok, %{athanor_id: "ath_b"} = session} = SessionStorage.get_session(hash)

      assert {:error, :not_found} =
               SessionStorage.update_athanor(make_token_hash("none"), "ath_b")

      assert {:ok, n} = SessionStorage.delete_by_user(session.user_id)
      assert n >= 1
      assert {:error, :not_found} = SessionStorage.get_session(hash)
    end
  end

  describe "refresh_session/2" do
    test "updates session expiration" do
      hash = make_token_hash("refresh")
      attrs = session_attrs()
      :ok = SessionStorage.create_session(hash, attrs, Arca.Test.Actor.issuance())

      new_expires = DateTime.add(DateTime.utc_now(), 7200, :second)
      assert :ok = SessionStorage.refresh_session(hash, new_expires)

      # Verify the session still exists after refresh
      assert {:ok, _session} = SessionStorage.get_session(hash)
    end

    test "returns not_found for missing session" do
      hash = make_token_hash("refresh_missing")
      assert {:error, :not_found} = SessionStorage.refresh_session(hash, DateTime.utc_now())
    end
  end

  describe "a protected device's session" do
    defp reserve!(client_id, id \\ Prima.UUID7.generate_id("ses")) do
      :ok =
        SessionStorage.reserve_client_session(id, %{
          client_id: client_id,
          user_id: "user_1",
          expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
        })

      id
    end

    defp activate(client_id, id, expires_in_ms) do
      hash = make_token_hash("client")

      result =
        SessionStorage.activate_client_session(
          hash,
          %{
            id: id,
            client_id: client_id,
            user_id: "user_1",
            token_prefix: "cyfr_",
            expires_at: DateTime.add(DateTime.utc_now(), expires_in_ms, :millisecond)
          },
          Arca.Test.Actor.issuance("user_1")
        )

      {result, hash}
    end

    defp client_session!(client_id, expires_in_ms) do
      id = reserve!(client_id)

      {:ok, hash} = activate(client_id, id, expires_in_ms)

      {hash, id}
    end

    test "is reserved as a row no token loads, which its activation gives a token once" do
      id = reserve!("pcl_one")
      row = Arca.Repo.get!(Arca.Schemas.Session, id)
      assert row.provider == "unlock_reserved" and row.client_id == "pcl_one"
      assert {:error, :not_found} = SessionStorage.get_session(make_token_hash("guess"))

      {:ok, hash} = activate("pcl_one", id, 60_000)

      assert {:ok, %{id: ^id, client_id: "pcl_one", provider: "unlock"}} =
               SessionStorage.get_session(hash)

      assert {{:error, :reservation_retired}, _} = activate("pcl_one", id, 60_000)
    end

    test "a reservation is carried to its ticket's deadline only while it stands" do
      id = reserve!("pcl_hold")
      until = DateTime.add(DateTime.utc_now(), 120, :second)
      assert :ok = SessionStorage.hold_client_reservation("pcl_hold", id, until)
      %{expires_at: held} = Arca.Repo.get!(Arca.Schemas.Session, id)
      assert DateTime.compare(held, DateTime.truncate(until, :microsecond)) == :eq

      assert {:error, :reservation_retired} =
               SessionStorage.hold_client_reservation("pcl_other", id, until)

      {:ok, [_unloadable]} = SessionStorage.delete_client_sessions("pcl_hold", [id])

      assert {:error, :reservation_retired} =
               SessionStorage.hold_client_reservation("pcl_hold", id, until)
    end

    test "a lock, another client or an expired reservation leaves nothing to activate" do
      locked = reserve!("pcl_two")
      assert {:ok, [_unloadable]} = SessionStorage.delete_client_sessions("pcl_two", [locked])
      assert {{:error, :reservation_retired}, _} = activate("pcl_two", locked, 60_000)

      other = reserve!("pcl_two")
      assert {{:error, :reservation_retired}, _} = activate("pcl_three", other, 60_000)

      expired = reserve!("pcl_two")
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      Arca.Repo.update_all(from(s in Arca.Schemas.Session, where: s.id == ^expired),
        set: [expires_at: past]
      )

      assert {{:error, :reservation_retired}, _} = activate("pcl_two", expired, 60_000)
    end

    test "a browser's refresh never moves it" do
      {hash, _id} = client_session!("pcl_four", 60_000)
      {:ok, %{expires_at: before}} = SessionStorage.get_session(hash)
      later = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:error, :not_found} = SessionStorage.refresh_session(hash, later)
      assert {:ok, %{expires_at: ^before}} = SessionStorage.get_session(hash)
    end

    test "its channel slides an active one, never past the cap, never another client's, never an expired one or a reservation" do
      {hash, id} = client_session!("pcl_five", 1_000)
      {expired_hash, expired} = client_session!("pcl_five", -1_000)
      {_other_hash, other} = client_session!("pcl_six", 1_000)
      reserved = reserve!("pcl_five")
      %{expires_at: reserved_until} = Arca.Repo.get!(Arca.Schemas.Session, reserved)
      cap = DateTime.add(DateTime.utc_now(), 30, :second)

      assert {:ok, standing} =
               SessionStorage.slide_client_sessions(
                 "pcl_five",
                 [id, expired, other, reserved],
                 60_000,
                 cap
               )

      assert standing == Enum.sort([id, reserved])
      assert {:ok, %{expires_at: slid}} = SessionStorage.get_session(hash)
      assert DateTime.compare(slid, DateTime.truncate(cap, :microsecond)) == :eq
      assert {:error, :not_found} = SessionStorage.get_session(expired_hash)
      assert %{expires_at: ^reserved_until} = Arca.Repo.get!(Arca.Schemas.Session, reserved)

      far = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert {:ok, [^id]} = SessionStorage.slide_client_sessions("pcl_five", [id], 60_000, far)
      assert {:ok, %{expires_at: bounded}} = SessionStorage.get_session(hash)
      assert DateTime.diff(bounded, DateTime.utc_now(), :second) <= 60
    end

    test "a lock deletes exactly the sessions it names of its own client" do
      {hash, id} = client_session!("pcl_seven", 60_000)
      {kept_hash, kept} = client_session!("pcl_seven", 60_000)
      {other_hash, _other} = client_session!("pcl_eight", 60_000)

      assert {:ok, [^hash]} = SessionStorage.delete_client_sessions("pcl_seven", [id])
      assert {:ok, []} = SessionStorage.delete_client_sessions("pcl_seven", [id])
      assert {:ok, []} = SessionStorage.delete_client_sessions("pcl_eight", [kept])
      assert {:error, :not_found} = SessionStorage.get_session(hash)
      assert {:ok, %{id: ^kept}} = SessionStorage.get_session(kept_hash)
      assert {:ok, _} = SessionStorage.get_session(other_hash)
    end
  end

  describe "delete_session/1" do
    test "deletes a session" do
      hash = make_token_hash("delete")
      :ok = SessionStorage.create_session(hash, session_attrs(), Arca.Test.Actor.issuance())

      assert :ok = SessionStorage.delete_session(hash)
      assert {:error, :not_found} = SessionStorage.get_session(hash)
    end

    test "succeeds for nonexistent session" do
      hash = make_token_hash("delete_missing")
      assert :ok = SessionStorage.delete_session(hash)
    end
  end

  describe "cleanup_expired_sessions/0" do
    test "deletes expired sessions globally and returns count" do
      hash = make_token_hash("cleanup")
      attrs = session_attrs(%{expires_at: DateTime.add(DateTime.utc_now(), -60, :second)})
      :ok = SessionStorage.create_session(hash, attrs, Arca.Test.Actor.issuance())

      {:ok, count} = SessionStorage.cleanup_expired_sessions()
      assert count >= 1
    end
  end

  describe "tenant column" do
    test "stores and retrieves athanor_id" do
      hash = make_token_hash("tenant")
      attrs = session_attrs(%{athanor_id: "ath_alpha"})

      assert :ok = SessionStorage.create_session(hash, attrs, Arca.Test.Actor.issuance())

      assert {:ok, session} = SessionStorage.get_session(hash)
      assert session.athanor_id == "ath_alpha"
    end

    test "a session may exist before its athanor is resolved (nil, never a default)" do
      hash = make_token_hash("tenant_default")
      attrs = session_attrs()

      assert :ok = SessionStorage.create_session(hash, attrs, Arca.Test.Actor.issuance())

      assert {:ok, session} = SessionStorage.get_session(hash)
      assert session.athanor_id == nil
    end
  end

  describe "identity_key_epoch" do
    # Writing a person's identity row is fenced by the member's slot: a
    # claimant runs and this member holds its slot, restored after the case.
    setup do
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
      node = "node-ses-#{System.unique_integer([:positive])}"
      {:ok, _slot} = Arca.ControlPlane.take(node, node <> "#boot", 60_000)
      :ok
    end

    # A remote person, and this home's cached head of their identity at
    # `epoch`: the epoch a session of theirs may bind.
    defp remote_person!(epoch) do
      n = System.unique_integer([:positive])
      now = DateTime.utc_now()
      identifier = "per_" <> Prima.Digest.sha256_hex("remote-#{n}")

      {:ok, _head} =
        Arca.DirectoryHeads.put(Prima.Actor.system(), %{
          identifier: identifier,
          genesis: "genesis-#{n}",
          directory_url: "https://dir.example",
          head_hash: epoch,
          key_epoch: epoch,
          recovery_epoch: epoch,
          state: "{}"
        })

      {:ok, person} =
        Arca.Test.People.mint(
          Prima.Actor.system(),
          %{
            id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
            provider: "cyfr",
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          },
          %{
            key: "cyfr|https://dir.example|#{identifier}",
            provider: "cyfr",
            issuer: "https://dir.example",
            subject: identifier,
            first_seen_at: now,
            last_seen_at: now
          },
          also: fn person ->
            {:ok, _} =
              Arca.PersonIdentities.create(Prima.Actor.system(), %{
                user_id: person.id,
                provenance: "remote",
                identifier: identifier,
                directory_url: "https://dir.example"
              })

            :ok
          end
        )

      person
    end

    test "a remote person's session records the key_epoch it was minted under" do
      epoch = Prima.Digest.sha256("epoch-#{System.unique_integer()}")
      person = remote_person!(epoch)
      hash = make_token_hash("remote")
      issuance = Arca.Test.Actor.issuance(person.id)

      assert {:error, :identity_key_epoch_required} =
               SessionStorage.create_session(hash, session_attrs(%{user_id: person.id}), issuance)

      # An epoch other than the cached head's current one is stale.
      assert {:error, :stale_key_epoch} =
               SessionStorage.create_session(
                 hash,
                 session_attrs(%{
                   user_id: person.id,
                   identity_key_epoch: Prima.Digest.sha256("gone")
                 }),
                 issuance
               )

      assert :ok =
               SessionStorage.create_session(
                 hash,
                 session_attrs(%{user_id: person.id, identity_key_epoch: epoch}),
                 issuance
               )

      assert {:ok, %{identity_key_epoch: ^epoch}} = SessionStorage.get_session(hash)
    end

    test "a local person's session records none" do
      hash = make_token_hash("local")

      assert {:error, :unexpected_key_epoch} =
               SessionStorage.create_session(
                 hash,
                 session_attrs(%{identity_key_epoch: Prima.Digest.sha256("epoch")}),
                 Arca.Test.Actor.issuance()
               )

      assert :ok =
               SessionStorage.create_session(hash, session_attrs(), Arca.Test.Actor.issuance())

      assert {:ok, %{identity_key_epoch: nil}} = SessionStorage.get_session(hash)
    end

    test "the also: closure commits with the session, or the session is not written" do
      hash = make_token_hash("also")

      assert {:error, :receipt_conflict} =
               SessionStorage.create_session(
                 hash,
                 session_attrs(),
                 Arca.Test.Actor.issuance() ++
                   [also: fn _session -> {:error, :receipt_conflict} end]
               )

      assert {:error, :not_found} = SessionStorage.get_session(hash)
      me = self()

      assert :ok =
               SessionStorage.create_session(
                 hash,
                 session_attrs(),
                 Arca.Test.Actor.issuance() ++
                   [
                     also: fn session ->
                       send(me, {:session, session})
                       :ok
                     end
                   ]
               )

      assert_received {:session, %{id: "ses_" <> _, user_id: "user_1"}}
    end

    test "an also: closure answering anything else raises, and the session is not written" do
      hash = make_token_hash("also-other")

      assert_raise ArgumentError, ~r/an also: closure answers/, fn ->
        SessionStorage.create_session(
          hash,
          session_attrs(),
          Arca.Test.Actor.issuance() ++ [also: fn _session -> {:ok, :receipt} end]
        )
      end

      assert {:error, :not_found} = SessionStorage.get_session(hash)
    end
  end
end
