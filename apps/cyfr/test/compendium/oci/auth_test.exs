# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.AuthTest do
  use ExUnit.Case, async: false

  alias Compendium.OCI.{Auth, Errors}
  alias Compendium.Registry.CredentialStore
  alias Sanctum.Context

  @registry "registry.test.example"
  @user "oci_auth_test_user"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    for slug <- ["alice", "stripe.com"] do
      CredentialStore.delete(ctx(), @registry, slug)
    end

    :ok
  end

  defp ctx do
    Context.build(
      user_id: @user,
      athanor_id: "ath_test",
      permissions: [:*],
      scope: :athanor,
      auth_method: :oidc,
      namespace: "testns",
      authenticated: true
    )
  end

  # A row written past the facade: sealed around `plaintext` under the key
  # it is stored at.
  defp plant!(slug, plaintext) do
    aad = Sanctum.CipherAAD.registry_token(@user, @registry, slug)
    {:ok, ciphertext} = Sanctum.Cipher.encrypt(plaintext, aad)

    :ok =
      Arca.RegistryTokenStorage.put(%{
        user_id: @user,
        registry: @registry,
        namespace_slug: slug,
        credential_ciphertext: ciphertext
      })
  end

  defp outage!,
    do: Arca.Repo.query!("ALTER TABLE registry_tokens RENAME TO registry_tokens_unavailable")

  describe "fetch_credential/3" do
    test "returns :anonymous when no credential is stored" do
      assert Auth.fetch_credential(@registry, "alice", ctx()) == :anonymous
    end

    test "returns :anonymous when ctx is nil (no cross-user fallback)" do
      :ok = CredentialStore.put_push_token(ctx(), @registry, "alice", "cyfr_pt_fake", "personal")

      assert Auth.fetch_credential(@registry, "alice", nil) == :anonymous
    end

    test "returns the push-token credential when one is stored for the user+namespace" do
      :ok =
        CredentialStore.put_push_token(
          ctx(),
          @registry,
          "alice",
          "cyfr_pt_alice_token",
          "personal"
        )

      assert {:ok, fetched} = Auth.fetch_credential(@registry, "alice", ctx())
      assert fetched.type == :push_token
      assert fetched.token == "cyfr_pt_alice_token"
      assert fetched.namespace == "alice"
    end

    test "scoped per-namespace: alice's token does not surface for stripe.com" do
      :ok = CredentialStore.put_push_token(ctx(), @registry, "alice", "cyfr_pt_alice", "personal")

      assert Auth.fetch_credential(@registry, "stripe.com", ctx()) == :anonymous
    end

    @tag :capture_log
    test "a stored row that does not open is corrupt, never anonymous" do
      for plaintext <- [
            "not json",
            ~s({"type":"push_token"}),
            ~s({"type":"push_token","token":""}),
            ~s({"type":"push_token","token":7})
          ] do
        plant!("alice", plaintext)

        assert Auth.fetch_credential(@registry, "alice", ctx()) == {:error, :corrupt},
               "#{plaintext} read as something other than corrupt"
      end
    end

    @tag :capture_log
    test "a store that cannot answer is unavailable, never anonymous" do
      :ok = CredentialStore.put_push_token(ctx(), @registry, "alice", "cyfr_pt_alice", "personal")
      outage!()

      assert Auth.fetch_credential(@registry, "alice", ctx()) == {:error, :unavailable}
    end

    test "the log names the namespace and never the token" do
      plant!("alice", ~s({"type":"push_token","token":["cyfr_pt_leak"]}))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :corrupt} = Auth.fetch_credential(@registry, "alice", ctx())
        end)

      assert log =~ "alice"
      refute log =~ "cyfr_pt_leak"
    end
  end

  describe "auth_headers/4" do
    test "returns empty headers when no credential exists (anonymous pull)" do
      assert {:ok, []} = Auth.auth_headers(@registry, "alice/catalysts/foo", "alice", ctx())
    end

    test "emits Bearer <push_token> when a push token is stored" do
      :ok =
        CredentialStore.put_push_token(ctx(), @registry, "alice", "cyfr_pt_abc123", "personal")

      assert {:ok, [{"authorization", "Bearer cyfr_pt_abc123"}]} =
               Auth.auth_headers(@registry, "alice/catalysts/foo", "alice", ctx())
    end

    @tag :capture_log
    test "a corrupt token refuses as unavailable and names the namespace, not the token" do
      plant!("alice", ~s({"type":"push_token","token":42}))

      assert {:error,
              %Errors{
                reason: :registry_unavailable,
                detail: %{credential_store: :corrupt},
                message: message
              }} = Auth.auth_headers(@registry, "alice/catalysts/foo", "alice", ctx())

      assert message ==
               "The push token stored for namespace 'alice' could not be opened — " <>
                 "sign in again to re-mint it"
    end

    @tag :capture_log
    test "a store outage refuses as unavailable rather than going anonymous" do
      outage!()

      assert {:error,
              %Errors{
                reason: :registry_unavailable,
                detail: %{credential_store: :unavailable},
                message: "Your registry credentials could not be read — retry shortly"
              }} = Auth.auth_headers(@registry, "alice/catalysts/foo", "alice", ctx())
    end
  end
end
