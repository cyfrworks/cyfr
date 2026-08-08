# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.CipherAAD do
  @moduledoc """
  Single builder for the at-rest cipher's additional-authenticated-data (AAD)
  tuple.

  The configured `Sanctum.Cipher` binds this map as AES-GCM AAD. Encrypt-time,
  decrypt-time, and the operator-run re-encryption tool MUST produce a
  byte-identical tuple for a given row, or decryption fails closed. Defining
  the per-purpose shape in exactly one place removes the risk of those sites
  drifting apart.

  `org`/`project` are normalized through `Arca.QueryHelpers` exactly as the
  storage layer partitions them, so the binding reconstructs identically
  regardless of nil/"" sentinel variance. Fields a purpose does not carry are
  omitted; the cipher frames a missing field as an empty string.

  Callers pass `scope` already stringified (the storage partition value), so
  it is bound through unchanged.
  """

  alias Arca.QueryHelpers

  @doc """
  AAD for a secret row (`:secret` purpose).
  """
  @spec secret(String.t(), String.t() | nil, String.t() | nil, String.t()) :: map()
  def secret(scope, org_id, project_id, name) do
    %{
      purpose: :secret,
      scope: scope,
      org: QueryHelpers.normalize_org_id(org_id),
      project: QueryHelpers.normalize_project_id(project_id),
      name: name
    }
  end


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
  @spec vault_entry(String.t() | nil, String.t() | nil, String.t(), String.t()) :: map()
  def vault_entry(org_id, project_id, entry_id, provider_hint) do
    %{
      purpose: :vault_entry,
      org: QueryHelpers.normalize_org_id(org_id),
      project: QueryHelpers.normalize_project_id(project_id),
      name: entry_id,
      sub: provider_hint,
      user: ""
    }
  end

  @doc """
  AAD for an OAuth provider client-credential blob
  (`:oauth_provider_credential` purpose).

  One row per `(org, project, provider)`; the provider name is the manifest
  oauth-block key and part of the unique storage key, so everything bound
  here is immutable per row.
  """
  @spec provider_credential(String.t() | nil, String.t() | nil, String.t()) :: map()
  def provider_credential(org_id, project_id, provider) do
    %{
      purpose: :oauth_provider_credential,
      org: QueryHelpers.normalize_org_id(org_id),
      project: QueryHelpers.normalize_project_id(project_id),
      name: provider
    }
  end

  @doc """
  AAD for a registry push token (`:registry_token` purpose).

  A platform-plane store — tokens belong to users, not tenants — so the
  tenant frames are omitted and the whole storage key binds directly:
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
  row — both pass the already-normalized partition columns.
  """
  @spec webhook_secret(String.t(), String.t() | nil, String.t() | nil, String.t()) :: map()
  def webhook_secret(scope, org_id, project_id, name) do
    %{
      purpose: :webhook_secret,
      scope: scope,
      org: QueryHelpers.normalize_org_id(org_id),
      project: QueryHelpers.normalize_project_id(project_id),
      name: name
    }
  end
end
