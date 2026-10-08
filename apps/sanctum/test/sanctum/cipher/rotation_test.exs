# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Cipher.RotationTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Sanctum.Cipher
  alias Sanctum.Cipher.Rotation

  @k0 :crypto.strong_rand_bytes(32)
  @k1 :crypto.strong_rand_bytes(32)
  @k2 :crypto.strong_rand_bytes(32)

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    orig_kr = Application.get_env(:sanctum, :crypto_keyring)

    put_keyring(%{primary: "k1", keys: %{"k1" => @k1}})

    on_exit(fn ->
      restore(:crypto_keyring, orig_kr)
    end)

    :ok
  end

  defp put_keyring(kr), do: Application.put_env(:sanctum, :crypto_keyring, kr)

  # The keyring is the identity domain's key, which is where
  # `put_keyring/1` sets it: restoring it under the host's application
  # would leave this suite's test keyring live for every test after.
  defp restore(k, nil), do: Application.delete_env(:sanctum, k)
  defp restore(k, v), do: Application.put_env(:sanctum, k, v)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp uuid, do: Ecto.UUID.generate()

  # Insert rows whose ciphertext is produced with the SAME AAD the rotation
  # tool will rebuild from the row's columns (the contract under test).
  @athanor "ath_a"

  defp put_webhook_row(name, secret, prev, over \\ %{}) do
    aad = Sanctum.CipherAAD.webhook_secret(@athanor, name)

    sec =
      case Map.get(over, :secret_encrypted, :seal) do
        :seal -> elem(Cipher.encrypt(secret, aad), 1)
        other -> other
      end

    prev_ct = if prev, do: elem(Cipher.encrypt(prev, aad), 1)
    id = uuid()

    Arca.Repo.insert_all(Arca.Schemas.Webhook, [
      %{
        id: id,
        name: name,
        slug: "wh_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
        target_ref: "catalyst:local.x:1.0.0",
        secret_encrypted: sec,
        previous_secret_encrypted: prev_ct,
        signature_header: "x-cyfr-signature",
        input_template: "{}",
        enabled: true,
        profile_id: "prof_test",
        athanor_id: @athanor,
        inserted_at: now(),
        updated_at: now()
      }
    ])

    id
  end

  defp put_vault_row(name, plaintext, over \\ %{}) do
    id = Map.get(over, :id, "vlt_" <> uuid())
    hint = Map.get(over, :provider_hint, "legacy")
    aad = Sanctum.CipherAAD.vault_entry(@athanor, id, hint)

    sealed =
      case Map.get(over, :sealed_payload, :seal) do
        :seal -> elem(Cipher.encrypt(plaintext, aad), 1)
        other -> other
      end

    Arca.Repo.insert_all(Arca.Schemas.VaultEntry, [
      %{
        id: id,
        athanor_id: @athanor,
        name: name,
        provider_hint: hint,
        kind: "bundle",
        destination: ~s({"hosts":["api.example.com"],"scheme":"https"}),
        status: Map.get(over, :status, "active"),
        payload_rev: 0,
        sealed_payload: sealed,
        inserted_at: now(),
        updated_at: now()
      }
    ])

    id
  end

  # An instance entry sealed as `Sanctum.InstanceEntries` seals one: under
  # its id and provider hint, with no athanor.
  defp put_instance_row(name, plaintext, over \\ %{}) do
    id = Map.get(over, :id, "ine_" <> uuid())
    hint = Map.get(over, :provider_hint, "openai.com")
    {:ok, sealed} = Cipher.encrypt(plaintext, Sanctum.CipherAAD.instance_entry(id, hint))

    Arca.Repo.insert_all(Arca.Schemas.InstanceEntry, [
      %{
        id: id,
        name: name,
        provider_hint: hint,
        kind: "api_key",
        destination:
          ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"}),
        audience: "everyone",
        component_policy: "any",
        created_by: "usr_admin",
        status: "active",
        payload_rev: 0,
        sealed_payload: sealed,
        inserted_at: now(),
        updated_at: now()
      }
    ])

    id
  end

  defp put_provider_credential_row(provider, plaintext) do
    aad = Sanctum.CipherAAD.provider_credential(@athanor, provider)
    {:ok, ct} = Cipher.encrypt(plaintext, aad)

    :ok =
      Arca.ProviderCredentialStorage.put(%{
        athanor_id: @athanor,
        provider: provider,
        payload_ciphertext: ct,
        created_by: "user_1"
      })

    {:ok, row} = Arca.ProviderCredentialStorage.get(Prima.Actor.in_athanor(@athanor), provider)
    row.id
  end

  # Seals a v3 envelope as the pre-athanor writer did (production has no v3
  # writer and no v3 read path left; legacy rows are fabricated here).
  defp seal_v3(plaintext, %{purpose: purpose, name: name}, label, master) do
    info = "cyfr-cipher-v1|" <> Atom.to_string(purpose)
    # Mirrors Sanctum.Cipher's fixed iteration count (no knob may change it).
    key = :crypto.pbkdf2_hmac(:sha256, master, info, 100_000, 32)
    iv = :crypto.strong_rand_bytes(12)

    fields =
      for v <- ["project", "org_a", "default", name, "", ""] do
        <<byte_size(v)::32, v::binary>>
      end

    aad =
      IO.iodata_to_binary([
        "cyfrv3",
        <<0x03>>,
        <<byte_size(label)::32, label::binary>>,
        <<byte_size(Atom.to_string(purpose))::32, Atom.to_string(purpose)::binary>>
        | fields
      ])

    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, 16, true)
    <<0x03, byte_size(label)::8, label::binary, iv::binary, tag::binary, ct::binary>>
  end

  defp col(table, id, field) do
    Arca.Repo.one(from(r in table, where: r.id == ^id, select: field(r, ^field)))
  end

  # ---- a person's keys ---------------------------------------------------------

  @directory "https://dir.example"

  # A first sign-in: the person and their key set, sealed under the
  # keyring's primary as it stands.
  defp person! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: "github|https://github.com|rotation#{n}",
        provider: "github",
        email: "rotation#{n}@example.com",
        verified: true
      })

    user
  end

  defp identity_row(user_id), do: Arca.Repo.get_by!(Arca.Schemas.PersonIdentity, user_id: user_id)

  defp as(user_id), do: %Prima.Actor{user_id: user_id}

  defp request_id, do: "req_#{System.unique_integer([:positive])}"

  # An accepted enrollment: the identifier on the person's row, and the kit
  # seed sealed to them until the kit is acknowledged.
  defp enroll!(user_id, seed) do
    row = identity_row(user_id)
    {:ok, {recovery, _}} = Prima.Identity.derive_recovery_key(seed)

    {:ok, genesis} =
      Prima.Identity.Entry.genesis(
        live_key: row.live_public_key,
        operational_key: row.operational_public_key,
        recovery_keys: [recovery],
        directory: @directory
      )

    {:ok, sealed_seed} = Cipher.encrypt(seed, Sanctum.CipherAAD.person_key(user_id, :kit_seed))

    {:ok, attempt} =
      Arca.IdentityAttempts.open(as(user_id), %{
        kind: "enrollment",
        request_id: request_id(),
        user_id: user_id,
        identifier: Prima.Identity.identifier(genesis),
        directory_url: @directory,
        genesis: Prima.Identity.canonical(genesis),
        request_digest: Prima.Identity.hash(genesis),
        kit_seed_sealed: sealed_seed
      })

    {:ok, _} = Arca.IdentityAttempts.advance(as(user_id), attempt.id, "staged", "submitted")

    {:ok, accepted} =
      Arca.IdentityAttempts.advance(as(user_id), attempt.id, "submitted", "accepted")

    accepted
  end

  # A restore's attempt past its mint, naming the person it minted, with
  # its staged keys sealed under `frame`: the restore's own unless a case
  # says otherwise.
  defp put_restore_row!(user_id, keys, frame \\ nil) do
    id = Prima.UUID7.generate_id("iat")
    rid = request_id()
    frame = frame || "restore:" <> rid

    {:ok, live} = Cipher.encrypt(keys.live, Sanctum.CipherAAD.person_key(frame, :live))

    {:ok, operational} =
      Cipher.encrypt(keys.operational, Sanctum.CipherAAD.person_key(frame, :operational))

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.IdentityAttempt, [
        %{
          id: id,
          kind: "restore",
          request_id: rid,
          phase: "minted",
          user_id: user_id,
          identifier: "per_" <> Prima.Digest.sha256_hex(rid),
          directory_url: @directory,
          entry: "recover-request",
          request_digest: Prima.Digest.sha256(rid),
          expected_revision: 0,
          token_digest: Prima.Digest.sha256("token-" <> rid),
          staged_live_public_key: :crypto.strong_rand_bytes(32),
          staged_operational_public_key: :crypto.strong_rand_bytes(32),
          staged_live_key_sealed: live,
          staged_operational_key_sealed: operational,
          revision: 1,
          inserted_at: now(),
          updated_at: now()
        }
      ])

    %{id: id, frame: frame}
  end

  defp person_key(frame, role), do: Sanctum.CipherAAD.person_key(frame, role)

  describe "T-REENCRYPT: happy path + idempotency" do
    test "migrates every table onto the new primary; plaintext preserved" do
      w = put_webhook_row("hook1", "whsec_aaa", "whsec_old")
      v = put_vault_row("legacy:probe", ~s({"v":2,"fields":{}}))

      rt_aad = Sanctum.CipherAAD.registry_token("user_1", "registry.test", "alice")
      {:ok, rt_ct} = Cipher.encrypt(~s({"token":"cyfr_pt_x"}), rt_aad)

      :ok =
        Arca.RegistryTokenStorage.put(%{
          user_id: "user_1",
          registry: "registry.test",
          namespace_slug: "alice",
          credential_ciphertext: rt_ct
        })

      {:ok, rt_row} = Arca.RegistryTokenStorage.get("user_1", "registry.test", "alice")

      pc = put_provider_credential_row("google", ~s({"client_id":"cid","client_secret":"cs"}))

      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})

      assert {:ok, summary} = Rotation.reencrypt_all()
      assert summary.webhooks == %{scanned: 1, rotated: 1, skipped: 0}
      assert summary.vault_entries == %{scanned: 1, rotated: 1, skipped: 0}
      assert summary.registry_tokens == %{scanned: 1, rotated: 1, skipped: 0}
      assert summary.oauth_provider_credentials == %{scanned: 1, rotated: 1, skipped: 0}
      refute summary.dry_run

      # Every column is now on k2 and still decrypts to the original plaintext.
      assert {:ok, "k2"} = Cipher.label(col("webhooks", w, :secret_encrypted))
      assert {:ok, "k2"} = Cipher.label(col("webhooks", w, :previous_secret_encrypted))

      wh_aad = Sanctum.CipherAAD.webhook_secret(@athanor, "hook1")

      assert {:ok, "whsec_aaa"} = Cipher.decrypt(col("webhooks", w, :secret_encrypted), wh_aad)

      assert {:ok, "whsec_old"} =
               Cipher.decrypt(col("webhooks", w, :previous_secret_encrypted), wh_aad)

      assert {:ok, "k2"} = Cipher.label(col("vault_entries", v, :sealed_payload))

      vault_aad = Sanctum.CipherAAD.vault_entry(@athanor, v, "legacy")

      assert {:ok, ~s({"v":2,"fields":{}})} =
               Cipher.decrypt(col("vault_entries", v, :sealed_payload), vault_aad)

      assert {:ok, "k2"} = Cipher.label(col("registry_tokens", rt_row.id, :credential_ciphertext))

      assert {:ok, ~s({"token":"cyfr_pt_x"})} =
               Cipher.decrypt(col("registry_tokens", rt_row.id, :credential_ciphertext), rt_aad)

      assert {:ok, "k2"} =
               Cipher.label(col("oauth_provider_credentials", pc, :payload_ciphertext))

      pc_aad = Sanctum.CipherAAD.provider_credential(@athanor, "google")

      assert {:ok, ~s({"client_id":"cid","client_secret":"cs"})} =
               Cipher.decrypt(col("oauth_provider_credentials", pc, :payload_ciphertext), pc_aad)
    end

    test "re-running is a no-op (idempotent / resumable)" do
      put_vault_row("legacy:s", "v")
      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})

      assert {:ok, %{vault_entries: %{rotated: 1, skipped: 0}}} = Rotation.reencrypt_all()

      assert {:ok, %{vault_entries: %{scanned: 1, rotated: 0, skipped: 1}}} =
               Rotation.reencrypt_all()
    end

    test "rows already on the primary are skipped, byte-unchanged" do
      v = put_vault_row("legacy:s", "v")
      before = col("vault_entries", v, :sealed_payload)

      # primary is still k1 (what the row was written under)
      assert {:ok, %{vault_entries: %{scanned: 1, rotated: 0, skipped: 1}}} =
               Rotation.reencrypt_all()

      assert col("vault_entries", v, :sealed_payload) == before
    end
  end

  describe "T-REENCRYPT: dry-run" do
    test "reports work but writes nothing" do
      v = put_vault_row("legacy:s", "v")
      before = col("vault_entries", v, :sealed_payload)
      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})

      assert {:ok, %{vault_entries: %{scanned: 1, rotated: 1, skipped: 0}, dry_run: true}} =
               Rotation.reencrypt_all(dry_run: true)

      assert col("vault_entries", v, :sealed_payload) == before
      assert {:ok, "k1"} = Cipher.label(col("vault_entries", v, :sealed_payload))
    end
  end

  describe "T-REENCRYPT: an interrupted run" do
    test "leaves every row whole, and resuming finishes it" do
      # Three rows in a known id order. The middle one is sealed under a
      # key the rotation will not be given, so the run aborts on it: the
      # first row is already re-sealed, the third has not been touched.
      a = put_vault_row("legacy:a", "plain-a", %{id: "vlt_aaa"})

      put_keyring(%{primary: "k0", keys: %{"k0" => @k0}})
      b = put_vault_row("legacy:b", "plain-b", %{id: "vlt_bbb"})

      put_keyring(%{primary: "k1", keys: %{"k1" => @k1}})
      c = put_vault_row("legacy:c", "plain-c", %{id: "vlt_ccc"})

      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})

      assert {:error,
              {:vault_entries,
               {:decrypt_failed, :sealed_payload, {:decrypt, {:unknown_key_label, "k0"}}}, ^b}} =
               Rotation.reencrypt_all(batch_size: 1)

      # Row by row, never half a row: `a` is wholly on the new key and `c`
      # is wholly on the old one. Neither is a mixture.
      assert {:ok, "k2"} = Cipher.label(col("vault_entries", a, :sealed_payload))

      assert {:ok, "plain-a"} =
               Cipher.decrypt(
                 col("vault_entries", a, :sealed_payload),
                 Sanctum.CipherAAD.vault_entry(@athanor, a, "legacy")
               )

      assert {:ok, "k1"} = Cipher.label(col("vault_entries", c, :sealed_payload))

      assert {:ok, "plain-c"} =
               Cipher.decrypt(
                 col("vault_entries", c, :sealed_payload),
                 Sanctum.CipherAAD.vault_entry(@athanor, c, "legacy")
               )

      # Give the run the key it was missing and rerun: `a` is already on
      # the primary and is skipped, the other two finish.
      put_keyring(%{primary: "k2", keys: %{"k0" => @k0, "k1" => @k1, "k2" => @k2}})

      assert {:ok, %{vault_entries: %{scanned: 3, rotated: 2, skipped: 1}}} =
               Rotation.reencrypt_all(batch_size: 1)

      for {id, plain} <- [{a, "plain-a"}, {b, "plain-b"}, {c, "plain-c"}] do
        ct = col("vault_entries", id, :sealed_payload)
        assert {:ok, {4, "k2"}} = Cipher.envelope(ct)

        assert {:ok, ^plain} =
                 Cipher.decrypt(ct, Sanctum.CipherAAD.vault_entry(@athanor, id, "legacy"))
      end
    end
  end

  describe "T-REENCRYPT: the compare-and-set" do
    test "a row written between the read and the write is not overwritten" do
      # Both rows come back in one page, so the second row's ciphertext is
      # already in hand when the first row's write completes. The handler
      # rewrites the second row there — a legitimate concurrent re-seal —
      # which is exactly the write a plain update would discard.
      a = put_vault_row("legacy:a", "plain-a", %{id: "vlt_aaa"})
      b = put_vault_row("legacy:b", "plain-b", %{id: "vlt_bbb"})

      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})

      b_aad = Sanctum.CipherAAD.vault_entry(@athanor, b, "legacy")
      {:ok, concurrent} = Cipher.encrypt("written-by-someone-else", b_aad)

      handler = "rotation-cas-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:cyfr, :sanctum, :crypto_rotation, :row],
        fn _e, _m, meta, _c ->
          send(parent, {:row, meta.id, meta.result})

          if meta.id == a do
            {1, _} =
              Arca.Repo.update_all(
                from(r in Arca.Schemas.VaultEntry, where: r.id == ^b),
                set: [sealed_payload: concurrent]
              )
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, %{vault_entries: %{scanned: 2, rotated: 1, skipped: 1}}} =
               Rotation.reencrypt_all()

      assert_receive {:row, ^a, :rotated}
      assert_receive {:row, ^b, :cas_miss}

      # Byte-for-byte what the other writer left, not what the rotation
      # had prepared for the ciphertext it read.
      assert col("vault_entries", b, :sealed_payload) == concurrent
      assert {:ok, "written-by-someone-else"} = Cipher.decrypt(concurrent, b_aad)
    end
  end

  describe "T-REENCRYPT: fail-closed" do
    test "aborts the table run on an undecryptable row (never silently skips)" do
      id = put_vault_row("legacy:s", "v")
      # Retire k1 entirely: the row can no longer be decrypted → must abort.
      put_keyring(%{primary: "k2", keys: %{"k2" => @k2}})

      assert {:error,
              {:vault_entries,
               {:decrypt_failed, :sealed_payload, {:decrypt, {:unknown_key_label, "k1"}}}, ^id}} =
               Rotation.reencrypt_all()
    end
  end

  describe "T-REENCRYPT: audit/0" do
    test "reports the key-label distribution without decrypting" do
      put_webhook_row("hook_a", "1", nil)
      put_webhook_row("hook_b", "2", nil)
      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})
      put_webhook_row("hook_c", "3", nil)

      assert {:ok, report} = Rotation.audit()
      wh = report.webhooks
      assert wh.total == 3
      assert wh.on_primary == 1
      assert wh.on_other == %{"k1" => 2}
      assert wh.unknown == 0
    end

    test "covers vault_entries and excludes tombstoned rows" do
      put_vault_row("legacy:a", ~s({"v":1,"legacy":{}}))
      put_vault_row("gone", "irrelevant", %{sealed_payload: nil, status: "tombstoned"})

      assert {:ok, report} = Rotation.audit()
      assert report.vault_entries.total == 1
      assert report.vault_entries.on_primary == 1
      assert report.vault_entries.unknown == 0
    end

    test "covers oauth provider credentials" do
      put_provider_credential_row("github", ~s({"client_id":"cid","client_secret":null}))
      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})

      assert {:ok, report} = Rotation.audit()
      assert report.oauth_provider_credentials.total == 1
      assert report.oauth_provider_credentials.on_primary == 0
      assert report.oauth_provider_credentials.on_other == %{"k1" => 1}
      assert report.oauth_provider_credentials.unknown == 0
    end
  end

  describe "T-REENCRYPT: a person's keys" do
    test "each sealed key moves to the new primary and still opens as its own role" do
      user = person!()
      seed = :crypto.strong_rand_bytes(32)
      enrollment = enroll!(user.id, seed)
      head = enrollment.request_digest

      # A staged rotation, sealed to the person as their next live key.
      {:ok, staged} = Sanctum.Person.sign_rotate(user.id, head)

      {:ok, rotation} =
        Arca.IdentityAttempts.open(
          as(user.id),
          Map.merge(staged, %{
            kind: "rotation",
            request_id: request_id(),
            user_id: user.id,
            expected_head: head
          })
        )

      restored = %{
        live: :crypto.strong_rand_bytes(32),
        operational: :crypto.strong_rand_bytes(32)
      }

      restore = put_restore_row!(user.id, restored)
      row = identity_row(user.id)

      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})

      assert {:ok, summary} = Rotation.reencrypt_all()
      assert summary.person_identities == %{scanned: 1, rotated: 1, skipped: 0}
      # The enrollment's kit seed, the rotation's staged live key and the
      # restore's staged live and operational keys.
      assert summary.identity_attempts == %{scanned: 3, rotated: 3, skipped: 0}

      for {table, id, column} <- [
            {"person_identities", row.id, :live_key_sealed},
            {"person_identities", row.id, :operational_key_sealed},
            {"identity_attempts", enrollment.id, :kit_seed_sealed},
            {"identity_attempts", rotation.id, :staged_live_key_sealed},
            {"identity_attempts", restore.id, :staged_live_key_sealed},
            {"identity_attempts", restore.id, :staged_operational_key_sealed}
          ] do
        assert {:ok, {4, "k2"}} = Cipher.envelope(col(table, id, column)),
               "#{table}.#{column} is not on the new primary"
      end

      # The old key is gone, and nothing needed it: each key opens as what
      # it is, the person's by their frame, the restore's by its own.
      put_keyring(%{primary: "k2", keys: %{"k2" => @k2}})

      assert {:ok, ^seed} =
               Cipher.decrypt(
                 col("identity_attempts", enrollment.id, :kit_seed_sealed),
                 person_key(user.id, :kit_seed)
               )

      assert {:ok, restored_live} =
               Cipher.decrypt(
                 col("identity_attempts", restore.id, :staged_live_key_sealed),
                 person_key(restore.frame, :live)
               )

      assert restored_live == restored.live

      assert {:ok, restored_operational} =
               Cipher.decrypt(
                 col("identity_attempts", restore.id, :staged_operational_key_sealed),
                 person_key(restore.frame, :operational)
               )

      assert restored_operational == restored.operational

      # The operational key still signs a rotation its public half verifies.
      assert {:ok, again} = Sanctum.Person.sign_rotate(user.id, head)
      assert {:ok, entry} = again.entry |> Jason.decode!() |> Prima.Identity.Entry.decode()
      assert :ok = Prima.Identity.verify(entry, row.operational_public_key)

      # The rotation's staged key activates as a byte copy and signs as the
      # person's live key.
      for {from, to} <- [{"staged", "submitted"}, {"submitted", "accepted"}] do
        {:ok, _} = Arca.IdentityAttempts.advance(as(user.id), rotation.id, from, to)
      end

      {:ok, _} =
        Arca.IdentityAttempts.advance(as(user.id), rotation.id, "accepted", "keys_active")

      assert {:ok, cert} =
               Sanctum.Person.issue_device_cert(
                 user.id,
                 :crypto.strong_rand_bytes(32),
                 "pcl_rotation",
                 %{subject: :local, audience: Sanctum.origin(), athanor: @athanor}
               )

      assert {:ok, _} =
               Prima.DeviceCert.verify(cert, staged.staged_live_public_key,
                 home: Sanctum.origin(),
                 now: cert.not_before,
                 skew: 0
               )
    end

    test "a restore's key sealed under the person's frame aborts the run fail-closed" do
      # The rotation rebuilds a restore's frame from the restore, whatever
      # person it names, so keys sealed under that person's frame do not
      # open.
      user = person!()
      keys = %{live: :crypto.strong_rand_bytes(32), operational: :crypto.strong_rand_bytes(32)}
      %{id: restore_id} = put_restore_row!(user.id, keys, user.id)

      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})

      assert {:error,
              {:identity_attempts,
               {:decrypt_failed, :staged_live_key_sealed, {:decrypt, :aad_or_key_mismatch}},
               ^restore_id}} = Rotation.reencrypt_all()
    end

    test "a key sealed as another role aborts the run fail-closed" do
      # A live key column holding the operational key's ciphertext: the
      # column binds its role, so the rotation cannot open it as the live
      # key.
      user = person!()
      row = identity_row(user.id)
      row_id = row.id

      {1, _} =
        Arca.Repo.update_all(from(p in Arca.Schemas.PersonIdentity, where: p.id == ^row_id),
          set: [live_key_sealed: row.operational_key_sealed]
        )

      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})

      assert {:error,
              {:person_identities,
               {:decrypt_failed, :live_key_sealed, {:decrypt, :aad_or_key_mismatch}}, ^row_id}} =
               Rotation.reencrypt_all()
    end

    test "the audit counts each sealed column of a person's key rows" do
      user = person!()
      enroll!(user.id, :crypto.strong_rand_bytes(32))
      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})

      assert {:ok, report} = Rotation.audit()

      # The live and the operational key, each counted.
      assert report.person_identities == %{
               total: 2,
               on_primary: 0,
               on_other: %{"k1" => 2},
               unknown: 0
             }

      assert report.identity_attempts == %{
               total: 1,
               on_primary: 0,
               on_other: %{"k1" => 1},
               unknown: 0
             }
    end

    test "a live key activated mid-run leaves the operational key behind, which the audit shows and a second run moves" do
      # Two enrolled people; the walk goes in row id order, so the later
      # row's rotation activates between the two swaps.
      people = for _ <- 1..2, do: person!()
      for person <- people, do: enroll!(person.id, :crypto.strong_rand_bytes(32))
      [earlier, later] = people |> Enum.map(&identity_row(&1.id)) |> Enum.sort_by(& &1.id)

      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})

      {:ok, staged} = Sanctum.Person.sign_rotate(later.user_id, later.head_hash)

      {:ok, rotation} =
        Arca.IdentityAttempts.open(
          as(later.user_id),
          Map.merge(staged, %{
            kind: "rotation",
            request_id: request_id(),
            user_id: later.user_id,
            expected_head: later.head_hash
          })
        )

      for {from, to} <- [{"staged", "submitted"}, {"submitted", "accepted"}] do
        {:ok, _} = Arca.IdentityAttempts.advance(as(later.user_id), rotation.id, from, to)
      end

      handler = "rotation-person-#{System.unique_integer([:positive])}"
      earlier_id = earlier.id

      :telemetry.attach(
        handler,
        [:cyfr, :sanctum, :crypto_rotation, :row],
        fn _e, _m, meta, _c ->
          if meta.table == :person_identities and meta.id == earlier_id do
            {:ok, _} =
              Arca.IdentityAttempts.advance(
                as(later.user_id),
                rotation.id,
                "accepted",
                "keys_active"
              )
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, summary} = Rotation.reencrypt_all()
      :telemetry.detach(handler)

      # The activation changed the later row's live key, so its swap missed
      # and its operational key stayed under the old key.
      assert summary.person_identities == %{scanned: 2, rotated: 1, skipped: 1}

      assert {:ok, {4, "k2"}} =
               Cipher.envelope(col("person_identities", later.id, :live_key_sealed))

      assert {:ok, {4, "k1"}} =
               Cipher.envelope(col("person_identities", later.id, :operational_key_sealed))

      # The audit counts each column, so it is not yet safe to drop k1.
      assert {:ok, report} = Rotation.audit()
      assert report.person_identities.on_other == %{"k1" => 1}

      # Run again: it moves, and the old key is no longer needed.
      assert {:ok, again} = Rotation.reencrypt_all()
      assert again.person_identities.rotated == 1

      assert {:ok, report} = Rotation.audit()

      assert report.person_identities == %{
               total: 4,
               on_primary: 4,
               on_other: %{},
               unknown: 0
             }

      put_keyring(%{primary: "k2", keys: %{"k2" => @k2}})
      assert {:ok, _} = Sanctum.Person.sign_rotate(later.user_id, rotation.entry_hash)
    end
  end

  describe "T-REENCRYPT: roster binding" do
    # Every AAD purpose is a table of sealed rows somewhere; a purpose the
    # rotation tool does not walk is a key an operator retires while it still
    # seals live secrets. `reencrypt_all/1` and `audit/0` walk one roster —
    # `Arca.CipherRotation.tables/0`, where the schemas are — and the AAD
    # each row is re-sealed under is a `rotate_row/3` clause here. The two
    # lists live in different files, so this test is what keeps them one.
    @root Path.expand("../../../../..", __DIR__)
    # A person's keys are sealed on two tables: the identity row, and the
    # staged keys and pending kit seed of their attempts.
    @purpose_tables %{
      vault_entry: [:vault_entries],
      instance_entry: [:instance_entries],
      webhook_secret: [:webhooks],
      registry_token: [:registry_tokens],
      oauth_provider_credential: [:oauth_provider_credentials],
      person_key: [:person_identities, :identity_attempts]
    }

    test "every Sanctum.CipherAAD purpose has a rotation and an audit table" do
      aad_src = File.read!(Path.join(@root, "apps/sanctum/lib/sanctum/cipher_aad.ex"))

      purposes =
        Regex.scan(~r/purpose: :(\w+)/, aad_src)
        |> Enum.map(fn [_, p] -> String.to_existing_atom(p) end)
        |> Enum.uniq()
        |> Enum.sort()

      assert purposes == Enum.sort(Map.keys(@purpose_tables)),
             "Sanctum.CipherAAD gained or lost a purpose — teach " <>
               "Sanctum.Cipher.Rotation its table and update @purpose_tables here"

      # The roster both the re-encryption and the audit walk. Equality, not
      # inclusion: a table in it with no purpose is a walk over rows nothing
      # here knows how to re-seal.
      assert Enum.sort(Arca.CipherRotation.tables()) ==
               @purpose_tables |> Map.values() |> List.flatten() |> Enum.sort(),
             "Arca.CipherRotation's table roster and Sanctum.CipherAAD's purposes disagree"

      rot_src = File.read!(Path.join(@root, "apps/sanctum/lib/sanctum/cipher/rotation.ex"))

      for {purpose, tables} <- @purpose_tables, table <- tables do
        assert rot_src =~ "defp rotate_row(:#{table}, ",
               "rotation has no rotate_row/3 clause for :#{table} (purpose :#{purpose})"
      end
    end
  end

  describe "T-REENCRYPT-V4: retired envelope versions" do
    test "a pre-v4 row aborts the run fail-closed instead of being skipped" do
      aad = %{purpose: :webhook_secret, name: "V3ROW"}
      v3_ct = seal_v3("legacy-plain", aad, "k1", @k1)
      _id = put_webhook_row("V3ROW", "ignored", nil, %{secret_encrypted: v3_ct})

      # Unreadable version-3 envelopes must cause a rotation error.
      assert {:error, {:webhooks, {:not_a_cipher_envelope, _col}, _sample}} =
               Rotation.reencrypt_all()
    end

    test "vault entries rotate onto the new primary; payload_rev is never bumped" do
      id = put_vault_row("legacy:probe", ~s({"v":1,"legacy":{"secrets":[]}}))
      put_vault_row("gone", "x", %{sealed_payload: nil, status: "tombstoned"})

      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})

      assert {:ok, %{vault_entries: %{scanned: 1, rotated: 1, skipped: 0}}} =
               Rotation.reencrypt_all()

      new_ct = col("vault_entries", id, :sealed_payload)
      assert {:ok, {4, "k2"}} = Cipher.envelope(new_ct)

      aad = Sanctum.CipherAAD.vault_entry(@athanor, id, "legacy")
      assert {:ok, ~s({"v":1,"legacy":{"secrets":[]}})} = Cipher.decrypt(new_ct, aad)

      assert col("vault_entries", id, :payload_rev) == 0
    end

    test "instance entries rotate onto the new primary under their own AAD; payload_rev holds" do
      plain = ~s({"v":3,"fields":{"API_KEY":"sk-instance"}})
      id = put_instance_row("shared-openai", plain)
      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})

      assert {:ok, %{instance_entries: %{scanned: 1, rotated: 1, skipped: 0}}} =
               Rotation.reencrypt_all()

      new_ct = col("instance_entries", id, :sealed_payload)
      assert {:ok, {4, "k2"}} = Cipher.envelope(new_ct)

      assert {:ok, ^plain} =
               Cipher.decrypt(new_ct, Sanctum.CipherAAD.instance_entry(id, "openai.com"))

      assert col("instance_entries", id, :payload_rev) == 0

      # The AAD binds the id and the hint and no athanor: another hint, or
      # the vault-entry purpose over the same id, opens nothing.
      assert {:error, _} = Cipher.decrypt(new_ct, Sanctum.CipherAAD.instance_entry(id, "x.com"))

      assert {:error, _} =
               Cipher.decrypt(new_ct, Sanctum.CipherAAD.vault_entry("", id, "openai.com"))

      assert {:ok, %{instance_entries: %{rotated: 0, skipped: 1}}} = Rotation.reencrypt_all()
      assert {:ok, %{instance_entries: %{total: 1, on_primary: 1}}} = Rotation.audit()
    end

    test "registry tokens rotate onto the new primary and keep decrypting" do
      aad = Sanctum.CipherAAD.registry_token("user_1", "registry.test", "alice")
      {:ok, ct} = Cipher.encrypt(~s({"token":"cyfr_pt_x"}), aad)

      :ok =
        Arca.RegistryTokenStorage.put(%{
          user_id: "user_1",
          registry: "registry.test",
          namespace_slug: "alice",
          credential_ciphertext: ct
        })

      {:ok, row} = Arca.RegistryTokenStorage.get("user_1", "registry.test", "alice")

      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})

      assert {:ok, %{registry_tokens: %{scanned: 1, rotated: 1, skipped: 0}}} =
               Rotation.reencrypt_all()

      new_ct = col("registry_tokens", row.id, :credential_ciphertext)
      assert {:ok, {4, "k2"}} = Cipher.envelope(new_ct)
      assert {:ok, ~s({"token":"cyfr_pt_x"})} = Cipher.decrypt(new_ct, aad)
    end
  end
end
