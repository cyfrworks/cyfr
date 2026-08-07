# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.Source do
  @moduledoc """
  Where profiles and consent revisions are read from.

  The loader (`Sanctum.Consent.Loader`) is pure decision logic; this
  behaviour is its only view of persistence. The database adapter is the
  production source; `Sanctum.Consent.Source.Memory` serves tests, so the
  loader's fail-closed rules are provable without a schema.

  A consent arrives fully decoded: the adapter owns JSON/binary decoding,
  the loader never parses storage formats other than the resolved policy
  blob itself (which stays a string because `Sanctum.Authority.Blob.parse/1`
  is the single fail-closed entry for it).
  """

  alias Sanctum.Authority.RootSelect
  alias Sanctum.Context

  @typedoc """
  One immutable consent revision, §2.5-shaped.

  `vault_refs` carries the derived reverse-index rows for the revision —
  the loader's blob/refs equality check needs both sides, and delivering
  them together keeps the check atomic with the read.
  """
  @type consent :: %{
          required(:id) => String.t(),
          required(:revision) => non_neg_integer(),
          required(:scope) => Sanctum.Consent.scope(),
          required(:pinned_version) => String.t(),
          required(:invoke_mode) => Sanctum.Consent.invoke_mode(),
          required(:shape_digest) => String.t(),
          required(:commit_digest) => String.t(),
          required(:resolved_policy) => String.t(),
          required(:activation) => %{String.t() => String.t()},
          required(:vault_refs) => [
            %{vault_entry_id: String.t(), binding_digest: String.t()}
          ]
        }

  @doc "Candidate profiles for a name-level source ref within the caller's tenant."
  @callback profiles(Context.t(), source_ref :: String.t()) ::
              {:ok, [RootSelect.profile_summary()]} | {:error, term()}

  @doc "The head consent revision of a profile, fully decoded."
  @callback head_consent(Context.t(), profile_id :: String.t()) ::
              {:ok, consent()} | {:error, :not_found | :no_head | term()}

  @doc """
  The configured source adapter.

  Defaults to the Memory adapter until the database adapter exists — no
  production ingress consults consent yet, so the default only ever serves
  tests.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:cyfr, :consent_source, Sanctum.Consent.Source.Memory)
end
