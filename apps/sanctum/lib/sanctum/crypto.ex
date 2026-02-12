defmodule Sanctum.Crypto do
  @moduledoc """
  Shared cryptographic utilities for CYFR.

  Provides centralized encryption key management. Requires `secret_key_base`
  to be configured in all environments (set via `CYFR_SECRET_KEY_BASE` env var
  or directly in config).

  ## Key Derivation

  Uses PBKDF2-HMAC-SHA256 with configurable iterations (default 100,000) for
  key derivation. The iteration count can be configured via
  `CYFR_PBKDF2_ITERATIONS` environment variable.

  ## Usage

      # Get encryption key for AES-256
      {:ok, key} = Sanctum.Crypto.encryption_key()

      # Get encryption key with custom salt (for per-user encryption)
      {:ok, key} = Sanctum.Crypto.encryption_key(salt: user_salt)

      # Encrypt data
      {:ok, encrypted} = Sanctum.Crypto.encrypt(plaintext)

      # Decrypt data
      {:ok, decrypted} = Sanctum.Crypto.decrypt(encrypted)

  """

  require Logger

  # AES-256-GCM constants
  @iv_size 16
  @tag_size 16

  # PBKDF2 constants
  @default_iterations 100_000
  @key_length 32
  # WARNING: This salt MUST match the salt in Sanctum.Secrets
  # for encryption interoperability. Changing this will break decryption of existing data.
  @default_salt "cyfr_default_salt_v1"

  @doc """
  Get the encryption salt (authoritative source for cross-module compatibility).

  Other modules should call this function instead of duplicating the salt constant.
  """
  @spec encryption_salt() :: String.t()
  def encryption_salt, do: @default_salt

  @doc """
  Get the encryption key derived from the configured secret key base.

  Uses PBKDF2-HMAC-SHA256 with 100,000 iterations by default.

  ## Options

    * `:salt` - Custom salt for key derivation (for per-user encryption).
      Defaults to a static salt for global encryption.

  Returns `{:ok, key}` or `{:error, reason}`.
  """
  @spec encryption_key(keyword()) :: {:ok, binary()} | {:error, term()}
  def encryption_key(opts \\ []) do
    salt = Keyword.get(opts, :salt, @default_salt)

    case get_key_base() do
      {:ok, key_base} ->
        {:ok, derive_key(key_base, salt)}

      {:error, _} = error ->
        error
    end
  end

  defp derive_key(key_base, salt) do
    iterations = get_iterations()
    salt_binary = if is_binary(salt), do: salt, else: to_string(salt)

    :crypto.pbkdf2_hmac(:sha256, key_base, salt_binary, iterations, @key_length)
  end

  defp get_iterations do
    Application.get_env(:sanctum, :pbkdf2_iterations, @default_iterations)
  end

  @doc """
  Get the encryption key, raising on failure.
  """
  @spec encryption_key!(keyword()) :: binary()
  def encryption_key!(opts \\ []) do
    case encryption_key(opts) do
      {:ok, key} -> key
      {:error, reason} -> raise "Failed to get encryption key: #{inspect(reason)}"
    end
  end

  @doc """
  Encrypt plaintext using AES-256-GCM.

  ## Options

    * `:salt` - Custom salt for key derivation (for per-user encryption)

  Returns `{:ok, ciphertext}` where ciphertext includes IV and auth tag.
  """
  @spec encrypt(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def encrypt(plaintext, opts \\ [])

  def encrypt(plaintext, opts) when is_binary(plaintext) do
    case encryption_key(opts) do
      {:ok, key} ->
        iv = :crypto.strong_rand_bytes(@iv_size)

        {ciphertext, tag} =
          :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, <<>>, @tag_size, true)

        {:ok, iv <> tag <> ciphertext}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Decrypt ciphertext using AES-256-GCM.

  ## Options

    * `:salt` - Custom salt for key derivation (must match encryption salt)

  Returns `{:ok, plaintext}` or `{:error, reason}`.

  Unlike the previous implementation, this returns a specific error on failure
  rather than silently returning an empty map.
  """
  @spec decrypt(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def decrypt(encrypted, opts \\ [])

  def decrypt(encrypted, opts) when byte_size(encrypted) >= @iv_size + @tag_size do
    case encryption_key(opts) do
      {:ok, key} ->
        <<iv::binary-size(@iv_size), tag::binary-size(@tag_size), ciphertext::binary>> = encrypted

        case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, <<>>, tag, false) do
          plaintext when is_binary(plaintext) ->
            {:ok, plaintext}

          :error ->
            Logger.warning("Decryption failed - possible key mismatch or corrupted data")
            {:error, {:decryption_failed, :key_mismatch_possible}}
        end

      {:error, _} = error ->
        error
    end
  end

  def decrypt(encrypted, _opts) when is_binary(encrypted) do
    Logger.warning("Decryption failed - data too short (#{byte_size(encrypted)} bytes)")
    {:error, {:decryption_failed, :data_too_short}}
  end

  def decrypt(_, _opts) do
    {:error, {:decryption_failed, :invalid_input}}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_key_base do
    case Application.get_env(:sanctum, :secret_key_base) do
      nil ->
        {:error, :secret_key_base_not_configured}

      key when is_binary(key) and byte_size(key) >= 32 ->
        {:ok, key}

      key when is_binary(key) ->
        {:error, {:secret_key_base_too_short, byte_size(key)}}
    end
  end
end
