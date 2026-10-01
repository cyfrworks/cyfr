# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SessionStorageTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.SessionStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
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
        Arca.Users.mint(
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

    test "every session carrying a retired key_epoch ends, and only those" do
      old = Prima.Digest.sha256("old-#{System.unique_integer()}")
      new = Prima.Digest.sha256("new-#{System.unique_integer()}")
      person = remote_person!(old)
      issuance = Arca.Test.Actor.issuance(person.id)
      retired = make_token_hash("old")
      current = make_token_hash("new")

      :ok =
        SessionStorage.create_session(
          retired,
          session_attrs(%{user_id: person.id, identity_key_epoch: old}),
          issuance
        )

      # The cached head moves to `new` by hand, without an advance's own
      # retirement: what ends the old session below is revoke_key_epoch/3.
      {1, _} =
        Arca.Repo.update_all(
          from(h in Arca.Schemas.DirectoryHead, where: h.head_hash == ^old),
          set: [head_hash: new, key_epoch: new]
        )

      :ok =
        SessionStorage.create_session(
          current,
          session_attrs(%{user_id: person.id, identity_key_epoch: new}),
          issuance
        )

      assert {:error, :cross_tenant} =
               SessionStorage.revoke_key_epoch(
                 Prima.Actor.in_athanor("ath_test"),
                 [person.id],
                 old
               )

      assert {:ok, [^retired]} =
               SessionStorage.revoke_key_epoch(Prima.Actor.system(), [person.id], old)

      assert {:error, :not_found} = SessionStorage.get_session(retired)
      assert {:ok, _} = SessionStorage.get_session(current)
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
