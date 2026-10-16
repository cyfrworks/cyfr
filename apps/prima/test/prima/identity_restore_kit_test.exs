# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.IdentityRestoreKitTest do
  @moduledoc """
  The kit proof as data (`tests/fixtures/restore_kit.json`): the seed
  derives the fixture's recovery key, the valid proof decodes and verifies
  under it, re-signing its fields reproduces its signed JCS bytes, its sig
  and its digest byte for byte, and every refused proof is refused with
  its stated reason, a decoding refusal naming its field.
  """

  use ExUnit.Case, async: true

  alias Prima.Identity
  alias Prima.Identity.{Encoding, RestoreKit}

  @vectors Path.expand("../../../../tests/fixtures/restore_kit.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp raw(text, size) do
    {:ok, bytes} = Encoding.unb64(text, size)
    bytes
  end

  defp kit(v, name) do
    %{"seed" => seed, "public" => public} = v[name]
    {raw(seed, 32), raw(public, 32)}
  end

  defp expected(%{"reason" => reason, "field" => field}),
    do: {:error, {String.to_existing_atom(reason), field}}

  defp expected(%{"reason" => reason}), do: {:error, String.to_existing_atom(reason)}

  test "the protocol and the challenge's length are the fixture's" do
    v = vectors()
    assert v["protocol"] == RestoreKit.protocol()
    assert v["challenge_bytes"] == RestoreKit.challenge_bytes()
    refute RestoreKit.protocol() == Identity.protocol()
  end

  test "each seed derives the fixture's recovery key" do
    v = vectors()

    for name <- ["kit", "other_kit"] do
      {seed, public} = kit(v, name)
      assert {:ok, {^public, _private}} = Identity.derive_recovery_key(seed)
    end
  end

  test "the valid proof decodes, verifies under the kit's key and writes back to itself" do
    v = vectors()
    {_seed, public} = kit(v, "kit")
    {_other_seed, other_public} = kit(v, "other_kit")
    %{"proof" => map, "fields" => fields} = v["valid"]

    assert {:ok, %RestoreKit{} = proof} = RestoreKit.decode(map)
    assert proof.restore_id == fields["restore_id"]
    assert proof.identifier == fields["identifier"]
    assert proof.challenge == raw(fields["challenge"], RestoreKit.challenge_bytes())
    assert RestoreKit.encode(proof) == map

    assert Identity.verify(proof, public) == :ok
    assert Identity.verify(proof, other_public) == {:error, :wrong_signer}
    assert RestoreKit.signer(proof, [other_public, public]) == {:ok, public}
    assert RestoreKit.signer(proof, [other_public]) == {:error, :wrong_signer}
    assert RestoreKit.signer(proof, []) == {:error, :wrong_signer}
  end

  test "re-signing the fields reproduces the signed JCS bytes, the sig and the digest" do
    v = vectors()
    {seed, _public} = kit(v, "kit")
    %{"proof" => map, "fields" => fields, "signed" => signed, "digest" => digest} = v["valid"]

    assert {:ok, unsigned} =
             RestoreKit.new(
               restore_id: fields["restore_id"],
               identifier: fields["identifier"],
               challenge: raw(fields["challenge"], RestoreKit.challenge_bytes())
             )

    assert unsigned.sig == nil
    refute Map.has_key?(RestoreKit.encode(unsigned), "sig")
    assert Encoding.jcs!(RestoreKit.encode(unsigned)) == signed
    assert Encoding.jcs!(Map.delete(map, "sig")) == signed

    resigned = Identity.sign(unsigned, seed)
    assert RestoreKit.encode(resigned) == map
    assert Identity.canonical(resigned) == Encoding.jcs!(map)
    assert Prima.Digest.sha256(Identity.canonical(resigned)) == digest
  end

  test "an unsigned proof is refused by its fields before it is signed" do
    challenge = :binary.copy(<<7>>, 32)
    identifier = "per_" <> String.duplicate("a", 64)

    assert {:error, {:missing_field, "challenge"}} =
             RestoreKit.new(restore_id: "rst_1", identifier: identifier)

    assert {:error, {:invalid_field, "challenge"}} =
             RestoreKit.new(restore_id: "rst_1", identifier: identifier, challenge: <<1, 2>>)

    assert {:error, {:invalid_field, "identifier"}} =
             RestoreKit.new(restore_id: "rst_1", identifier: "per_x", challenge: challenge)

    assert {:ok, %RestoreKit{}} =
             RestoreKit.new(restore_id: "rst_1", identifier: identifier, challenge: challenge)
  end

  test "every refused proof is refused with its stated reason" do
    v = vectors()
    {_seed, public} = kit(v, "kit")

    for %{"name" => name, "proof" => map, "error" => error} <- v["refused"] do
      answer =
        case RestoreKit.decode(map) do
          {:ok, proof} -> RestoreKit.signer(proof, [public])
          refused -> refused
        end

      assert answer == expected(error), name
    end

    reasons = v["refused"] |> Enum.map(& &1["error"]["reason"]) |> Enum.uniq() |> Enum.sort()

    assert reasons ==
             ~w(invalid_field missing_field unknown_field wrong_protocol wrong_signer)
  end

  test "a value that is not a map is not a proof" do
    for value <- [nil, "proof", [], %RestoreKit{restore_id: "r", identifier: "i", challenge: ""}] do
      assert RestoreKit.decode(value) == {:error, {:invalid_field, "proof"}}
    end
  end
end
