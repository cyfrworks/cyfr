# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ConfirmationAssertionTest do
  @moduledoc """
  The certified cross-home confirmation as data
  (`tests/fixtures/confirmation_assertion.json`): each assertion re-signs
  to its bytes; each is checked under a verified head against the
  audience, athanor, ref, digest and clock the deciding home holds, so an
  assertion from another `key_epoch`, key, person, home, athanor or record
  is refused; each malformed assertion is refused; and the record the
  vectors name is a real record whose ref and digest are its own.
  """

  use ExUnit.Case, async: true

  alias Prima.{ConfirmationAssertion, Identity}
  alias Prima.Identity.Encoding

  @vectors Path.expand("../../../../tests/fixtures/confirmation_assertion.json", __DIR__)

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

  defp head(name) do
    identity = vectors()["identity"]
    names = identity["heads"][name]["entries"]
    {:ok, state} = Identity.verify_chain(Enum.map(names, &identity["entries"][&1]))
    state
  end

  test "the protocol and lifetime are the fixture's, and each head's key_epoch is its walk's" do
    v = vectors()
    assert v["protocol"] == ConfirmationAssertion.protocol()
    assert v["lifetime_ms"] == ConfirmationAssertion.lifetime_ms()

    for {name, %{"key_epoch" => key_epoch}} <- v["identity"]["heads"] do
      assert head(name).key_epoch == key_epoch
    end
  end

  test "the record the assertions name is a confirmation whose ref and digest are its own" do
    %{"confirmation" => map, "ref" => ref, "digest" => digest} = vectors()["record"]
    assert {:ok, record} = Prima.Confirmation.decode(map)
    assert Prima.Confirmation.ref(record.id) == ref
    assert Prima.Confirmation.digest(record) == digest
    assert vectors()["assertions"]["valid"]["assertion"]["ref"] == ref
    assert vectors()["assertions"]["valid"]["assertion"]["digest"] == digest
    assert vectors()["assertions"]["valid"]["assertion"]["athanor"] == record.athanor
    assert vectors()["assertions"]["valid"]["assertion"]["audience"] == record.home
  end

  test "every assertion re-signs to its bytes and writes back to itself" do
    for {name, %{"assertion" => map, "signer" => signer}} <- vectors()["assertions"] do
      assert map["sig"] == raw_signature(map, private(signer)), name
      assert {:ok, assertion} = ConfirmationAssertion.decode(map)
      assert ConfirmationAssertion.encode(assertion) == map
      assert ConfirmationAssertion.sign(%{assertion | sig: nil}, private(signer)) == assertion
    end
  end

  test "every assertion is checked under its head to its result" do
    v = vectors()

    for %{"name" => name, "assertion" => assertion, "head" => head, "expect" => expect} = vector <-
          v["verify"] do
      result =
        ConfirmationAssertion.verify(v["assertions"][assertion]["assertion"], head(head),
          audience: expect["audience"],
          athanor: expect["athanor"],
          ref: expect["ref"],
          digest: expect["digest"],
          now: expect["now"]
        )

      case vector do
        %{"result" => "ok"} -> assert {:ok, %ConfirmationAssertion{}} = result, name
        %{"error" => error} -> assert tag(result) == error, name
      end
    end
  end

  test "every malformed assertion is refused" do
    for %{"name" => name, "assertion" => map, "error" => error} <- vectors()["refusals"] do
      assert tag(ConfirmationAssertion.decode(map)) == error, name
    end

    assert ConfirmationAssertion.decode("not a map") == {:error, {:invalid_field, "assertion"}}
  end

  test "new/1 builds the fixture's assertion, and no other protocol's signature verifies it" do
    v = vectors()
    map = v["assertions"]["valid"]["assertion"]

    {:ok, built} =
      ConfirmationAssertion.new(
        identifier: map["identifier"],
        key_epoch: map["key_epoch"],
        audience: map["audience"],
        athanor: map["athanor"],
        ref: map["ref"],
        digest: map["digest"],
        expires_at: map["expires_at"]
      )

    assert ConfirmationAssertion.encode(
             ConfirmationAssertion.sign(built, private("alice_live_1"))
           ) ==
             map

    refute Encoding.verify(
             Map.put(map, "protocol", "cyfr-person-assertion/v1"),
             unb64(v["keys"]["alice_live_1"]["public"])
           )
  end
end
