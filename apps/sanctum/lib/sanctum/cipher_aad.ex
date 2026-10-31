# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.CipherAAD do
  @moduledoc """
  Single builder for the at-rest cipher's additional-authenticated-data (AAD)
  tuple.

  `Sanctum.Cipher` binds this map as AES-GCM AAD. Encrypt-time,
  decrypt-time, and the operator-run re-encryption tool MUST produce a
  byte-identical tuple for a given row, or decryption fails closed. Defining
  the per-purpose shape in exactly one place removes the risk of those sites
  drifting apart.

  The `athanor` frame is the owning athanor's id, bound through unchanged.
  Fields a purpose does not carry are omitted; the cipher frames a missing
  field as an empty string. A purpose that belongs to a person rather than
  an athanor fills the `user` frame instead.
  """

  @doc """
  AAD for a vault entry's sealed payload (`:vault_entry` purpose).

  Bound to the entry id and provider hint — both immutable per row, which
  is what makes `provider_hint` immutable. Everything else about an entry
  (endpoints, scopes, field schema) lives outside the envelope and is
  covered by the derived binding digest instead.

  The `user` frame is explicit and empty: vault entries are the one purpose
  specified to carry it from day one, so per-user credentials can later fill
  it without re-entering every credential.
  """
  @spec vault_entry(String.t(), String.t(), String.t()) :: map()
  def vault_entry(athanor_id, entry_id, provider_hint) do
    %{
      purpose: :vault_entry,
      athanor: athanor_id,
      name: entry_id,
      sub: provider_hint,
      user: ""
    }
  end

  @doc """
  AAD for an OAuth provider client-credential blob
  (`:oauth_provider_credential` purpose).

  One row per `(athanor, provider)`; the provider name is the manifest
  oauth-block key and part of the unique storage key, so everything bound
  here is immutable per row.
  """
  @spec provider_credential(String.t(), String.t()) :: map()
  def provider_credential(athanor_id, provider) do
    %{
      purpose: :oauth_provider_credential,
      athanor: athanor_id,
      name: provider
    }
  end

  @doc """
  AAD for a registry push token (`:registry_token` purpose).

  A platform-plane store — tokens belong to users, not athanors — so the
  athanor frame is omitted and the whole storage key binds directly:
  the registry as `name`, the namespace slug as `sub`, and the owning
  user in the `user` frame (this is a per-user credential, which is what
  that frame exists for). Repointing a row at another user, registry or
  namespace fails decryption.
  """
  @spec registry_token(String.t(), String.t(), String.t()) :: map()
  def registry_token(user_id, registry, namespace_slug) do
    %{
      purpose: :registry_token,
      name: registry,
      sub: namespace_slug,
      user: user_id
    }
  end

  @doc """
  AAD for a webhook HMAC secret (`:webhook_secret` purpose).

  Symmetric whether built from the writing context or rebuilt from the stored
  row — both pass the athanor id and the webhook name.
  """
  @spec webhook_secret(String.t(), String.t()) :: map()
  def webhook_secret(athanor_id, name) do
    %{
      purpose: :webhook_secret,
      athanor: athanor_id,
      name: name
    }
  end

  @typedoc "Which of a person's private keys a sealed value holds."
  @type person_key_role :: :live | :operational | :kit_seed

  @doc """
  AAD for one of a person's private keys (`:person_key` purpose): the live
  key, the operational key, or a recovery kit's seed awaiting delivery.

  A person's keys are theirs, not an athanor's, so the athanor frame is
  omitted and the `user` frame binds the person; `name` binds the role, so
  a key sealed as the live key never opens as the operational key or as a
  seed.

  `user_frame` is the person's `user_id`, on their identity row and on
  their enrollment and rotation attempts. A restore attempt stages its keys
  before any person exists, so its frame is `"restore:" <> request_id` for
  the attempt's whole life, even once the restore has minted the person.
  The frame binds the person and the role, never the row: a rotation's
  staged live key moves onto the identity row as a byte copy.
  """
  @spec person_key(String.t(), person_key_role()) :: map()
  def person_key(user_frame, role)
      when is_binary(user_frame) and user_frame != "" and
             role in [:live, :operational, :kit_seed] do
    %{
      purpose: :person_key,
      user: user_frame,
      name: Atom.to_string(role)
    }
  end
end
