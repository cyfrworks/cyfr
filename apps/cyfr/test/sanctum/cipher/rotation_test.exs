# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Cipher.RotationTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Sanctum.Cipher
  alias Sanctum.Cipher.Rotation

  @k1 :crypto.strong_rand_bytes(32)
  @k2 :crypto.strong_rand_bytes(32)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    orig_kr = Application.get_env(:cyfr, :crypto_keyring)

    put_keyring(%{primary: "k1", keys: %{"k1" => @k1}})

    on_exit(fn ->
      restore(:crypto_keyring, orig_kr)
    end)

    :ok
  end

  defp put_keyring(kr), do: Application.put_env(:cyfr, :crypto_keyring, kr)
  defp restore(k, nil), do: Application.delete_env(:cyfr, k)
  defp restore(k, v), do: Application.put_env(:cyfr, k, v)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp uuid, do: Ecto.UUID.generate()

  # Insert rows whose ciphertext is produced with the SAME AAD the rotation
  # tool will rebuild from the row's columns (the contract under test).
  @org "org_a"
  @proj "default"
  @scope "project"

  defp put_webhook_row(name, secret, prev, over \\ %{}) do
    aad = %{purpose: :webhook_secret, scope: @scope, org: @org, project: @proj, name: name}

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
        scope_type: @scope,
        org_id: @org,
        project_id: @proj,
        inserted_at: now(),
        updated_at: now()
      }
    ])

    id
  end

  defp put_vault_row(name, plaintext, over \\ %{}) do
    id = "vlt_" <> uuid()
    hint = Map.get(over, :provider_hint, "legacy")
    aad = Sanctum.CipherAAD.vault_entry(@org, @proj, id, hint)

    sealed =
      case Map.get(over, :sealed_payload, :seal) do
        :seal -> elem(Cipher.encrypt(plaintext, aad), 1)
        other -> other
      end

    Arca.Repo.insert_all(Arca.Schemas.VaultEntry, [
      %{
        id: id,
        org_id: @org,
        project_id: @proj,
        name: name,
        provider_hint: hint,
        kind: "bundle",
        status: Map.get(over, :status, "active"),
        payload_rev: 0,
        sealed_payload: sealed,
        inserted_at: now(),
        updated_at: now()
      }
    ])

    id
  end

  # Seals a v2 envelope as the pre-v3 writer did (production has no v2
  # writer left; legacy rows are fabricated here).
  defp seal_v2(plaintext, %{purpose: purpose} = ctx, label, master) do
    info = "cyfr-cipher-v1|" <> Atom.to_string(purpose)
    iters = max(Application.get_env(:cyfr, :pbkdf2_iterations, 100_000), 100_000)
    key = :crypto.pbkdf2_hmac(:sha256, master, info, iters, 32)
    iv = :crypto.strong_rand_bytes(12)

    fields =
      for k <- [:scope, :org, :project, :name, :sub] do
        v = Map.get(ctx, k) || ""
        <<byte_size(v)::32, v::binary>>
      end

    aad =
      IO.iodata_to_binary([
        "cyfrv2",
        <<0x02>>,
        <<byte_size(label)::32, label::binary>>,
        <<byte_size(Atom.to_string(purpose))::32, Atom.to_string(purpose)::binary>>
        | fields
      ])

    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, 16, true)
    <<0x02, byte_size(label)::8, label::binary, iv::binary, tag::binary, ct::binary>>
  end

  defp col(table, id, field) do
    Arca.Repo.one(from(r in table, where: r.id == ^id, select: field(r, ^field)))
  end

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

      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})

      assert {:ok, summary} = Rotation.reencrypt_all()
      assert summary.webhooks == %{scanned: 1, rotated: 1, skipped: 0}
      assert summary.vault_entries == %{scanned: 1, rotated: 1, skipped: 0}
      assert summary.registry_tokens == %{scanned: 1, rotated: 1, skipped: 0}
      refute summary.dry_run

      # Every column is now on k2 and still decrypts to the original plaintext.
      assert {:ok, "k2"} = Cipher.label(col("webhooks", w, :secret_encrypted))
      assert {:ok, "k2"} = Cipher.label(col("webhooks", w, :previous_secret_encrypted))

      wh_aad = %{
        purpose: :webhook_secret,
        scope: "project",
        org: "org_a",
        project: "default",
        name: "hook1"
      }

      assert {:ok, "whsec_aaa"} = Cipher.decrypt(col("webhooks", w, :secret_encrypted), wh_aad)

      assert {:ok, "whsec_old"} =
               Cipher.decrypt(col("webhooks", w, :previous_secret_encrypted), wh_aad)

      assert {:ok, "k2"} = Cipher.label(col("vault_entries", v, :sealed_payload))

      vault_aad = Sanctum.CipherAAD.vault_entry(@org, @proj, v, "legacy")

      assert {:ok, ~s({"v":2,"fields":{}})} =
               Cipher.decrypt(col("vault_entries", v, :sealed_payload), vault_aad)

      assert {:ok, "k2"} = Cipher.label(col("registry_tokens", rt_row.id, :credential_ciphertext))

      assert {:ok, ~s({"token":"cyfr_pt_x"})} =
               Cipher.decrypt(col("registry_tokens", rt_row.id, :credential_ciphertext), rt_aad)
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
  end

  describe "T-REENCRYPT-V3: retired envelope versions" do
    test "a pre-v3 row aborts the run fail-closed instead of being skipped" do
      aad = %{purpose: :webhook_secret, scope: @scope, org: @org, project: @proj, name: "V2ROW"}
      v2_ct = seal_v2("legacy-plain", aad, "k1", @k1)
      _id = put_webhook_row("V2ROW", "ignored", nil, %{secret_encrypted: v2_ct})

      # The v2 read path is retired: an unreadable envelope must surface,
      # never be silently skipped past.
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
      assert {:ok, {3, "k2"}} = Cipher.envelope(new_ct)

      aad = Sanctum.CipherAAD.vault_entry(@org, @proj, id, "legacy")
      assert {:ok, ~s({"v":1,"legacy":{"secrets":[]}})} = Cipher.decrypt(new_ct, aad)

      assert col("vault_entries", id, :payload_rev) == 0
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
      assert {:ok, {3, "k2"}} = Cipher.envelope(new_ct)
      assert {:ok, ~s({"token":"cyfr_pt_x"})} = Cipher.decrypt(new_ct, aad)
    end
  end
end
