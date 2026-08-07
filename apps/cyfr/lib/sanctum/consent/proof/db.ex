# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.Proof.DB do
  @moduledoc """
  Durable proof store over `consent_proofs`.

  The plan → preview → commit walk spans human minutes and must survive a
  node restart, so proofs live in the database. The stored key is the
  sha256 of the token — reading the table cannot replay a proof — and
  consumption is `Arca.ConsentProofStorage.take/1`, whose delete count
  picks exactly one winner between concurrent commits.

  Take-before-compare is preserved from the Memory store: a mismatched
  attempt burns the token rather than revealing, over repeated tries,
  which binding was wrong. Expiry is checked on read; expired rows are
  purged opportunistically at mint.
  """

  @behaviour Sanctum.Consent.Proof

  alias Sanctum.Consent.Proof

  @token_bytes 32

  # The only binding keys a stored proof may round-trip. String→atom
  # conversion at read is restricted to this list, so a tampered bindings
  # column cannot mint atoms.
  @optional_binding_keys ~w(actor org_id project_id profile_id expected_revision)

  @impl Sanctum.Consent.Proof
  def mint(bindings, ttl_ms) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Arca.ConsentProofStorage.purge_expired(now)

    token = Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

    row = %{
      token_hash: hash(token),
      kind: Atom.to_string(bindings.kind),
      digest: bindings.commit_digest,
      bindings: encode_optional(bindings),
      org_id: Map.get(bindings, :org_id, ""),
      project_id: Map.get(bindings, :project_id, "default"),
      expires_at: DateTime.add(now, ttl_ms, :millisecond),
      inserted_at: now
    }

    case Arca.ConsentProofStorage.insert(row) do
      :ok -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Sanctum.Consent.Proof
  def consume(token, presented) do
    # Take first — same burn-on-mismatch contract as the Memory store.
    case Arca.ConsentProofStorage.take(hash(token)) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, row} ->
        if DateTime.compare(row.expires_at, DateTime.utc_now()) == :gt do
          Proof.compare(minted_bindings(row), presented)
        else
          {:error, :expired}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Encoding
  # ---------------------------------------------------------------------------

  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp encode_optional(bindings) do
    bindings
    |> Map.drop([:kind, :commit_digest])
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
    |> Jason.encode!()
  end

  defp minted_bindings(row) do
    optional =
      case Jason.decode(row.bindings) do
        {:ok, %{} = map} ->
          for {k, v} <- map, k in @optional_binding_keys, into: %{} do
            {String.to_existing_atom(k), v}
          end

        _ ->
          %{}
      end

    Map.merge(optional, %{
      kind: kind_atom(row.kind),
      commit_digest: row.digest
    })
  end

  # A kind string whose atom does not exist on this node (tampered column,
  # or a proof minted by a newer release) must fail the bindings compare,
  # never crash the consumer — the token is already burned either way.
  defp kind_atom(kind) do
    String.to_existing_atom(kind)
  rescue
    ArgumentError -> :__unknown_proof_kind__
  end
end
