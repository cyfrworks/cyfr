# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Cipher do
  @moduledoc """
  At-rest encryption of tenant-scoped credential blobs (secrets, OAuth token
  bundles, webhook HMAC secrets, identity-link tokens): versioned, AAD-bound,
  keyring-rotatable AES-256-GCM.

  The keyring (`:crypto_keyring`) is set at boot in `config/runtime.exs` —
  explicit via `CYFR_CRYPTO_KEYRING`, or derived from `:secret_key_base` when
  that env var is absent (single-operator installs work zero-config).

  ## Envelope (v2, big-endian)

      version(1)=0x02 | key_label_len(1) | key_label(L) | iv(12) | tag(16) | ct

  Minimum 31 bytes (empty ciphertext, 1-byte label). A non-`0x02` first byte
  fails closed. CYFR is greenfield with respect to this envelope; the wire
  format has no backward-compatibility tail.

  ## Tenant binding (AAD)

  `aad_ctx` carries `:purpose` plus the caller's canonical tenant key fields —
  `org`/`project` already normalized via `Arca.QueryHelpers`, `scope` as the
  raw `to_string(ctx.scope)`, the logical row `name`, and an optional `sub`
  discriminator (e.g. the OAuth provider). This tuple is bound as AES-GCM
  additional authenticated data using length-prefixed framing (collision-safe
  — `("a","bc")` cannot frame-collide with `("ab","c")`). The version byte and
  key label are bound too, so the otherwise-plaintext envelope header is
  tamper-evident. A row copied to another tenant fails the GCM tag check on
  decrypt. `Sanctum.CipherAAD` provides the canonical `aad_ctx` builders for
  each purpose.

  ## Keyring & rotation

  `config :cyfr, :crypto_keyring` is `%{primary: label, keys: %{label =>
  master_binary}}` (parsed/validated at boot in `runtime.exs`). Encryption
  always uses `primary`; decryption selects the key by the label embedded in
  the envelope, so retired keys keep decrypting until a re-encryption pass
  (`Sanctum.Cipher.Rotation`) moves every row onto the new primary. The GCM key
  is `PBKDF2-HMAC-SHA256(master, "cyfr-cipher-v1|<purpose>")` so a key for one
  purpose can never decrypt another purpose's blob; derived keys are memoized
  in `:persistent_term` (the keyring is boot-immutable).
  """

  @typedoc """
  AAD binding context. `:purpose` is required; the remaining keys are the
  caller's canonical tenant partition fields (see moduledoc).
  """
  @type aad_ctx :: %{required(:purpose) => atom(), optional(atom()) => term()}

  @version 0x02
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
    aad = build_aad(label, ctx)

    {ct, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, @tag_size, true)

    {:ok,
     <<@version::8, byte_size(label)::8, label::binary, iv::binary, tag::binary, ct::binary>>}
  end

  @spec decrypt(binary(), aad_ctx()) :: {:ok, binary()} | {:error, term()}
  def decrypt(<<@version::8, llen::8, rest::binary>>, %{purpose: purpose} = ctx)
      when byte_size(rest) >= llen + @iv_size + @tag_size do
    <<label::binary-size(llen), iv::binary-size(@iv_size), tag::binary-size(@tag_size),
      ct::binary>> = rest

    case Map.fetch(keyring().keys, label) do
      :error ->
        {:error, {:decrypt, {:unknown_key_label, label}}}

      {:ok, master} ->
        key = derive_key(label, purpose, master)
        aad = build_aad(label, ctx)

        case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ct, aad, tag, false) do
          plaintext when is_binary(plaintext) -> {:ok, plaintext}
          :error -> {:error, {:decrypt, :aad_or_key_mismatch}}
        end
    end
  end

  def decrypt(<<@version::8, _::binary>>, _ctx), do: {:error, {:decrypt, :truncated}}
  def decrypt(bin, _ctx) when is_binary(bin), do: {:error, {:decrypt, :unknown_version}}
  def decrypt(_, _ctx), do: {:error, {:decrypt, :invalid_input}}

  @doc """
  Extract the key label from a v2 envelope without decrypting.

  Single source of truth for the envelope layout, used by
  `Sanctum.Cipher.Rotation` to decide whether a row is already on the primary
  key. Returns `:error` for anything that is not a well-formed v2 envelope
  (fail closed — the rotation tool treats that as a row to surface, never
  silently skip).
  """
  @spec label(binary()) :: {:ok, binary()} | :error
  def label(<<@version::8, llen::8, rest::binary>>) when byte_size(rest) >= llen and llen > 0 do
    <<lbl::binary-size(llen), _::binary>> = rest
    {:ok, lbl}
  end

  def label(_), do: :error

  @doc "The current primary key label (the label new writes use)."
  @spec primary_label() :: binary()
  def primary_label, do: keyring().primary

  # ============================================================================
  # Internal
  # ============================================================================

  defp keyring, do: Application.fetch_env!(:cyfr, :crypto_keyring)

  # Length-prefixed framing of the full identifying tuple. Absent fields frame
  # as "" so the AAD is well-defined and identical across encrypt/decrypt for
  # a given purpose. Version + key label are bound so the plaintext header
  # cannot be tampered with undetected.
  defp build_aad(label, %{purpose: purpose} = ctx) do
    IO.iodata_to_binary([
      "cyfrv2",
      <<@version::8>>,
      frame(label),
      frame(Atom.to_string(purpose)),
      frame(field(ctx, :scope)),
      frame(field(ctx, :org)),
      frame(field(ctx, :project)),
      frame(field(ctx, :name)),
      frame(field(ctx, :sub))
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
