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
  AAD for an OAuth token bundle (`:oauth_token` purpose).

  The `oauth_credentials` table has no scope column, so the tuple carries the
  storage key (`component_ref`, `provider`) instead.
  """
  @spec oauth_token(String.t(), String.t(), String.t() | nil, String.t() | nil) :: map()
  def oauth_token(component_ref, provider, org_id, project_id) do
    %{
      purpose: :oauth_token,
      org: QueryHelpers.normalize_org_id(org_id),
      project: QueryHelpers.normalize_project_id(project_id),
      name: component_ref,
      sub: provider
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
