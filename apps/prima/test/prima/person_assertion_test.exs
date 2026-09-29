# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.PersonAssertionTest do
  @moduledoc """
  The CYFR door's assertion as data (`tests/fixtures/person_assertion.json`):
  each assertion re-signs to its bytes; each is checked under a verified
  head against the audience, challenge, carry action and clock the relying
  home expects, so an assertion from another `key_epoch`, audience,
  challenge or action is refused; each malformed assertion is refused; and
  the genesis carried beside it is held to its identifier before its
  directory is used.
  """

  use ExUnit.Case, async: true

  alias Prima.{Identity, PersonAssertion}
  alias Prima.Identity.Encoding

  @vectors Path.expand("../../../../tests/fixtures/person_assertion.json", __DIR__)

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

  test "the protocol is the fixture's, and each head's key_epoch is its walk's" do
    v = vectors()
    assert v["protocol"] == PersonAssertion.protocol()

    for {name, %{"key_epoch" => key_epoch}} <- v["identity"]["heads"] do
      assert head(name).key_epoch == key_epoch
    end
  end

  test "every assertion re-signs to its bytes and writes back to itself" do
    for {name, %{"assertion" => map, "signer" => signer}} <- vectors()["assertions"] do
      assert map["sig"] == raw_signature(map, private(signer)), name
      assert {:ok, assertion} = PersonAssertion.decode(map)
      assert PersonAssertion.encode(assertion) == map
      assert PersonAssertion.sign(%{assertion | sig: nil}, private(signer)) == assertion
    end
  end

  test "every assertion is checked under its head to its result" do
    v = vectors()

    for %{"name" => name, "assertion" => assertion, "head" => head, "expect" => expect} = vector <-
          v["verify"] do
      result =
        PersonAssertion.verify(v["assertions"][assertion]["assertion"], head(head),
          audience: expect["audience"],
          challenge: unb64(expect["challenge"]),
          action_id: expect["action_id"],
          now: expect["now"]
        )

      case vector do
        %{"result" => "ok"} -> assert {:ok, %PersonAssertion{}} = result, name
        %{"error" => error} -> assert tag(result) == error, name
      end
    end
  end

  test "every malformed assertion is refused" do
    for %{"name" => name, "assertion" => map, "error" => error} <- vectors()["refusals"] do
      assert tag(PersonAssertion.decode(map)) == error, name
    end
  end

  test "the genesis beside an assertion is held to its identifier before its directory is used" do
    v = vectors()
    genesis = v["identity"]["entries"]["genesis"]

    for %{"name" => name, "assertion" => assertion, "genesis" => carried} = vector <-
          v["transport"] do
      carried =
        case carried do
          %{"with_padding" => length} ->
            Map.put(genesis, "padding", String.duplicate("a", length))

          %{"entry" => entry} ->
            entry
        end

      result =
        PersonAssertion.open(%{
          "assertion" => v["assertions"][assertion]["assertion"],
          "genesis" => carried
        })

      case vector do
        %{"result" => "ok", "directory" => directory} ->
          assert {:ok, %{genesis: %{directory: ^directory}, assertion: %PersonAssertion{}}} =
                   result,
                 name

        %{"error" => error} ->
          assert tag(result) == error, name
      end
    end

    assert PersonAssertion.open(%{"assertion" => %{}}) == {:error, {:invalid_field, "transport"}}
  end

  test "new/1 builds the fixture's assertion" do
    v = vectors()
    map = v["assertions"]["valid"]["assertion"]

    {:ok, built} =
      PersonAssertion.new(
        identifier: map["identifier"],
        audience: map["audience"],
        challenge: unb64(map["challenge"]),
        action_id: map["action_id"],
        key_epoch: map["key_epoch"],
        expires_at: map["expires_at"]
      )

    assert PersonAssertion.encode(PersonAssertion.sign(built, private("alice_live_1"))) == map
    assert byte_size(built.challenge) == PersonAssertion.challenge_bytes()

    refute Encoding.verify(
             Map.put(map, "protocol", "cyfr-carry/v1"),
             unb64(v["keys"]["alice_live_1"]["public"])
           )
  end
end
