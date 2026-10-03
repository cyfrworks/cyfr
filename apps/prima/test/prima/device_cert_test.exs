# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.DeviceCertTest do
  @moduledoc """
  Device certificates and the connect and renewal proof as data
  (`tests/fixtures/device_cert.json`): each certificate re-signs to its
  bytes; each is checked at a home, clock and epoch to its result, expiry
  strict and the tolerance on not-before alone; a local subject never
  passes at another home and needs no identifier; each malformed shape is
  refused; and each proof is held to the challenge held for its
  connection, so none is reused across purpose, client, home, athanor or
  device key.
  """

  use ExUnit.Case, async: true

  alias Prima.DeviceCert
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.Identity.Encoding

  @vectors Path.expand("../../../../tests/fixtures/device_cert.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp unb64(value) do
    {:ok, bytes} = Base.url_decode64(value, padding: false)
    bytes
  end

  defp private(name), do: unb64(vectors()["keys"][name]["seed"])
  defp public(name), do: unb64(vectors()["keys"][name]["public"])

  defp raw_signature(map, private_key) do
    {:ok, message} = Prima.JCS.encode(Map.delete(map, "sig"))

    Base.url_encode64(:crypto.sign(:eddsa, :none, message, [private_key, :ed25519]),
      padding: false
    )
  end

  defp tag({:error, reason}), do: tag(reason)
  defp tag({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp tag(reason) when is_atom(reason), do: Atom.to_string(reason)

  test "the protocols, lifetime and purposes are the fixture's" do
    v = vectors()
    assert v["certificate_protocol"] == DeviceCert.protocol()
    assert v["proof_protocol"] == Challenge.protocol()
    assert v["lifetime_ms"] == Challenge.lifetime_ms()
    assert v["purposes"] == Enum.map(Challenge.purposes(), &Atom.to_string/1)
    assert DeviceCert.protocol() != Challenge.protocol()
  end

  test "every public key derives from its seed" do
    for {name, %{"seed" => seed, "public" => public}} <- vectors()["keys"] do
      {derived, _private} = :crypto.generate_key(:eddsa, :ed25519, unb64(seed))
      assert Encoding.b64(derived) == public, name
    end
  end

  test "every signed certificate re-signs to its bytes, and those that read write back to themselves" do
    for {name, %{"certificate" => cert, "signer" => signer}} <- vectors()["certificates"] do
      if signer, do: assert(cert["sig"] == raw_signature(cert, private(signer)), name)

      case DeviceCert.decode(cert) do
        {:ok, decoded} ->
          assert DeviceCert.encode(decoded) == cert, name

          if signer,
            do: assert(DeviceCert.sign(%{decoded | sig: nil}, private(signer)) == decoded)

        {:error, :local_subject_elsewhere} ->
          assert name == "local_elsewhere"
      end
    end
  end

  test "every certificate is checked at its home, clock and epoch to its result" do
    v = vectors()

    for %{"name" => name, "certificate" => cert, "key" => key, "opts" => opts} = vector <-
          v["verify"] do
      opts =
        [home: opts["home"], now: opts["now"], skew: opts["skew"]] ++
          if(opts["key_epoch"], do: [key_epoch: opts["key_epoch"]], else: [])

      result = DeviceCert.verify(v["certificates"][cert]["certificate"], public(key), opts)

      case vector do
        %{"result" => "ok"} -> assert {:ok, %DeviceCert{}} = result, name
        %{"error" => error} -> assert tag(result) == error, name
      end
    end
  end

  test "expiry is strict and the tolerance never extends a certificate" do
    v = vectors()
    cert = v["certificates"]["local"]["certificate"]
    home = v["homes"]["alice"]
    expires_at = cert["expires_at"]

    for skew <- [0, 60_000, 3_600_000] do
      assert DeviceCert.verify(cert, public("alice_live_1"),
               home: home,
               now: expires_at,
               skew: skew
             ) ==
               {:error, :expired}
    end
  end

  test "a local certificate carries no identifier or epoch; an identity one carries both" do
    v = vectors()
    {:ok, local} = DeviceCert.decode(v["certificates"]["local"]["certificate"])
    assert local.subject == %{kind: :local, user_id: local.subject.user_id}
    assert local.issuer == local.audience

    {:ok, identity} = DeviceCert.decode(v["certificates"]["identity"]["certificate"])

    assert %{kind: :identity, identifier: "per_" <> _, key_epoch: "sha256:" <> _} =
             identity.subject

    assert identity.issuer != identity.audience
  end

  test "every malformed certificate is refused" do
    for %{"name" => name, "certificate" => cert, "error" => error} <- vectors()["refusals"] do
      assert tag(DeviceCert.decode(cert)) == error, name
    end
  end

  test "new/1 builds the fixture's local certificate" do
    v = vectors()
    cert = v["certificates"]["local"]["certificate"]

    {:ok, built} =
      DeviceCert.new(
        device_key: public("device_1"),
        client_id: cert["client_id"],
        subject: %{kind: :local, user_id: cert["subject"]["user_id"]},
        issuer: cert["issuer"],
        audience: cert["audience"],
        athanor: cert["athanor"],
        not_before: cert["not_before"],
        expires_at: cert["expires_at"]
      )

    assert DeviceCert.encode(DeviceCert.sign(built, private("alice_live_1"))) == cert

    assert DeviceCert.new(
             device_key: public("device_1"),
             client_id: cert["client_id"],
             subject: %{kind: :local, user_id: cert["subject"]["user_id"]},
             issuer: cert["issuer"],
             audience: v["homes"]["hub"],
             athanor: cert["athanor"],
             not_before: cert["not_before"],
             expires_at: cert["expires_at"]
           ) == {:error, :local_subject_elsewhere}
  end

  describe "challenges and proofs" do
    test "every challenge reads and writes back, and a challenge lives 60 seconds from issue" do
      v = vectors()

      for {name, map} <- v["challenges"] do
        assert {:ok, challenge} = Challenge.decode(map), name
        assert Challenge.encode(challenge) == map
        assert challenge.expires_at == v["issued_at"] + Challenge.lifetime_ms()
        assert byte_size(challenge.nonce) == Challenge.nonce_bytes()
      end

      connect = v["challenges"]["connect"]

      assert {:ok, built} =
               Challenge.new(
                 purpose: :connect,
                 home: connect["home"],
                 athanor: connect["athanor"],
                 client_id: connect["client_id"],
                 device_key: public("device_1"),
                 nonce: unb64(connect["nonce"]),
                 now: v["issued_at"]
               )

      assert Challenge.encode(built) == connect
    end

    test "every proof is the device key's signature over its exact challenge" do
      v = vectors()

      for {name, device} <- [
            {"connect", "device_1"},
            {"renew", "device_1"},
            {"pair", "device_1"},
            {"by_another_key", "device_2"}
          ] do
        proof = v["proofs"][name]
        assert proof["sig"] == raw_signature(proof, private(device)), name
        assert {:ok, decoded} = Proof.decode(proof)
        assert Proof.encode(decoded) == proof
      end

      {:ok, connect} = Challenge.decode(v["challenges"]["connect"])
      assert Proof.encode(Proof.sign(connect, private("device_1"))) == v["proofs"]["connect"]
    end

    test "every proof is held to the challenge held for its connection" do
      v = vectors()

      for %{"name" => name, "proof" => proof, "held" => held, "now" => now} = vector <-
            v["proof_cases"] do
        {:ok, held} = Challenge.decode(v["challenges"][held])
        result = Proof.verify(v["proofs"][proof], held, now)

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

    test "a pairing proof and a connect or renewal proof never stand in for each other" do
      v = vectors()
      proof = fn name -> v["proofs"][name] end
      held = fn name -> elem(Challenge.decode(v["challenges"][name]), 1) end
      now = v["issued_at"] + 1000

      assert held.("pair").purpose == :pair
      assert held.("pair").client_id in v["reserved_client_ids"]
      assert Proof.verify(proof.("pair"), held.("pair"), now) == :ok

      for {presented, expected} <- [
            {"pair", "connect"},
            {"pair", "renew"},
            {"connect", "pair"},
            {"renew", "pair"}
          ] do
        assert Proof.verify(proof.(presented), held.(expected), now) ==
                 {:error, {:challenge_mismatch, :purpose}},
               "#{presented} for #{expected}"
      end

      assert held.("pair_other_client").client_id != held.("pair").client_id

      assert Proof.verify(proof.("pair"), held.("pair_other_client"), now) ==
               {:error, {:challenge_mismatch, :client_id}}
    end

    test "every malformed challenge is refused, and a proof needs its signature" do
      v = vectors()

      for %{"name" => name, "challenge" => map, "error" => error} <- v["challenge_refusals"] do
        assert tag(Challenge.decode(map)) == error, name
      end

      assert Proof.decode(Map.delete(v["proofs"]["connect"], "sig")) ==
               {:error, {:missing_field, "sig"}}
    end

    test "a certificate's signature never verifies as a proof's, nor a proof's as a certificate's" do
      v = vectors()
      cert = v["certificates"]["local"]["certificate"]
      proof = v["proofs"]["connect"]

      refute Encoding.verify(
               Map.put(proof, "protocol", DeviceCert.protocol()),
               public("device_1")
             )

      refute Encoding.verify(
               Map.put(cert, "protocol", Challenge.protocol()),
               public("alice_live_1")
             )
    end
  end
end
