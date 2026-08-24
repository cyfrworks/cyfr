# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Cipher do
  @moduledoc """
  At-rest encryption of tenant-scoped credential blobs (secrets, OAuth token
  bundles, webhook HMAC secrets, identity-link tokens): versioned, AAD-bound,
  keyring-rotatable AES-256-GCM.

  The keyring (`:crypto_keyring`) is resolved at boot by `Cyfr.Application`
  (`resolve_crypto_keyring!/0`) — explicit via `CYFR_CRYPTO_KEYRING`, or
  derived from `:secret_key_base` when that env var is absent
  (single-operator installs work zero-config).

  ## Envelope (big-endian)

      version(1) | key_label_len(1) | key_label(L) | iv(12) | tag(16) | ct

  The version byte is `0x04`; any other first byte fails closed. Minimum
  31 bytes (empty ciphertext, 1-byte label).

  ## Tenant binding (AAD)

  `aad_ctx` carries `:purpose` plus the caller's canonical tenant key fields —
  the owning `athanor` id, the logical row `name`, an optional `sub`
  discriminator (e.g. the OAuth provider), and a `user` frame, empty on vault
  entries until per-user credentials exist, so enabling them later re-keys
  nothing. This tuple is bound as AES-GCM additional authenticated data using
  length-prefixed framing (collision-safe — `("a","bc")` cannot frame-collide
  with `("ab","c")`). The version byte and key label are bound too, so the
  otherwise-plaintext envelope header is tamper-evident. A row copied to
  another athanor fails to decrypt.
  """
  @type aad_ctx :: %{required(:purpose) => atom(), optional(atom()) => term()}

  @version_v4 0x04
  @iv_size 12
  @tag_size 16
  @key_len 32
  @default_iterations 100_000

  @spec encrypt(binary(), aad_ctx()) :: {:ok, binary()}
  def encrypt(plaintext, %{purpose: purpose} = ctx) when is_binary(plaintext) do
    keyring = keyring()
    label = keyring.primary
    master = Map.fetch!(keyring.keys, label)
    key = derive_key(label, purpose, master)
    iv = :crypto.strong_rand_bytes(@iv_size)
    aad = build_aad(@version_v4, label, ctx)

    {ct, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, @tag_size, true)

    {:ok,
     <<@version_v4::8, byte_size(label)::8, label::binary, iv::binary, tag::binary, ct::binary>>}
  end

  @spec decrypt(binary(), aad_ctx()) :: {:ok, binary()} | {:error, term()}
  def decrypt(<<version::8, llen::8, rest::binary>>, %{purpose: purpose} = ctx)
      when version == @version_v4 and
             byte_size(rest) >= llen + @iv_size + @tag_size do
    <<label::binary-size(^llen), iv::binary-size(@iv_size), tag::binary-size(@tag_size),
      ct::binary>> = rest

    case Map.fetch(keyring().keys, label) do
      :error ->
        {:error, {:decrypt, {:unknown_key_label, label}}}

      {:ok, master} ->
        key = derive_key(label, purpose, master)
        aad = build_aad(version, label, ctx)

        case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ct, aad, tag, false) do
          plaintext when is_binary(plaintext) -> {:ok, plaintext}
          :error -> {:error, {:decrypt, :aad_or_key_mismatch}}
        end
    end
  end

  def decrypt(<<version::8, _::binary>>, _ctx) when version == @version_v4,
    do: {:error, {:decrypt, :truncated}}

  def decrypt(bin, _ctx) when is_binary(bin), do: {:error, {:decrypt, :unknown_version}}
  def decrypt(_, _ctx), do: {:error, {:decrypt, :invalid_input}}

  @doc """
  Extract the key label from an envelope without decrypting.

  Returns `:error` for anything that is not a well-formed envelope (fail
  closed — the rotation tool treats that as a row to surface, never silently
  skip).
  """
  @spec label(binary()) :: {:ok, binary()} | :error
  def label(bin) do
    case envelope(bin) do
      {:ok, {_version, lbl}} -> {:ok, lbl}
      :error -> :error
    end
  end

  @doc """
  Parse the envelope header without decrypting: `{:ok, {version, key_label}}`.

  Single source of truth for the header layout. `Sanctum.Cipher.Rotation`
  uses it to decide whether a row is already on the primary key.
  """
  @spec envelope(binary()) :: {:ok, {4, binary()}} | :error
  def envelope(<<version::8, llen::8, rest::binary>>)
      when version == @version_v4 and byte_size(rest) >= llen and llen > 0 do
    <<lbl::binary-size(^llen), _::binary>> = rest
    {:ok, {version, lbl}}
  end

  def envelope(_), do: :error

  @doc "The current primary key label (the label new writes use)."
  @spec primary_label() :: binary()
  def primary_label, do: keyring().primary

  @doc "The envelope version `encrypt/2` writes — the only one `decrypt/2` reads."
  @spec current_version() :: pos_integer()
  def current_version, do: @version_v4

  # ============================================================================
  # Internal
  # ============================================================================

  defp keyring, do: Application.fetch_env!(:cyfr, :crypto_keyring)

  # Length-prefixed framing of the full identifying tuple. Absent fields frame
  # as "" so the AAD is well-defined and identical across encrypt/decrypt for
  # a given purpose. Version + key label are bound so the plaintext header
  # cannot be tampered with undetected.
  defp build_aad(@version_v4, label, %{purpose: purpose} = ctx) do
    IO.iodata_to_binary([
      "cyfrv4",
      <<@version_v4::8>>,
      frame(label),
      frame(Atom.to_string(purpose)),
      frame(field(ctx, :athanor)),
      frame(field(ctx, :name)),
      frame(field(ctx, :sub)),
      frame(field(ctx, :user))
    ])
  end

  defp frame(s) when is_binary(s), do: <<byte_size(s)::32, s::binary>>

  defp field(ctx, key) do
    case Map.get(ctx, key) do
      nil -> ""
      v when is_binary(v) -> v
      v -> to_string(v)
    end
  end

  # Per-(label, purpose) key, memoized. The keyring is fixed for the VM
  # lifetime (set at boot; a rotation is an explicit redeploy), so a process-
  # global cache is safe and avoids re-running PBKDF2 on every operation.
  defp derive_key(label, purpose, master) do
    pt_key = {__MODULE__, :dk, label, purpose}

    case :persistent_term.get(pt_key, :miss) do
      {^master, dk} ->
        dk

      _ ->
        # Miss, or the same label now maps to different key material (only
        # possible across a redeploy/test reconfig — the keyring is otherwise
        # boot-immutable). Keying the memo on the master binary keeps a stale
        # derived key from ever being returned.
        # Load-bearing literal: this info string is baked into every derived
        # key, so renaming it (even to match the envelope version) orphans every
        # blob encrypted so far. Pinned by test; change only with a
        # rotate-everything migration.
        info = "cyfr-cipher-v1|" <> Atom.to_string(purpose)
        dk = :crypto.pbkdf2_hmac(:sha256, master, info, iterations(), @key_len)
        :persistent_term.put(pt_key, {master, dk})
        dk
    end
  end

  # A misconfigured (too-low) iteration count cannot weaken derivation below
  # the default floor.
  defp iterations do
    max(Application.get_env(:cyfr, :pbkdf2_iterations, @default_iterations), @default_iterations)
  end
end
