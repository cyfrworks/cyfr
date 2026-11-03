# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.DeviceUnlockTest do
  @moduledoc """
  The protected device's proof purposes as data
  (`tests/fixtures/device_unlock.json`): each purpose takes exactly its
  fields; the four worked proofs are the device key's signatures over
  their exact challenges and read back to their bytes; every proof is held
  to the challenge the home holds (none, once consumed) at its time, to
  its result; a lock proof needs no clock and the fresh verifier never
  takes one; and the storage words of the capability report read to their
  report or are refused as contradictory.
  """

  use ExUnit.Case, async: true

  alias Prima.DeviceCert.{Challenge, Proof, Storage}
  alias Prima.Identity.Encoding

  @vectors Path.expand("../../../../tests/fixtures/device_unlock.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp unb64(value) do
    {:ok, bytes} = Base.url_decode64(value, padding: false)
    bytes
  end

  defp private(name), do: unb64(vectors()["keys"][name]["seed"])

  defp raw_signature(map, private_key) do
    {:ok, message} = Prima.JCS.encode(Map.delete(map, "sig"))

    Base.url_encode64(:crypto.sign(:eddsa, :none, message, [private_key, :ed25519]),
      padding: false
    )
  end

  defp tag({:error, reason}), do: tag(reason)
  defp tag({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp tag(reason) when is_atom(reason), do: Atom.to_string(reason)

  test "the protocol, the field lists and the sizes are the implementation's" do
    v = vectors()
    common = v["common_fields"]
    assert v["protocol"] == Challenge.protocol()
    assert common["lifetime_ms"] == Challenge.lifetime_ms()
    assert common["nonce_bytes"] == Challenge.nonce_bytes()
    assert common["key_bytes"] == Encoding.key_bytes()

    for {name, %{"fresh" => fresh, "fields" => fields}} <- v["purpose_fields"] do
      purpose = String.to_existing_atom(name)
      assert purpose in Challenge.purposes(), name
      assert Challenge.fresh?(purpose) == fresh, name
      assert Enum.map(Challenge.purpose_fields(purpose), &Atom.to_string/1) == fields, name

      expected =
        common["binding"] ++ if(fresh, do: common["freshness"], else: []) ++ fields

      assert Enum.sort(Map.keys(Map.delete(v["proofs"][name], "sig"))) == Enum.sort(expected),
             name
    end

    assert v["purpose_fields"]["enroll"]["admissions"] == [
             "setup",
             "restore",
             "invitation",
             "open"
           ]
  end

  test "every public key derives from its seed" do
    for {name, %{"seed" => seed, "public" => public}} <- vectors()["keys"] do
      {derived, _private} = :crypto.generate_key(:eddsa, :ed25519, unb64(seed))
      assert Encoding.b64(derived) == public, name
    end
  end

  test "every worked proof is device_1's signature over its exact challenge and reads back" do
    v = vectors()

    for {name, proof} <- v["proofs"] do
      assert proof["sig"] == raw_signature(proof, private("device_1")), name
      assert byte_size(unb64(proof["sig"])) == v["common_fields"]["signature_bytes"]
      assert {:ok, decoded} = Proof.decode(proof), name
      assert Proof.encode(decoded) == proof, name
      assert decoded.challenge.purpose == String.to_existing_atom(name)

      assert Proof.encode(Proof.sign(decoded.challenge, private("device_1"))) == proof, name
    end
  end

  test "new/1 builds each worked challenge, a confirmation's capped by its record" do
    v = vectors()
    now = 1_790_000_000_000

    for {name, proof} <- v["proofs"] do
      challenge = Map.delete(proof, "sig")

      attrs =
        [
          purpose: String.to_existing_atom(name),
          home: challenge["home"],
          athanor: challenge["athanor"],
          client_id: challenge["client_id"],
          device_key: unb64(challenge["device_key"]),
          now: now,
          nonce: challenge["nonce"] && unb64(challenge["nonce"])
        ] ++
          for field <- v["purpose_fields"][name]["fields"],
              do: {String.to_existing_atom(field), challenge[field]}

      assert {:ok, built} = Challenge.new(attrs), name
      assert Challenge.encode(built) == challenge, name
    end

    confirm = Map.delete(v["proofs"]["confirm"], "sig")

    {:ok, capped} =
      Challenge.new(
        purpose: :confirm,
        home: confirm["home"],
        athanor: confirm["athanor"],
        client_id: confirm["client_id"],
        device_key: unb64(confirm["device_key"]),
        nonce: unb64(confirm["nonce"]),
        now: now,
        not_after: now + 10_000,
        ref: confirm["ref"],
        digest: confirm["digest"]
      )

    assert capped.expires_at == now + 10_000
  end

  test "every proof is held to the challenge the home holds, to its result" do
    for %{"name" => name, "held" => held, "proof" => proof} = vector <- vectors()["verify"] do
      held =
        case held do
          nil ->
            nil

          map ->
            {:ok, challenge} = Challenge.decode(map)
            challenge
        end

      result =
        case vector do
          %{"now" => now} -> Proof.verify(proof, held, now)
          _no_clock -> Proof.verify_lock(proof, held)
        end

      case vector do
        %{"result" => "ok"} ->
          assert result == :ok, name

        %{"error" => "challenge_mismatch", "field" => field} ->
          assert result == {:error, {:challenge_mismatch, String.to_existing_atom(field)}}, name

        %{"error" => error} ->
          assert tag(result) == error, name
      end
    end
  end

  test "a held lock challenge never passes the fresh verifier, nor a fresh one the lock verifier" do
    v = vectors()
    {:ok, lock} = Challenge.decode(Map.delete(v["proofs"]["lock"], "sig"))
    {:ok, unlock} = Challenge.decode(Map.delete(v["proofs"]["unlock"], "sig"))

    assert Proof.verify(v["proofs"]["lock"], lock, 0) == {:error, :wrong_purpose}
    assert Proof.verify_lock(v["proofs"]["unlock"], unlock) == {:error, :wrong_purpose}
    assert Proof.verify_lock(v["proofs"]["lock"], nil) == {:error, :no_challenge}
  end

  test "the storage words read to their report, two for one volume refused" do
    v = vectors()["exchange"]["capabilities"]
    words = Storage.words()
    assert v["root"] == words.root
    assert v["data"] == words.data

    for %{"capabilities" => names} = vector <- v["cases"] do
      case vector do
        %{"storage" => %{"root" => root, "data" => data}} ->
          assert Storage.read(names) ==
                   {:ok,
                    %{root: String.to_existing_atom(root), data: String.to_existing_atom(data)}},
                 inspect(names)

        %{"error" => "contradictory"} ->
          assert Storage.read(names) == {:error, :contradictory}, inspect(names)
      end
    end
  end

  test "the exchange's sizes are the challenge's" do
    exchange = vectors()["exchange"]
    assert exchange["ticket_bytes"] == Challenge.nonce_bytes()
    assert exchange["ticket_lifetime_ms"] == Challenge.lifetime_ms()
    assert exchange["session_lifetime_ms"] == Challenge.lifetime_ms()
    assert exchange["refresh_interval_ms"] * 2 == exchange["session_lifetime_ms"]

    assert exchange["http"]["unlock_complete"]["get"] ==
             exchange["http"]["unlock_complete"]["post"]
  end
end
