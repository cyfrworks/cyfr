# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Compendium.ReleaseDigest do
  @moduledoc """
  The activation identity of a published release: its artifact bytes bound
  to the security-relevant part of its manifest.

  The plain `digest` column hashes artifact bytes alone, so a component can
  keep its digest while its manifest declares new capabilities — the
  manifest is covered by no digest today. A release digest closes that: it
  hashes the artifact digest together with the canonicalized manifest
  blocks that decide what the component may do, so any change to declared
  capability produces a new identity.

  ## The security-relevant subset

  | Block | Why it is in |
  |---|---|
  | `dependencies` | which components this one may reach |
  | `needs` | named roles the operator satisfies with Connections |
  | `caps` | the declared capability ask the operator consents to |
  | `setup` | legacy: `setup.policy` / `setup.secrets` (rejected at registration once deleted) |
  | `oauth` | legacy: provider endpoints, scopes and credential references |
  | `wasi` | legacy: never runtime-parsed; covered while old manifests carry it |

  Everything else — description, schema, examples, tags — is presentational
  and deliberately excluded, so re-describing a release does not change its
  activation identity. Absent blocks are omitted rather than nulled, since
  the canonical domain has no null (`Sanctum.JCS`).

  Canonicalization is `Sanctum.JCS`, whose restricted domain refuses floats.
  A manifest carrying a float in one of these blocks therefore cannot be
  published — fail-closed by construction rather than by a separate check.
  """

  alias Sanctum.JCS

  # Additive first (existing rows carry neither needs nor caps, so their
  # digests are unchanged); the legacy trio leaves the subset only after
  # registration rejects it, shipped with a backfill re-run.
  @security_blocks ~w(dependencies needs caps setup oauth wasi)

  @type error :: {:invalid_manifest, JCS.error()} | {:invalid_artifact_digest, term()}

  @doc """
  The manifest keys that contribute to a release digest.
  """
  @spec security_blocks() :: [String.t()]
  def security_blocks, do: @security_blocks

  @doc """
  Compute the release digest from an artifact digest and a decoded manifest.

  `manifest` may be `nil` (many components ship without one); the subset is
  then empty and the digest still binds the artifact.

  ## Examples

      iex> {:ok, digest} = Compendium.ReleaseDigest.compute("sha256:abc", nil)
      iex> String.starts_with?(digest, "sha256:")
      true

      iex> Compendium.ReleaseDigest.compute("sha256:abc", %{"setup" => %{"policy" => %{"timeout" => 1.5}}})
      {:error, {:invalid_manifest, {:invalid_value, ["setup", "policy", "timeout"], :float_not_permitted}}}

  """
  @spec compute(String.t(), map() | nil) :: {:ok, String.t()} | {:error, error()}
  def compute(artifact_digest, manifest)

  def compute(artifact_digest, _manifest)
      when not is_binary(artifact_digest) or artifact_digest == "" do
    {:error, {:invalid_artifact_digest, artifact_digest}}
  end

  def compute(artifact_digest, nil), do: compute(artifact_digest, %{})

  def compute(artifact_digest, manifest) when is_map(manifest) do
    subset = Map.take(manifest, @security_blocks)

    case JCS.encode(subset) do
      {:ok, canonical} -> {:ok, JCS.hash_binary(artifact_digest <> canonical)}
      {:error, reason} -> {:error, {:invalid_manifest, reason}}
    end
  end

  def compute(_artifact_digest, manifest), do: {:error, {:invalid_manifest, manifest}}
end
