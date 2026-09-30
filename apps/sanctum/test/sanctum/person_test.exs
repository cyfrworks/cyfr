# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PersonTest do
  @moduledoc """
  A person's online keys at home: one key set per person, minted with the
  person and sealed to them by role; device certificates signed by the
  live key, local without an identifier and for another home only with
  one; rotations signed by the operational key and written nowhere; and
  person assertions refused until the CYFR door exists.

  The keys are proved by what they sign and what verifies it, never by
  opening one here.
  """

  # The keyring, the validity setting and the directory setting are
  # process-wide, and some cases change them.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Arca.Schemas.{IdentityAttempt, PersonIdentity}
  alias Prima.Identity
  alias Prima.Identity.Entry
  alias Sanctum.{Cipher, CipherAAD, Person}

  @directory "https://dir.example"
  @athanor "ath_person"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    keyring = Application.get_env(:sanctum, :crypto_keyring)
    directory = Application.get_env(:sanctum, :directory_url)

    on_exit(fn ->
      if keyring,
        do: Application.put_env(:sanctum, :crypto_keyring, keyring),
        else: Application.delete_env(:sanctum, :crypto_keyring)

      if directory,
        do: Application.put_env(:sanctum, :directory_url, directory),
        else: Application.delete_env(:sanctum, :directory_url)
    end)

    {:ok, user: person!()}
  end

  # ---- fixtures ----------------------------------------------------------------

  # A first admitted sign-in's person, with the key set it mints.
  defp person! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: "github|https://github.com|person#{n}",
        provider: "github",
        email: "person#{n}@example.com",
        verified: true
      })

    user
  end

  defp row(user_id), do: Arca.Repo.get_by!(PersonIdentity, user_id: user_id)

  defp as(user_id), do: %Prima.Actor{user_id: user_id}

  defp request_id, do: "req_#{System.unique_integer([:positive])}"

  defp device_key, do: elem(:crypto.generate_key(:eddsa, :ed25519), 0)

  defp local(overrides \\ %{}),
    do: Map.merge(%{subject: :local, audience: Sanctum.origin(), athanor: @athanor}, overrides)

  defp remote, do: %{subject: :identity, audience: "https://hub.example", athanor: @athanor}

  # The person's enrollment opened and accepted: the identifier, the genesis
  # and the head on their row. The genesis names their own public keys.
  defp open_enrollment!(user_id) do
    row = row(user_id)
    {:ok, {recovery, _}} = Identity.derive_recovery_key(:crypto.strong_rand_bytes(32))

    {:ok, genesis} =
      Entry.genesis(
        live_key: row.live_public_key,
        operational_key: row.operational_public_key,
        recovery_keys: [recovery],
        directory: @directory
      )

    {:ok, attempt} =
      Arca.IdentityAttempts.open(as(user_id), %{
        kind: "enrollment",
        request_id: request_id(),
        user_id: user_id,
        identifier: Identity.identifier(genesis),
        directory_url: @directory,
        genesis: Identity.canonical(genesis),
        request_digest: Identity.hash(genesis),
        kit_seed_sealed: "sealed-kit-seed"
      })

    {attempt, genesis}
  end

  defp enroll!(user_id) do
    {attempt, genesis} = open_enrollment!(user_id)
    {:ok, _} = Arca.IdentityAttempts.advance(as(user_id), attempt.id, "staged", "submitted")
    {:ok, _} = Arca.IdentityAttempts.advance(as(user_id), attempt.id, "submitted", "accepted")
    {row(user_id), genesis}
  end

  # The verified state of a person's one-entry log, as a directory holds it
  # before an append: built from the row, since only the person's home
  # holds the key that would sign the genesis.
  defp state(row, genesis) do
    %Identity.State{
      identifier: row.identifier,
      directory: @directory,
      head: row.head_hash,
      key_epoch: row.head_hash,
      live_key: row.live_public_key,
      operational_key: row.operational_public_key,
      recovery_keys: genesis.recovery_keys,
      revision: 0,
      length: 1
    }
  end

  defp attempts(user_id),
    do: Arca.Repo.aggregate(from(a in IdentityAttempt, where: a.user_id == ^user_id), :count)

  defp swap_sealed!(row, set) do
    {1, _} = Arca.Repo.update_all(from(p in PersonIdentity, where: p.id == ^row.id), set: set)
    :ok
  end

  # ---- the key set -------------------------------------------------------------

  describe "the key set a first sign-in mints" do
    test "is two distinct keys on the person's own row, unenrolled", %{user: user} do
      row = row(user.id)

      assert row.provenance == "local"
      assert row.enrollment == "none"
      assert is_nil(row.identifier) and is_nil(row.head_hash)
      assert byte_size(row.live_public_key) == 32
      assert byte_size(row.operational_public_key) == 32
      refute row.live_public_key == row.operational_public_key

      # Each private half is a cipher envelope on the keyring's primary.
      primary = Cipher.primary_label()
      assert {:ok, {4, ^primary}} = Cipher.envelope(row.live_key_sealed)
      assert {:ok, {4, ^primary}} = Cipher.envelope(row.operational_key_sealed)
    end

    test "is sealed to the person and to each key's role", %{user: user} do
      row = row(user.id)
      other = person!()

      # Neither key opens as the other role, as the kit seed, or as another
      # person's: the frame binds the person and the role, never the row.
      for {sealed, role} <- [
            {row.live_key_sealed, :operational},
            {row.live_key_sealed, :kit_seed},
            {row.operational_key_sealed, :live}
          ] do
        assert {:error, {:decrypt, :aad_or_key_mismatch}} =
                 Cipher.decrypt(sealed, CipherAAD.person_key(user.id, role))
      end

      assert {:error, {:decrypt, :aad_or_key_mismatch}} =
               Cipher.decrypt(row.live_key_sealed, CipherAAD.person_key(other.id, :live))

      assert {:error, {:decrypt, :aad_or_key_mismatch}} =
               Cipher.decrypt(
                 row.live_key_sealed,
                 CipherAAD.person_key("restore:" <> user.id, :live)
               )
    end

    test "is one per person: a second key set is refused and the first stands", %{user: user} do
      before = row(user.id)

      assert {:error, :conflict} = Person.mint_keys(%{id: user.id})

      assert row(user.id) == before
    end

    test "that cannot be sealed answers a bare refusal and logs the step alone", %{user: user} do
      # No keyring: sealing raises with the private key in hand. The raise
      # is answered, and the log names the step and the exception's module,
      # never its message or its stacktrace.
      Application.delete_env(:sanctum, :crypto_keyring)

      log =
        capture_log(fn ->
          assert {:error, :unavailable} = Person.mint_keys(%{id: user.id})
        end)

      assert log =~ "[Sanctum.Person] sealing a new live key failed (ArgumentError)"
      refute log =~ "crypto_keyring"
      refute log =~ "stacktrace"
    end
  end

  # ---- device certificates ----------------------------------------------------

  describe "issue_device_cert/4" do
    test "certifies a device locally for an unenrolled person, with no directory at all",
         %{user: user} do
      Application.delete_env(:sanctum, :directory_url)
      assert Sanctum.directory_url() == nil

      key = device_key()
      assert {:ok, cert} = Person.issue_device_cert(user.id, key, "pcl_local", local())

      assert %Prima.DeviceCert{
               device_key: ^key,
               client_id: "pcl_local",
               athanor: @athanor,
               subject: %{kind: :local, user_id: user_id}
             } = cert

      assert user_id == user.id
      assert cert.issuer == Sanctum.origin()
      assert cert.audience == Sanctum.origin()
      # The validity is the `device_cert_seconds` setting's default.
      assert cert.expires_at - cert.not_before == 3_600 * 1_000
      assert_in_delta cert.not_before, System.os_time(:millisecond), 5_000

      # Signed by the person's live key, as the receiving home checks it.
      assert {:ok, _} =
               Prima.DeviceCert.verify(cert, row(user.id).live_public_key,
                 home: Sanctum.origin(),
                 now: cert.not_before,
                 skew: 0
               )

      assert {:error, :bad_signature} =
               Prima.DeviceCert.verify(cert, row(user.id).operational_public_key,
                 home: Sanctum.origin(),
                 now: cert.not_before,
                 skew: 0
               )
    end

    test "names this home by its origin, whatever path, capitals or default port the public URL has",
         %{user: user} do
      public_url = Application.get_env(:sanctum, :public_url)

      on_exit(fn ->
        if public_url,
          do: Application.put_env(:sanctum, :public_url, public_url),
          else: Application.delete_env(:sanctum, :public_url)
      end)

      Application.put_env(:sanctum, :public_url, "https://Home.Example:443/cyfr/")
      assert Person.home() == "https://home.example"

      assert {:ok, cert} =
               Person.issue_device_cert(
                 user.id,
                 device_key(),
                 "pcl_home",
                 local(%{audience: "https://home.example"})
               )

      assert cert.issuer == "https://home.example"

      # The spelling the operator wrote is not this home's name.
      assert {:error, :wrong_audience} =
               Person.issue_device_cert(
                 user.id,
                 device_key(),
                 "pcl_home",
                 local(%{audience: "https://Home.Example:443/cyfr"})
               )

      Application.put_env(:sanctum, :public_url, "https://home.example:8443")
      assert Person.home() == "https://home.example:8443"
    end

    test "lasts the device_cert_seconds setting", %{user: user} do
      Sanctum.Test.Settings.put("device_cert_seconds", 120)

      assert {:ok, cert} = Person.issue_device_cert(user.id, device_key(), "pcl_short", local())
      assert cert.expires_at - cert.not_before == 120_000
    end

    test "refuses a local subject for another home", %{user: user} do
      assert {:error, :wrong_audience} =
               Person.issue_device_cert(
                 user.id,
                 device_key(),
                 "pcl_away",
                 local(%{audience: "https://hub.example"})
               )
    end

    test "refuses an identity subject to a person with no identifier", %{user: user} do
      assert {:error, :not_enrolled} =
               Person.issue_device_cert(user.id, device_key(), "pcl_remote", remote())

      # An enrollment still pending gives no identifier either.
      open_enrollment!(user.id)

      assert {:error, :not_enrolled} =
               Person.issue_device_cert(user.id, device_key(), "pcl_remote", remote())
    end

    test "certifies an enrolled person for another home under their current key_epoch",
         %{user: user} do
      {row, _genesis} = enroll!(user.id)

      assert {:ok, cert} = Person.issue_device_cert(user.id, device_key(), "pcl_remote", remote())

      assert cert.subject == %{
               kind: :identity,
               identifier: row.identifier,
               key_epoch: row.head_hash
             }

      assert cert.issuer == Sanctum.origin()
      assert cert.audience == "https://hub.example"

      assert {:ok, _} =
               Prima.DeviceCert.verify(cert, row.live_public_key,
                 home: "https://hub.example",
                 now: cert.not_before,
                 skew: 0,
                 key_epoch: row.head_hash
               )
    end

    test "refuses a person with no local key set", %{user: user} do
      # A person minted with no key set, and a remote person, whose keys
      # are held at their own home.
      n = System.unique_integer([:positive])
      now = DateTime.utc_now()

      {:ok, keyless} =
        Arca.Users.mint(
          Prima.Actor.system(),
          %{
            id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
            provider: "github",
            email: "keyless#{n}@example.com",
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          },
          %{
            key: "github|https://github.com|keyless#{n}",
            provider: "github",
            issuer: "https://github.com",
            subject: "keyless#{n}",
            first_seen_at: now,
            last_seen_at: now
          }
        )

      {:ok, remote} =
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
            key: "cyfr|https://home.example|remote#{n}",
            provider: "cyfr",
            issuer: "https://home.example",
            subject: "remote#{n}",
            first_seen_at: now,
            last_seen_at: now
          },
          also: fn person ->
            with {:ok, _} <-
                   Arca.PersonIdentities.create(Prima.Actor.system(), %{
                     user_id: person.id,
                     provenance: "remote",
                     identifier: "per_" <> Prima.Digest.sha256_hex("remote#{n}"),
                     directory_url: @directory
                   }),
                 do: :ok
          end
        )

      for person <- [keyless, remote] do
        assert {:error, :not_found} =
                 Person.issue_device_cert(person.id, device_key(), "pcl_none", local())

        assert {:error, :not_found} = Person.sign_rotate(person.id, Prima.Digest.sha256("head"))
      end

      assert {:error, :not_found} =
               Person.issue_device_cert("usr_ghost", device_key(), "pcl_none", local())

      # The person with keys is untouched by any of it.
      assert {:ok, _} = Person.issue_device_cert(user.id, device_key(), "pcl_kept", local())
    end

    test "answers :unavailable, not :not_found, when the live key cannot be opened",
         %{user: user} do
      row = row(user.id)

      # A live column holding the operational key's ciphertext opens as
      # neither: the column's role is in its AAD.
      swap_sealed!(row, live_key_sealed: row.operational_key_sealed)

      capture_log(fn ->
        assert {:error, :unavailable} =
                 Person.issue_device_cert(user.id, device_key(), "pcl_swapped", local())
      end)

      # A keyring that no longer holds the key it was sealed under.
      swap_sealed!(row, live_key_sealed: row.live_key_sealed)

      Application.put_env(:sanctum, :crypto_keyring, %{
        primary: "other",
        keys: %{"other" => :crypto.strong_rand_bytes(32)}
      })

      capture_log(fn ->
        assert {:error, :unavailable} =
                 Person.issue_device_cert(user.id, device_key(), "pcl_lost", local())
      end)

      # No keyring at all: the raise is answered, and the key is not in it.
      Application.delete_env(:sanctum, :crypto_keyring)

      log =
        capture_log(fn ->
          assert {:error, :unavailable} =
                   Person.issue_device_cert(user.id, device_key(), "pcl_none", local())
        end)

      assert log =~ "opening the live key failed (ArgumentError)"
    end

    test "refuses a malformed request as the certificate's shape does", %{user: user} do
      assert {:error, {:invalid_field, "device_key"}} =
               Person.issue_device_cert(user.id, "short", "pcl_bad", local())

      assert {:error, {:invalid_field, "client_id"}} =
               Person.issue_device_cert(user.id, device_key(), "not an id", local())

      assert {:error, {:invalid_field, "athanor"}} =
               Person.issue_device_cert(user.id, device_key(), "pcl_bad", local(%{athanor: ""}))

      enroll!(user.id)

      assert {:error, {:invalid_field, "audience"}} =
               Person.issue_device_cert(user.id, device_key(), "pcl_bad", %{
                 remote()
                 | audience: "hub.example"
               })
    end
  end

  # ---- rotation ----------------------------------------------------------------

  describe "sign_rotate/2" do
    test "stages a new live key and a rotate entry signed by the operational key, writing nothing",
         %{user: user} do
      {row, genesis} = enroll!(user.id)
      head = row.head_hash

      assert {:ok, staged} = Person.sign_rotate(user.id, head)

      assert %{
               entry: bytes,
               entry_hash: hash,
               staged_live_public_key: new_key,
               staged_live_key_sealed: sealed
             } = staged

      assert {:ok, %Entry{kind: :rotate, prev: ^head, live_key: ^new_key} = entry} =
               bytes |> Jason.decode!() |> Entry.decode()

      # The bytes are the entry's JCS form and the hash is over them: what
      # a directory appends and the attempt's request digest.
      assert bytes == Identity.canonical(entry)
      assert hash == Identity.hash(entry)
      assert hash == Prima.Digest.sha256(bytes)

      # Signed by the operational key and by no other: the directory's check
      # of the chain accepts it after the genesis.
      assert :ok = Identity.verify(entry, row.operational_public_key)
      assert {:error, :wrong_signer} = Identity.verify(entry, row.live_public_key)
      assert {:ok, next} = Identity.extend(state(row, genesis), entry)
      assert next.live_key == new_key and next.key_epoch == hash

      # The new key is a new live key, sealed to the person as one.
      refute new_key in [row.live_public_key, row.operational_public_key]
      assert {:ok, {4, _label}} = Cipher.envelope(sealed)

      assert {:error, {:decrypt, :aad_or_key_mismatch}} =
               Cipher.decrypt(sealed, CipherAAD.person_key(user.id, :operational))

      # Nothing was written: the row still names its keys and its head, and
      # no attempt was opened.
      assert row(user.id) == row
      assert attempts(user.id) == 1
    end

    test "makes a new key each call, and its answer is what a rotation attempt opens with",
         %{user: user} do
      {row, _genesis} = enroll!(user.id)

      {:ok, first} = Person.sign_rotate(user.id, row.head_hash)
      {:ok, second} = Person.sign_rotate(user.id, row.head_hash)
      refute first.staged_live_public_key == second.staged_live_public_key
      refute first.entry_hash == second.entry_hash

      assert {:ok, attempt} =
               Arca.IdentityAttempts.open(
                 as(user.id),
                 Map.merge(first, %{
                   kind: "rotation",
                   request_id: request_id(),
                   user_id: user.id,
                   expected_head: row.head_hash
                 })
               )

      assert attempt.request_digest == first.entry_hash

      # Activated, the staged key is the person's live key: it signs.
      for {from, to} <- [
            {"staged", "submitted"},
            {"submitted", "accepted"},
            {"accepted", "keys_active"}
          ] do
        {:ok, _} = Arca.IdentityAttempts.advance(as(user.id), attempt.id, from, to)
      end

      assert {:ok, cert} = Person.issue_device_cert(user.id, device_key(), "pcl_next", remote())
      assert cert.subject.key_epoch == first.entry_hash

      assert {:ok, _} =
               Prima.DeviceCert.verify(cert, first.staged_live_public_key,
                 home: "https://hub.example",
                 now: cert.not_before,
                 skew: 0,
                 key_epoch: first.entry_hash
               )
    end

    test "refuses a person with no identifier: there is no log to extend", %{user: user} do
      assert {:error, :not_enrolled} = Person.sign_rotate(user.id, Prima.Digest.sha256("head"))

      open_enrollment!(user.id)
      assert {:error, :not_enrolled} = Person.sign_rotate(user.id, Prima.Digest.sha256("head"))
    end

    test "refuses a rotate signed with the live key, before anything is written",
         %{user: user} do
      {row, genesis} = enroll!(user.id)

      # The directory refuses a rotate the operational key did not sign.
      {forger, forger_private} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, unsigned} = Entry.rotate(row.head_hash, forger)
      forged = Identity.sign(unsigned, forger_private)
      assert {:error, :wrong_signer} = Identity.extend(state(row, genesis), forged)

      # Here the live key never signs as the operational key: its sealed
      # half moved into the operational column does not open there, since
      # the AAD binds the role.
      swap_sealed!(row, operational_key_sealed: row.live_key_sealed)

      capture_log(fn ->
        assert {:error, :unavailable} = Person.sign_rotate(user.id, row.head_hash)
      end)

      # Nor does the live key re-sealed as the operational role: it opens,
      # but its public half is not the row's operational key, so nothing
      # is signed.
      {:ok, live} = Cipher.decrypt(row.live_key_sealed, CipherAAD.person_key(user.id, :live))
      {:ok, resealed} = Cipher.encrypt(live, CipherAAD.person_key(user.id, :operational))
      swap_sealed!(row, operational_key_sealed: resealed)

      log =
        capture_log(fn ->
          assert {:error, :unavailable} = Person.sign_rotate(user.id, row.head_hash)
        end)

      assert log =~ "the operational key of #{user.id} does not open"

      # No attempt was opened and the row names the keys it named.
      assert attempts(user.id) == 1
      after_row = row(user.id)
      assert after_row.live_public_key == row.live_public_key
      assert after_row.head_hash == row.head_hash
    end

    test "refuses a malformed head as the entry's shape does", %{user: user} do
      enroll!(user.id)
      assert {:error, {:invalid_field, "prev"}} = Person.sign_rotate(user.id, "not-a-digest")
    end
  end

  # ---- assertions --------------------------------------------------------------

  describe "sign_assertion/3" do
    setup %{user: user} do
      ctx = %{Sanctum.TestContext.local() | user_id: user.id}

      request = %{
        audience: "https://hub.example",
        challenge: :crypto.strong_rand_bytes(32),
        action_id: "act_1"
      }

      {:ok, ctx: ctx, request: request}
    end

    test "refuses a person with no identifier", %{ctx: ctx, request: request} do
      assert {:error, :not_enrolled} = Person.sign_assertion(ctx, request, [])

      assert {:error, :not_enrolled} =
               Person.sign_assertion(%{ctx | user_id: "usr_ghost"}, request, [])
    end

    test "signs nothing yet for an enrolled person", %{ctx: ctx, request: request, user: user} do
      enroll!(user.id)
      assert {:error, :not_built} = Person.sign_assertion(ctx, request, [])
    end
  end
end
