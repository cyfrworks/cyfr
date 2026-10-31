# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.CipherIntegrationTest do
  @moduledoc """
  B3 (webhook rotation grace) and registry-token AAD-stability under the
  real tenant-binding cipher.
  """
  use ExUnit.Case, async: false

  alias Sanctum.{Context, Webhook}
  alias Sanctum.Cipher

  require Ecto.Query

  @key :crypto.strong_rand_bytes(32)

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    orig_kr = Application.get_env(:sanctum, :crypto_keyring)
    Application.put_env(:sanctum, :crypto_keyring, %{primary: "k1", keys: %{"k1" => @key}})

    on_exit(fn ->
      if orig_kr == nil,
        do: Application.delete_env(:sanctum, :crypto_keyring),
        else: Application.put_env(:sanctum, :crypto_keyring, orig_kr)
    end)

    %{ctx: ctx("ath_a")}
  end

  defp ctx(athanor_id) do
    Context.build(
      user_id: "u1",
      namespace: "u1",
      athanor_id: athanor_id,
      scope: :athanor,
      permissions: [:execute, :vault_read],
      auth_method: :oidc,
      authenticated: true
    )
  end

  defp sign(secret, body),
    do: "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

  # verify_with_grace opens a row's secrets under its tenant AAD; the current
  # and previous secret share it, so the grace window stays stable.
  describe "a webhook's secrets under rotation" do
    test "create → verify; rotate → old (grace) + new both verify; tenant-mismatch fails closed",
         %{ctx: ctx} do
      Sanctum.Test.ComponentHelpers.register_test_component("x", "1.0.0", "catalyst", %{}, ctx)
      profile = Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "catalyst:local.x:1.0.0")

      {:ok, %{secret: secret, slug: slug}} =
        Sanctum.TestContext.create_webhook(ctx, %{
          name: "h",
          replay_protection: "none",
          target_ref: "catalyst:local.x:1.0.0",
          profile_id: profile
        })

      {:ok, row} = Webhook.resolve_ingress(slug)
      body = "event-body"

      assert :ok = Webhook.verify_with_grace(row, body, sign(secret, body))

      assert {:error, :signature_mismatch} =
               Webhook.verify_with_grace(row, body, sign("wrong", body))

      {:ok, %{secret: new_secret}} = Sanctum.TestContext.rotate_webhook(ctx, "h")
      {:ok, rotated} = Webhook.resolve_ingress(slug)

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

    # The same ciphertext under another athanor's AAD fails the cipher's
    # tag check: refused as `:secret_unreadable`, a fault of the server's
    # and never `:signature_mismatch`, since the sender signed correctly.
    test "a row copied to another athanor cannot open its secret", %{ctx: ctx} do
      Sanctum.Test.ComponentHelpers.register_test_component("x", "1.0.0", "catalyst", %{}, ctx)
      profile = Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "catalyst:local.x:1.0.0")

      {:ok, %{secret: secret, slug: slug}} =
        Sanctum.TestContext.create_webhook(ctx, %{
          name: "copied",
          replay_protection: "none",
          target_ref: "catalyst:local.x:1.0.0",
          profile_id: profile
        })

      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(w in Arca.Schemas.Webhook, where: w.slug == ^slug),
          set: [athanor_id: "ath_b"]
        )

      {:ok, copied} = Webhook.resolve_ingress(slug)

      assert {:error, :secret_unreadable} =
               Webhook.verify_with_grace(copied, "event-body", sign(secret, "event-body"))
    end
  end

  describe "a registry credential" do
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
      alice = person_context("github|https://github.com|111")
      other = person_context("github|https://github.com|222")

      assert :ok =
               Compendium.Registry.CredentialStore.put_push_token(
                 alice,
                 "reg.test",
                 "alice",
                 "cyfr_pt_alice",
                 "personal"
               )

      assert {:ok, %{token: "cyfr_pt_alice"}} =
               Compendium.Registry.CredentialStore.get(alice, "reg.test", "alice")

      # A different principal cannot read it (distinct secret name → no row).
      assert {:error, :not_found} =
               Compendium.Registry.CredentialStore.get(other, "reg.test", "alice")
    end
  end

  defp person_context(user_id),
    do: Sanctum.Context.build(user_id: user_id, authenticated: true, auth_method: :oidc)
end
