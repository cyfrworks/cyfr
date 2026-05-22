# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.CipherIntegrationTest do
  @moduledoc """
  B2 (OAuth version cascade) and B3 (webhook rotation grace) AAD-stability
  under the real tenant-binding cipher.
  """
  use ExUnit.Case, async: false

  alias Sanctum.{Context, OAuth, Webhook}
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

    %{ctx: ctx("org_a")}
  end

  defp ctx(org) do
    Context.build(
      user_id: "u1",
      namespace: "u1",
      org_id: org,
      project_id: "default",
      scope: :project,
      permissions: [:execute, :secrets_read, :secrets_write],
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
      {:ok, %{secret: secret, slug: slug}} =
        Webhook.create(ctx, %{name: "h", target_ref: "catalyst:local.x:1.0.0"})

      {:ok, row} = Arca.WebhookStorage.get_by_slug(slug)
      body = "event-body"

      assert :ok = Webhook.verify_with_grace(row, body, sign(secret, body))

      assert {:error, :signature_mismatch} =
               Webhook.verify_with_grace(row, body, sign("wrong", body))

      # Cross-tenant: same ciphertext, AAD rebuilt for another org → the
      # cipher's tag check fails → 401-class :signature_mismatch (not 500).
      assert {:error, :signature_mismatch} =
               Webhook.verify_with_grace(%{row | org_id: "org_b"}, body, sign(secret, body))

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

  # ==========================================================================
  # T-OAUTH-CASCADE (B2): a token stored under the name-level ref must decrypt
  # when looked up via a versioned ref (cascade), because the AAD binds the
  # *storage* ref — never the caller's versioned lookup ref.
  # ==========================================================================

  describe "T-OAUTH-CASCADE" do
    test "name-level-stored token decrypts via versioned-ref cascade", %{ctx: ctx} do
      name_ref = "catalyst:local.cascade_ok"
      provider = "google"
      json = ~s({"access_token":"ya29-cascade","expires_at":null})

      aad = %{
        purpose: :oauth_token,
        org: "org_a",
        project: "default",
        name: name_ref,
        sub: provider
      }

      {:ok, ct} = Cipher.encrypt(json, aad)
      put_oauth(name_ref, provider, ct)

      assert {:ok, "ya29-cascade"} =
               OAuth.get_access_token(ctx, name_ref <> ":0.1.0", provider)
    end

    test "AAD bound to the wrong (versioned) ref would not decrypt — proves the binding is real",
         %{ctx: ctx} do
      name_ref = "catalyst:local.cascade_bad"
      provider = "google"
      json = ~s({"access_token":"nope","expires_at":null})
      # Encrypt with the WRONG name (the versioned lookup ref) but store under
      # the name-level key the cascade actually reads.
      wrong_aad = %{
        purpose: :oauth_token,
        org: "org_a",
        project: "default",
        name: name_ref <> ":9.9.9",
        sub: provider
      }

      {:ok, ct} = Cipher.encrypt(json, wrong_aad)
      put_oauth(name_ref, provider, ct)

      assert {:error, msg} = OAuth.get_access_token(ctx, name_ref <> ":0.1.0", provider)
      assert msg =~ "authorization_required"
    end
  end

  # ==========================================================================
  # T-REGISTRY-CRED: registry push-token credentials are stored platform-scoped
  # (system context), so the AAD's scope/org/project are identical for every
  # user — the per-user crypto binding rests SOLELY on the `name` field, which
  # embeds the globally-unique user_id (`_registry.{registry}.{user_id}.{slug}`)
  # and is unconditionally framed into the cipher AAD. These tests lock that
  # property: a blob is bound to its principal and cannot be reused across
  # users even though they share the platform partition.
  # ==========================================================================

  describe "T-REGISTRY-CRED" do
    test "a registry blob is crypto-bound to its principal via the name AAD" do
      # The exact AAD Sanctum.Secrets builds for a platform-scoped registry
      # secret (system context → scope "platform", org "", project "default").
      name_a = "_registry.reg.test.github|https://github.com|111.alice"
      name_b = "_registry.reg.test.github|https://github.com|222.bob"
      aad_a = Sanctum.CipherAAD.secret("platform", nil, "default", name_a)
      aad_b = Sanctum.CipherAAD.secret("platform", nil, "default", name_b)

      {:ok, ct} = Cipher.encrypt(~s({"token":"cyfr_pt_alice"}), aad_a)

      # Same principal → decrypts.
      assert {:ok, ~s({"token":"cyfr_pt_alice"})} = Cipher.decrypt(ct, aad_a)
      # Another user's row (only `name` differs) → GCM tag mismatch, fail closed.
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

  defp put_oauth(ref, provider, ct) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Arca.Repo.insert_all("oauth_credentials", [
      %{
        id: Ecto.UUID.generate(),
        provider: provider,
        component_ref: ref,
        encrypted_data: ct,
        org_id: "org_a",
        project_id: "default",
        inserted_at: now,
        updated_at: now
      }
    ])
  end
end
