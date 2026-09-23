# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.RegistryCredentialsTest do
  # A person's registry push tokens: keyed by the person the context names,
  # sealed at rest, and read with an outage and a damaged row kept apart
  # from absence.
  use ExUnit.Case, async: false

  alias Sanctum.CipherAAD
  alias Sanctum.Context
  alias Sanctum.RegistryCredentials

  @registry "registry.credentials.test"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {alice, bob} = Sanctum.TestContext.two_contexts()
    {:ok, alice: alice, bob: bob}
  end

  # A row written past the facade: sealed bytes the caller chooses, under
  # the AAD of the key it is stored at unless `aad_slug` says otherwise.
  defp plant!(%Context{user_id: user_id}, slug, plaintext, aad_slug \\ nil) do
    aad = CipherAAD.registry_token(user_id, @registry, aad_slug || slug)
    {:ok, ciphertext} = Sanctum.Cipher.encrypt(plaintext, aad)

    :ok =
      Arca.RegistryTokenStorage.put(%{
        user_id: user_id,
        registry: @registry,
        namespace_slug: slug,
        credential_ciphertext: ciphertext
      })
  end

  defp outage!, do: Arca.Repo.query!("ALTER TABLE registry_tokens RENAME TO registry_tokens_unavailable")

  describe "put_push_token and get" do
    test "stores a push token for the context's person and reads it back", %{alice: alice} do
      assert :ok =
               RegistryCredentials.put_push_token(alice, @registry, "alice", "cyfr_pt_a", "personal",
                 label: "laptop"
               )

      assert {:ok, credential} = RegistryCredentials.get(alice, @registry, "alice")

      assert %{
               type: :push_token,
               token: "cyfr_pt_a",
               namespace: "alice",
               role: "personal",
               label: "laptop"
             } = credential

      assert is_binary(credential.issued_at)
    end

    test "stores the label it is given and none when it is given none", %{alice: alice} do
      :ok = RegistryCredentials.put_push_token(alice, @registry, "alice", "cyfr_pt_a", "personal")
      assert {:ok, credential} = RegistryCredentials.get(alice, @registry, "alice")
      refute Map.has_key?(credential, :label)
    end

    test "a second write replaces the first", %{alice: alice} do
      :ok = RegistryCredentials.put_push_token(alice, @registry, "alice", "cyfr_pt_1", "personal")
      :ok = RegistryCredentials.put_push_token(alice, @registry, "alice", "cyfr_pt_2", "personal")

      assert {:ok, %{token: "cyfr_pt_2"}} = RegistryCredentials.get(alice, @registry, "alice")
    end

    test "is keyed by the context's person: another never reads it", %{alice: alice, bob: bob} do
      :ok = RegistryCredentials.put_push_token(alice, @registry, "alice", "cyfr_pt_a", "personal")

      assert {:error, :not_found} = RegistryCredentials.get(bob, @registry, "alice")
      assert {:ok, []} = RegistryCredentials.list(bob, @registry)
    end

    test "a missing slot is absent", %{alice: alice} do
      assert {:error, :not_found} = RegistryCredentials.get(alice, @registry, "nobody")
    end

    test "a slug or token that is not a string stores nothing", %{alice: alice} do
      assert :skipped = RegistryCredentials.put_push_token(alice, @registry, nil, "t", "personal")
      assert :skipped = RegistryCredentials.put_push_token(alice, @registry, "alice", nil, "member")
      assert {:ok, []} = RegistryCredentials.list(alice, @registry)
    end
  end

  describe "a damaged row is corrupt, never absent" do
    test "a row sealed under another key does not open", %{alice: alice} do
      plant!(alice, "alice", ~s({"type":"push_token","token":"t"}), "somewhere-else")

      assert {:error, :corrupt} = RegistryCredentials.get(alice, @registry, "alice")
      assert {:ok, [%{id: id, status: :corrupt}]} = RegistryCredentials.list(alice, @registry)
      assert is_binary(id)
    end

    test "a row that opens to anything but a push token is corrupt", %{alice: alice} do
      for plaintext <- [~s({"type":"session","token":"t"}), ~s(["push_token"]), "not json"] do
        plant!(alice, "alice", plaintext)

        assert {:error, :corrupt} = RegistryCredentials.get(alice, @registry, "alice"),
               "#{plaintext} read as something other than corrupt"
      end
    end

    test "a listing keeps the damaged row in its place beside the good ones", %{alice: alice} do
      :ok = RegistryCredentials.put_push_token(alice, @registry, "alice", "cyfr_pt_a", "personal")
      plant!(alice, "bob", "not json")
      :ok = RegistryCredentials.put_push_token(alice, @registry, "stripe.com", "cyfr_pt_s", "member")

      assert {:ok, [%{namespace: "alice"}, %{status: :corrupt}, %{namespace: "stripe.com"}]} =
               RegistryCredentials.list(alice, @registry)
    end
  end

  test "a listing is personal and reserved first, then publishers, alphabetical", %{
    alice: alice
  } do
    for slug <- ["stripe.com", "bob", "acme.io", "alice"] do
      :ok = RegistryCredentials.put_push_token(alice, @registry, slug, "t_#{slug}", "member")
    end

    assert {:ok, entries} = RegistryCredentials.list(alice, @registry)
    assert Enum.map(entries, & &1.namespace) == ["alice", "bob", "acme.io", "stripe.com"]
  end

  test "delete removes one slot, is idempotent, and touches no one else's", %{
    alice: alice,
    bob: bob
  } do
    :ok = RegistryCredentials.put_push_token(alice, @registry, "alice", "a", "personal")
    :ok = RegistryCredentials.put_push_token(alice, @registry, "stripe.com", "s", "member")
    :ok = RegistryCredentials.put_push_token(bob, @registry, "alice", "b", "personal")

    assert :ok = RegistryCredentials.delete(alice, @registry, "alice")
    assert :ok = RegistryCredentials.delete(alice, @registry, "alice")
    assert {:error, :not_found} = RegistryCredentials.get(alice, @registry, "alice")
    assert {:ok, %{token: "s"}} = RegistryCredentials.get(alice, @registry, "stripe.com")
    assert {:ok, %{token: "b"}} = RegistryCredentials.get(bob, @registry, "alice")
  end

  @tag :capture_log
  test "a store that cannot answer is unavailable, never absent or empty", %{alice: alice} do
    :ok = RegistryCredentials.put_push_token(alice, @registry, "alice", "a", "personal")
    outage!()

    assert {:error, :unavailable} = RegistryCredentials.get(alice, @registry, "alice")
    assert {:error, :unavailable} = RegistryCredentials.list(alice, @registry)
    assert {:error, :unavailable} = RegistryCredentials.delete(alice, @registry, "alice")

    assert {:error, :unavailable} =
             RegistryCredentials.put_push_token(alice, @registry, "alice", "a2", "personal")
  end

  test "a context that names no person is refused before any read or write", %{alice: alice} do
    nobody = %{alice | user_id: nil}

    assert {:error, :forbidden} = RegistryCredentials.get(nobody, @registry, "alice")
    assert {:error, :forbidden} = RegistryCredentials.list(nobody, @registry)
    assert {:error, :forbidden} = RegistryCredentials.delete(nobody, @registry, "alice")

    assert {:error, :forbidden} =
             RegistryCredentials.put_push_token(nobody, @registry, "alice", "a", "personal")
  end
end
