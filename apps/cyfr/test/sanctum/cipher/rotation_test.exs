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

    Arca.Repo.insert_all("secrets", [
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

    Arca.Repo.insert_all("oauth_credentials", [
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

    Arca.Repo.insert_all("webhooks", [
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
  end
end
