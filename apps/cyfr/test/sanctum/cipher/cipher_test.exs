# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.CipherTest do
  use ExUnit.Case, async: false

  alias Sanctum.Cipher

  @k1 :crypto.strong_rand_bytes(32)
  @k2 :crypto.strong_rand_bytes(32)

  setup do
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

  defp aad(over \\ %{}) do
    Map.merge(
      %{purpose: :secret, scope: "project", org: "org_a", project: "default", name: "API_KEY"},
      over
    )
  end

  describe "T-CIPHER-RT: versioned envelope round-trip" do
    test "round-trips and emits a versioned, labeled envelope" do
      {:ok, ct} = Cipher.encrypt("sk-secret", aad())

      assert <<0x02, 2, "k1", _iv::binary-size(12), _tag::binary-size(16), _rest::binary>> = ct
      assert {:ok, "k1"} = Cipher.label(ct)
      assert {:ok, "sk-secret"} = Cipher.decrypt(ct, aad())
    end

    test "random IV — same plaintext/AAD yields distinct ciphertext, both decrypt" do
      {:ok, c1} = Cipher.encrypt("x", aad())
      {:ok, c2} = Cipher.encrypt("x", aad())
      assert c1 != c2
      assert {:ok, "x"} = Cipher.decrypt(c1, aad())
      assert {:ok, "x"} = Cipher.decrypt(c2, aad())
    end

    test "round-trips empty plaintext" do
      {:ok, ct} = Cipher.encrypt("", aad())
      assert {:ok, ""} = Cipher.decrypt(ct, aad())
    end
  end

  describe "T-CIPHER-NO-FALLBACK: clean cutoff, no headerless fallback" do
    test "a v1-shaped (headerless) blob is rejected, not decrypted" do
      assert {:error, {:decrypt, :unknown_version}} =
               Cipher.decrypt(<<0x01>> <> :crypto.strong_rand_bytes(40), aad())
    end

    test "garbage and short inputs fail closed" do
      assert {:error, {:decrypt, :unknown_version}} = Cipher.decrypt(<<0x99, 1, 2, 3>>, aad())
      assert {:error, {:decrypt, :truncated}} = Cipher.decrypt(<<0x02, 5, "ab">>, aad())
      assert {:error, {:decrypt, :invalid_input}} = Cipher.decrypt(:not_binary, aad())
    end
  end

  describe "T-AAD-MISMATCH: tenant binding" do
    setup do
      {:ok, ct} = Cipher.encrypt("payload", aad())
      %{ct: ct}
    end

    test "same AAD decrypts", %{ct: ct} do
      assert {:ok, "payload"} = Cipher.decrypt(ct, aad())
    end

    for {field, val} <- [org: "org_b", project: "other", name: "OTHER", scope: "org"] do
      test "mismatched #{field} fails closed", %{ct: ct} do
        assert {:error, {:decrypt, :aad_or_key_mismatch}} =
                 Cipher.decrypt(ct, aad(%{unquote(field) => unquote(val)}))
      end
    end

    test "a different purpose cannot decrypt (distinct derived key + AAD)", %{ct: ct} do
      assert {:error, {:decrypt, :aad_or_key_mismatch}} =
               Cipher.decrypt(ct, aad(%{purpose: :oauth_token}))
    end

    test "tampering the plaintext envelope header is detected" do
      {:ok, ct} = Cipher.encrypt("payload", aad())
      <<v, llen, rest::binary>> = ct
      # Flip the version byte — bound into the AAD, so the tag check fails.
      assert {:error, {:decrypt, :unknown_version}} =
               Cipher.decrypt(<<0x07, llen, rest::binary>>, aad())

      assert byte_size(<<v>>) == 1
    end
  end

  describe "T-KEYRING-ROT: rotation" do
    test "old-label rows still decrypt after primary moves; new writes use new primary" do
      {:ok, old} = Cipher.encrypt("under-k1", aad())

      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})

      assert {:ok, "under-k1"} = Cipher.decrypt(old, aad())
      {:ok, fresh} = Cipher.encrypt("under-k2", aad())
      assert {:ok, "k2"} = Cipher.label(fresh)
      assert {:ok, "under-k2"} = Cipher.decrypt(fresh, aad())
    end

    test "retiring a key fails closed with a distinct, actionable error" do
      {:ok, old} = Cipher.encrypt("under-k1", aad())
      put_keyring(%{primary: "k2", keys: %{"k2" => @k2}})

      assert {:error, {:decrypt, {:unknown_key_label, "k1"}}} = Cipher.decrypt(old, aad())
    end

    test "primary_label/0 reflects the configured primary" do
      assert Cipher.primary_label() == "k1"
      put_keyring(%{primary: "k2", keys: %{"k1" => @k1, "k2" => @k2}})
      assert Cipher.primary_label() == "k2"
    end
  end
end
