# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.Proof do
  @moduledoc """
  Single-use authorization bound to one exact set of consent decisions.

  A consent commit must prove that *this* commit — this commit digest, this
  profile, this actor, this expected revision — is the one that was
  authorized. A permission cannot express that: it says who you are, not
  what you approved, and `:*` satisfies every permission check there is.

  So authorization is a token minted server-side at preview time, carrying
  the bindings, and consumed exactly once at commit. Change any decision
  between preview and commit and the digest no longer matches; replay the
  token and it is already gone.

  **It is a token, not a human-presence assertion.** Any code holding the
  interactive session can walk plan → preview → commit unattended. Genuine
  presence, where it is wanted, is a separate step
  (`Sanctum.Auth.DeviceFlow`, `Sanctum.Auth.EmailVerification`).

  ## Consumption is unconditional

  A token is taken from the store *before* its bindings are checked, so a
  mismatched attempt burns it. That is deliberate: it makes a token
  unusable for probing which binding was wrong, and the caller's remedy —
  re-preview to see the current digest — is the right one anyway.

  The shipped store is `Sanctum.Consent.Proof.DB` (single-use rows keyed
  by token hash); `Sanctum.Consent.Proof.Memory` is the node-local
  alternative tests pin explicitly.
  """

  @type token :: String.t()

  @type bindings :: %{
          required(:kind) => atom(),
          required(:commit_digest) => String.t(),
          optional(:actor) => String.t(),
          optional(:org_id) => String.t(),
          optional(:project_id) => String.t(),
          optional(:profile_id) => String.t(),
          optional(:expected_revision) => non_neg_integer()
        }

  @type consume_error ::
          :not_found | :expired | {:binding_mismatch, atom()} | {:invalid_bindings, atom()}

  @doc "Mint a single-use proof for a set of bindings."
  @callback mint(bindings(), ttl_ms :: pos_integer()) :: {:ok, token()} | {:error, term()}

  @doc "Consume a proof, verifying it was minted for exactly these bindings."
  @callback consume(token(), bindings()) :: :ok | {:error, consume_error()}

  # Two minutes: long enough for an operator to read a consent sheet and
  # click, short enough that a leaked token is near-worthless. Mirrors the
  # OAuth pending-state TTL.
  @default_ttl_ms 120_000

  @required_bindings [:kind, :commit_digest]

  @doc "The default proof time-to-live in milliseconds."
  @spec default_ttl_ms() :: pos_integer()
  def default_ttl_ms, do: @default_ttl_ms

  @doc """
  Mint a proof through the configured store.
  """
  @spec mint(bindings(), keyword()) :: {:ok, token()} | {:error, term()}
  def mint(bindings, opts \\ []) do
    with :ok <- validate_bindings(bindings) do
      store().mint(bindings, Keyword.get(opts, :ttl_ms, @default_ttl_ms))
    end
  end

  @doc """
  Consume a proof through the configured store.
  """
  @spec consume(token(), bindings()) :: :ok | {:error, consume_error()}
  def consume(token, bindings) when is_binary(token) do
    with :ok <- validate_bindings(bindings) do
      store().consume(token, bindings)
    end
  end

  def consume(_token, _bindings), do: {:error, {:invalid_bindings, :token}}

  @doc """
  Compare two binding sets, returning the first field that differs.

  Shared by every store implementation so "what counts as the same
  authorization" is defined once. The digest comparison is constant-time —
  a proof consumer is an oracle otherwise.
  """
  @spec compare(bindings(), bindings()) :: :ok | {:error, {:binding_mismatch, atom()}}
  def compare(minted, presented) do
    digests_match? =
      Plug.Crypto.secure_compare(
        to_string(minted[:commit_digest]),
        to_string(presented[:commit_digest])
      )

    cond do
      not digests_match? ->
        {:error, {:binding_mismatch, :commit_digest}}

      true ->
        case Enum.find(binding_keys(minted, presented), &(minted[&1] != presented[&1])) do
          nil -> :ok
          field -> {:error, {:binding_mismatch, field}}
        end
    end
  end

  defp binding_keys(minted, presented) do
    (Map.keys(minted) ++ Map.keys(presented))
    |> Enum.uniq()
    |> List.delete(:commit_digest)
  end

  defp validate_bindings(bindings) when is_map(bindings) do
    case Enum.find(
           @required_bindings,
           &(is_nil(Map.get(bindings, &1)) or Map.get(bindings, &1) == "")
         ) do
      nil -> :ok
      missing -> {:error, {:invalid_bindings, missing}}
    end
  end

  defp validate_bindings(_bindings), do: {:error, {:invalid_bindings, :bindings}}

  # The in-code default matches the shipped config (config.exs): proofs are
  # single-use REPLAY protection, so an unset key must not silently downgrade
  # to a node-local in-memory store. Tests override to Memory explicitly.
  defp store, do: Application.get_env(:cyfr, :consent_proof_store, __MODULE__.DB)
end
