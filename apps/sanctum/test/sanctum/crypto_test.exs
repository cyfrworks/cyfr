defmodule Sanctum.CryptoTest do
  use ExUnit.Case, async: true

  alias Sanctum.Crypto

  describe "encryption_key/0" do
    test "returns ok tuple with 32-byte key" do
      assert {:ok, key} = Crypto.encryption_key()
      assert byte_size(key) == 32
    end

    test "returns same key on multiple calls" do
      {:ok, key1} = Crypto.encryption_key()
      {:ok, key2} = Crypto.encryption_key()
      assert key1 == key2
    end

    test "uses PBKDF2 for key derivation (different salt = different key)" do
      {:ok, key1} = Crypto.encryption_key(salt: "salt_a")
      {:ok, key2} = Crypto.encryption_key(salt: "salt_b")

      # Different salts should produce different keys
      assert key1 != key2
      assert byte_size(key1) == 32
      assert byte_size(key2) == 32
    end

    test "same salt produces same key" do
      {:ok, key1} = Crypto.encryption_key(salt: "consistent_salt")
      {:ok, key2} = Crypto.encryption_key(salt: "consistent_salt")

      assert key1 == key2
    end
  end

  describe "encrypt/1 and decrypt/1" do
    test "encrypts and decrypts plaintext successfully" do
      plaintext = "hello, world!"

      assert {:ok, encrypted} = Crypto.encrypt(plaintext)
      assert is_binary(encrypted)
      assert encrypted != plaintext

      assert {:ok, decrypted} = Crypto.decrypt(encrypted)
      assert decrypted == plaintext
    end

    test "encrypts empty string" do
      assert {:ok, encrypted} = Crypto.encrypt("")
      # Empty plaintext still has IV + tag overhead
      assert {:ok, decrypted} = Crypto.decrypt(encrypted)
      assert decrypted == ""
    end

    test "encrypts unicode content" do
      plaintext = "Hello, "

      assert {:ok, encrypted} = Crypto.encrypt(plaintext)
      assert {:ok, decrypted} = Crypto.decrypt(encrypted)
      assert decrypted == plaintext
    end

    test "encrypts JSON data" do
      json = ~s({"name":"test","value":123})

      assert {:ok, encrypted} = Crypto.encrypt(json)
      assert {:ok, decrypted} = Crypto.decrypt(encrypted)
      assert decrypted == json
    end

    test "produces different ciphertext for same plaintext (random IV)" do
      plaintext = "same data"

      {:ok, encrypted1} = Crypto.encrypt(plaintext)
      {:ok, encrypted2} = Crypto.encrypt(plaintext)

      # Different IVs means different ciphertext
      assert encrypted1 != encrypted2

      # But both decrypt to same plaintext
      {:ok, decrypted1} = Crypto.decrypt(encrypted1)
      {:ok, decrypted2} = Crypto.decrypt(encrypted2)
      assert decrypted1 == plaintext
      assert decrypted2 == plaintext
    end
  end

  describe "decrypt/1 error handling" do
    test "returns error for data too short" do
      # Less than IV + tag size (32 bytes minimum)
      short_data = :crypto.strong_rand_bytes(31)

      assert {:error, {:decryption_failed, :data_too_short}} = Crypto.decrypt(short_data)
    end

    test "returns error for corrupted ciphertext" do
      {:ok, encrypted} = Crypto.encrypt("test data")

      # Corrupt the ciphertext by flipping bits
      <<head::binary-size(20), _::binary-size(5), tail::binary>> = encrypted
      corrupted = head <> :crypto.strong_rand_bytes(5) <> tail

      assert {:error, {:decryption_failed, :key_mismatch_possible}} = Crypto.decrypt(corrupted)
    end

    test "returns error for non-binary input" do
      assert {:error, {:decryption_failed, :invalid_input}} = Crypto.decrypt(nil)
      assert {:error, {:decryption_failed, :invalid_input}} = Crypto.decrypt(123)
      assert {:error, {:decryption_failed, :invalid_input}} = Crypto.decrypt([])
    end
  end

  describe "encryption_key!/0" do
    test "returns key directly" do
      key = Crypto.encryption_key!()
      assert is_binary(key)
      assert byte_size(key) == 32
    end

    test "accepts salt option" do
      key = Crypto.encryption_key!(salt: "custom_salt")
      assert is_binary(key)
      assert byte_size(key) == 32
    end
  end

  describe "encrypt/decrypt with salt" do
    test "encrypts and decrypts with matching salt" do
      plaintext = "user-specific secret"
      salt = "user_123_salt"

      {:ok, encrypted} = Crypto.encrypt(plaintext, salt: salt)
      {:ok, decrypted} = Crypto.decrypt(encrypted, salt: salt)

      assert decrypted == plaintext
    end

    test "decryption fails with wrong salt" do
      plaintext = "user-specific secret"

      {:ok, encrypted} = Crypto.encrypt(plaintext, salt: "salt_a")
      result = Crypto.decrypt(encrypted, salt: "salt_b")

      assert {:error, {:decryption_failed, :key_mismatch_possible}} = result
    end
  end
end
