# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.ProofDBTest do
  use ExUnit.Case, async: false

  alias Sanctum.Consent.Proof

  @digest "sha256:" <> String.duplicate("ab", 32)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp bindings(over \\ %{}) do
    Map.merge(
      %{
        kind: :consent_commit,
        commit_digest: @digest,
        actor: "user_1",
        org_id: "local",
        project_id: "default",
        profile_id: "prof_1",
        expected_revision: 3
      },
      over
    )
  end

  defp mint!(b \\ bindings(), opts \\ []) do
    {:ok, token} = Sanctum.Consent.Proof.DB.mint(b, Keyword.get(opts, :ttl_ms, 120_000))
    token
  end

  describe "mint + consume" do
    test "a proof consumes exactly once for its exact bindings" do
      token = mint!()

      assert :ok = Sanctum.Consent.Proof.DB.consume(token, bindings())
      assert {:error, :not_found} = Sanctum.Consent.Proof.DB.consume(token, bindings())
    end

    test "the token itself is never stored — only its hash" do
      token = mint!()

      hashes = Arca.Repo.all(Arca.Schemas.ConsentProof) |> Enum.map(& &1.token_hash)
      expected_hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
      refute token in hashes
      assert expected_hash in hashes
    end

    test "a wrong digest is rejected AND burns the token" do
      token = mint!()
      wrong = bindings(%{commit_digest: "sha256:" <> String.duplicate("cd", 32)})

      assert {:error, {:binding_mismatch, :commit_digest}} =
               Sanctum.Consent.Proof.DB.consume(token, wrong)

      # Burned: even the correct bindings cannot use it now.
      assert {:error, :not_found} = Sanctum.Consent.Proof.DB.consume(token, bindings())
    end

    test "each divergent optional binding is named" do
      for {field, value} <- [
            actor: "someone_else",
            profile_id: "prof_2",
            expected_revision: 9
          ] do
        token = mint!()

        assert {:error, {:binding_mismatch, ^field}} =
                 Sanctum.Consent.Proof.DB.consume(token, bindings(%{field => value}))
      end
    end

    test "kinds are part of the binding — a plan token is not a commit proof" do
      token = mint!(bindings(%{kind: :plan}))

      assert {:error, {:binding_mismatch, :kind}} =
               Sanctum.Consent.Proof.DB.consume(token, bindings(%{kind: :consent_commit}))
    end

    test "an expired proof is rejected and burned" do
      token = mint!(bindings(), ttl_ms: 1)
      Process.sleep(10)

      assert {:error, :expired} = Sanctum.Consent.Proof.DB.consume(token, bindings())
      assert {:error, :not_found} = Sanctum.Consent.Proof.DB.consume(token, bindings())
    end

    test "minting purges expired rows opportunistically" do
      _stale = mint!(bindings(), ttl_ms: 1)
      Process.sleep(10)
      _fresh = mint!()

      assert Arca.Repo.aggregate(Arca.Schemas.ConsentProof, :count) == 1
    end
  end

  describe "concurrency" do
    test "two concurrent consumes produce exactly one :ok" do
      token = mint!()
      parent = self()

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, parent, self())
            Sanctum.Consent.Proof.DB.consume(token, bindings())
          end)
        end

      results = Task.await_many(tasks, 5_000)

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == {:error, :not_found})) == 1
    end
  end

  describe "through the configured-store front" do
    test "Proof.mint/consume round-trips via the DB store when configured" do
      original = Application.get_env(:cyfr, :consent_proof_store)
      Application.put_env(:cyfr, :consent_proof_store, Sanctum.Consent.Proof.DB)

      on_exit(fn ->
        if original,
          do: Application.put_env(:cyfr, :consent_proof_store, original),
          else: Application.delete_env(:cyfr, :consent_proof_store)
      end)

      {:ok, token} = Proof.mint(bindings())
      assert :ok = Proof.consume(token, bindings())
      assert {:error, :not_found} = Proof.consume(token, bindings())
    end
  end
end
