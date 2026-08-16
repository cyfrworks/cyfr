# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.CipherIntegrationTest do
  @moduledoc """
  B3 (webhook rotation grace) and registry-token AAD-stability under the
  real tenant-binding cipher.
  """
  use ExUnit.Case, async: false

  alias Sanctum.{Context, Webhook}
  alias Sanctum.Cipher

  @key :crypto.strong_rand_bytes(32)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    orig_kr = Application.get_env(:cyfr, :crypto_keyring)
    Application.put_env(:cyfr, :crypto_keyring, %{primary: "k1", keys: %{"k1" => @key}})

    on_exit(fn ->
      if orig_kr == nil,
        do: Application.delete_env(:cyfr, :crypto_keyring),
        else: Application.put_env(:cyfr, :crypto_keyring, orig_kr)
    end)

    %{ctx: ctx("ath_a")}
  end

  defp ctx(athanor_id) do
    Context.build(
      user_id: "u1",
      namespace: "u1",
      athanor_id: athanor_id,
      scope: :athanor,
      permissions: [:execute, :vault_read, :vault_write],
      auth_method: :oidc,
      authenticated: true
    )
  end

  defp sign(secret, body),
    do: "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

  # ==========================================================================
  # T-WEBHOOK-GRACE (B3): verify_with_grace rebuilds the row's tenant AAD;
  # current + previous secret share it, so the grace window stays stable.
  # ==========================================================================

  describe "T-WEBHOOK-GRACE" do
    test "create → verify; rotate → old (grace) + new both verify; tenant-mismatch fails closed",
         %{ctx: ctx} do
      Sanctum.Test.ComponentHelpers.register_test_component("x", "1.0.0", "catalyst", %{}, ctx)
      Sanctum.Test.ConsentFixtures.start_source!()
      profile = Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "catalyst:local.x:1.0.0")

      {:ok, %{secret: secret, slug: slug}} =
        Webhook.create(ctx, %{
          name: "h",
          target_ref: "catalyst:local.x:1.0.0",
          profile_id: profile
        })

      {:ok, row} = Arca.WebhookStorage.get_by_slug(slug)
      body = "event-body"

      assert :ok = Webhook.verify_with_grace(row, body, sign(secret, body))

      assert {:error, :signature_mismatch} =
               Webhook.verify_with_grace(row, body, sign("wrong", body))

      # Cross-tenant: same ciphertext, AAD rebuilt for another athanor → the
      # cipher's tag check fails → 401-class :signature_mismatch (not 500).
      assert {:error, :signature_mismatch} =
               Webhook.verify_with_grace(%{row | athanor_id: "ath_b"}, body, sign(secret, body))

      {:ok, %{secret: new_secret}} = Webhook.rotate(ctx, "h")
      {:ok, rotated} = Arca.WebhookStorage.get_by_slug(slug)

      assert :ok = Webhook.verify_with_grace(rotated, body, sign(new_secret, body))
      # Old secret still valid inside the grace window (previous ciphertext
      # shares the row identity → same AAD).
      assert :ok = Webhook.verify_with_grace(rotated, body, sign(secret, body))

      # After the grace window the previous secret is ignored.
      expired = %{rotated | previous_secret_expires_at: DateTime.add(DateTime.utc_now(), -10)}

      assert {:error, :signature_mismatch} =
               Webhook.verify_with_grace(expired, body, sign(secret, body))

      assert :ok = Webhook.verify_with_grace(expired, body, sign(new_secret, body))
    end
  end

  describe "T-REGISTRY-CRED" do
    test "a registry blob is crypto-bound to its principal via the user AAD" do
      # The exact AAD the registry-token store builds — the owning user
      # rides the `user` frame, so a row repointed at another principal
      # fails decryption.
      aad_a =
        Sanctum.CipherAAD.registry_token("github|https://github.com|111", "reg.test", "alice")

      aad_b =
        Sanctum.CipherAAD.registry_token("github|https://github.com|222", "reg.test", "alice")

      {:ok, ct} = Cipher.encrypt(~s({"token":"cyfr_pt_alice"}), aad_a)

      # Same principal → decrypts.
      assert {:ok, ~s({"token":"cyfr_pt_alice"})} = Cipher.decrypt(ct, aad_a)
      # Another user's row (only `user` differs) → GCM tag mismatch, fail closed.
      assert {:error, {:decrypt, :aad_or_key_mismatch}} = Cipher.decrypt(ct, aad_b)
    end

    test "CredentialStore keeps users isolated end-to-end under the cipher" do
      cred = %{
        type: :push_token,
        token: "cyfr_pt_alice",
        namespace: "alice",
        issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        label: "test"
      }

      assert :ok =
               Compendium.Registry.CredentialStore.put(
                 "github|https://github.com|111",
                 "reg.test",
                 "alice",
                 cred
               )

      assert {:ok, %{token: "cyfr_pt_alice"}} =
               Compendium.Registry.CredentialStore.get(
                 "github|https://github.com|111",
                 "reg.test",
                 "alice"
               )

      # A different principal cannot read it (distinct secret name → no row).
      assert :not_found =
               Compendium.Registry.CredentialStore.get(
                 "github|https://github.com|222",
                 "reg.test",
                 "alice"
               )
    end
  end
end
