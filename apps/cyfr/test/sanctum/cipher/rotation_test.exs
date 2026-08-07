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

  defp put_secret_row(name, plaintext) do
    aad = %{purpose: :secret, scope: @scope, org: @org, project: @proj, name: name}
    {:ok, ct} = Cipher.encrypt(plaintext, aad)
    id = uuid()

    Arca.Repo.insert_all(Arca.Schemas.Secret, [
      %{
        id: id,
        name: name,
        encrypted_value: ct,
        scope: @scope,
        org_id: @org,
        project_id: @proj,
        inserted_at: now(),
        updated_at: now()
      }
    ])

    id
  end

  defp put_oauth_row(ref, provider, plaintext) do
    aad = %{purpose: :oauth_token, org: @org, project: @proj, name: ref, sub: provider}
    {:ok, ct} = Cipher.encrypt(plaintext, aad)
    id = uuid()

    Arca.Repo.insert_all(Arca.Schemas.OauthCredential, [
      %{
        id: id,
        provider: provider,
        component_ref: ref,
        encrypted_data: ct,
        org_id: @org,
        project_id: @proj,
        inserted_at: now(),
        updated_at: now()
      }
    ])

    id
  end

  defp put_webhook_row(name, secret, prev) do
    aad = %{purpose: :webhook_secret, scope: @scope, org: @org, project: @proj, name: name}
    {:ok, sec} = Cipher.encrypt(secret, aad)
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
      s = put_secret_row("API_KEY", "sk-live-123")
      o = put_oauth_row("catalyst:local.gmail", "google", ~s({"access_token":"ya29"}))
      w = put_webhook_row("hook1", "whsec_aaa", "whsec_old")

      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})

      assert {:ok, summary} = Rotation.reencrypt_all()
      assert summary.secrets == %{scanned: 1, rotated: 1, skipped: 0}
      assert summary.oauth_credentials == %{scanned: 1, rotated: 1, skipped: 0}
      assert summary.webhooks == %{scanned: 1, rotated: 1, skipped: 0}
      refute summary.dry_run

      # Every column is now on k2 and still decrypts to the original plaintext.
      assert {:ok, "k2"} = Cipher.label(col("secrets", s, :encrypted_value))

      assert {:ok, "sk-live-123"} =
               Cipher.decrypt(
                 col("secrets", s, :encrypted_value),
                 %{
                   purpose: :secret,
                   scope: "project",
                   org: "org_a",
                   project: "default",
                   name: "API_KEY"
                 }
               )

      assert {:ok, "k2"} = Cipher.label(col("oauth_credentials", o, :encrypted_data))

      assert {:ok, ~s({"access_token":"ya29"})} =
               Cipher.decrypt(
                 col("oauth_credentials", o, :encrypted_data),
                 %{
                   purpose: :oauth_token,
                   org: "org_a",
                   project: "default",
                   name: "catalyst:local.gmail",
                   sub: "google"
                 }
               )

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
    end

    test "re-running is a no-op (idempotent / resumable)" do
      put_secret_row("S", "v")
      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})

      assert {:ok, %{secrets: %{rotated: 1, skipped: 0}}} = Rotation.reencrypt_all()

      assert {:ok, %{secrets: %{scanned: 1, rotated: 0, skipped: 1}}} =
               Rotation.reencrypt_all()
    end

    test "rows already on the primary are skipped, byte-unchanged" do
      s = put_secret_row("S", "v")
      before = col("secrets", s, :encrypted_value)

      # primary is still k1 (what the row was written under)
      assert {:ok, %{secrets: %{scanned: 1, rotated: 0, skipped: 1}}} =
               Rotation.reencrypt_all()

      assert col("secrets", s, :encrypted_value) == before
    end
  end

  describe "T-REENCRYPT: dry-run" do
    test "reports work but writes nothing" do
      s = put_secret_row("S", "v")
      before = col("secrets", s, :encrypted_value)
      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})

      assert {:ok, %{secrets: %{scanned: 1, rotated: 1, skipped: 0}, dry_run: true}} =
               Rotation.reencrypt_all(dry_run: true)

      assert col("secrets", s, :encrypted_value) == before
      assert {:ok, "k1"} = Cipher.label(col("secrets", s, :encrypted_value))
    end
  end

  describe "T-REENCRYPT: fail-closed" do
    test "aborts the table run on an undecryptable row (never silently skips)" do
      id = put_secret_row("S", "v")
      # Retire k1 entirely: the row can no longer be decrypted → must abort.
      put_keyring(%{primary: "k2", keys: %{"k2" => @k2}})

      assert {:error,
              {:secrets,
               {:decrypt_failed, :encrypted_value, {:decrypt, {:unknown_key_label, "k1"}}}, ^id}} =
               Rotation.reencrypt_all()
    end
  end

  describe "T-REENCRYPT: audit/0" do
    test "reports the key-label distribution without decrypting" do
      put_secret_row("A", "1")
      put_secret_row("B", "2")
      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})
      put_secret_row("C", "3")

      assert {:ok, report} = Rotation.audit()
      sec = report.secrets
      assert sec.total == 3
      assert sec.on_primary == 1
      assert sec.on_other == %{"k1" => 2}
      assert sec.unknown == 0
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

  describe "T-REENCRYPT-V3: envelope upgrade" do
    test "a v2 row on the PRIMARY key is re-sealed to v3, not skipped" do
      aad = %{purpose: :secret, scope: @scope, org: @org, project: @proj, name: "V2ROW"}
      v2_ct = seal_v2("legacy-plain", aad, "k1", @k1)
      id = uuid()

      Arca.Repo.insert_all(Arca.Schemas.Secret, [
        %{
          id: id,
          name: "V2ROW",
          encrypted_value: v2_ct,
          scope: @scope,
          org_id: @org,
          project_id: @proj,
          inserted_at: now(),
          updated_at: now()
        }
      ])

      # primary is still k1 — the label matches, the envelope version does not.
      assert {:ok, %{secrets: %{scanned: 1, rotated: 1, skipped: 0}}} =
               Rotation.reencrypt_all()

      new_ct = col("secrets", id, :encrypted_value)
      assert {:ok, {3, "k1"}} = Cipher.envelope(new_ct)
      assert {:ok, "legacy-plain"} = Cipher.decrypt(new_ct, aad)

      # Second pass: now genuinely finished.
      assert {:ok, %{secrets: %{scanned: 1, rotated: 0, skipped: 1}}} =
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
  end
end
