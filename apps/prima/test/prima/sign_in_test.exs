# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.SignInTest do
  @moduledoc """
  The sign-in request and its answers as data (`tests/fixtures/sign_in.json`,
  which the account pages read too): every request reads and writes back,
  has its digest and its fragment; every answer reads and writes back, a
  device's re-signs over its request's digest; every answer is checked
  against the request held for it, at a CYFR and a clock, to its result or
  to the refusal of the first check that fails; a passkey's answer to a
  registry request makes the bytes the registry accepts; and every
  malformed request, answer and fragment is refused.
  """

  use ExUnit.Case, async: true

  alias Prima.{Identity, RegistryRequest, SignIn}
  alias Prima.SignIn.{DeviceAnswer, PasskeyAnswer}

  @vectors Path.expand("../../../../tests/fixtures/sign_in.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp unb64(value) do
    {:ok, bytes} = Base.url_decode64(value, padding: false)
    bytes
  end

  defp tag({:ok, _value}), do: "ok"
  defp tag({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp tag({:error, {reason, _field}}) when is_atom(reason), do: Atom.to_string(reason)

  defp state(v) do
    {:ok, state} = Identity.verify_chain(v["identity"]["entries"])
    state
  end

  defp request(v, name) do
    {:ok, request} = SignIn.decode(v["requests"][name]["request"])
    request
  end

  defp answer(v, name) do
    %{"kind" => kind, "answer" => map} = v["answers"][name]
    {:ok, answer} = decoder(kind).(map)
    answer
  end

  defp decoder("passkey"), do: &PasskeyAnswer.decode/1
  defp decoder("device"), do: &DeviceAnswer.decode/1

  test "the protocol's constants are the fixture's" do
    v = vectors()
    assert v["protocol"] == SignIn.protocol()
    assert v["purposes"] == Enum.map(SignIn.purposes(), &Atom.to_string/1)
    assert v["lifetime_ms"] == SignIn.lifetime_ms()
    assert v["challenge_bytes"] == SignIn.challenge_bytes()
    assert v["max_fragment_bytes"] == SignIn.max_fragment_bytes()
  end

  test "the account walks to its state, the identifier its passkey's user handle names" do
    v = vectors()
    state = state(v)
    assert state.identifier == v["identity"]["identifiers"]["alice"]
    assert state.directory == v["directory"]
    {:ok, user_id} = Identity.user_id(state.identifier)
    assert Identity.identifier_for_user_id(user_id) == {:ok, state.identifier}
  end

  test "every request reads and writes back, and has its digest and its fragment" do
    v = vectors()

    for {name, %{"request" => map, "digest" => digest}} <- v["requests"] do
      assert {:ok, request} = SignIn.decode(map), name
      assert SignIn.encode(request) == map, name

      # The digest, spelled independently of Prima.SignIn.
      signed = if map["purpose"] == "registry", do: map["registry_request"], else: map
      {:ok, bytes} = Prima.JCS.encode(signed)
      assert :crypto.hash(:sha256, bytes) == unb64(digest), name
      assert SignIn.digest(request) == unb64(digest), name

      fragment = v["fragments"]["requests"][name]
      {:ok, jcs} = Prima.JCS.encode(map)
      assert fragment == Base.url_encode64(jcs, padding: false), name
      assert SignIn.fragment(request) == fragment, name
      assert SignIn.parse_fragment(fragment) == {:ok, map}, name
    end

    {:ok, built} =
      SignIn.new(
        purpose: :confirm,
        audience: v["home"],
        challenge: unb64(v["requests"]["confirm"]["request"]["challenge"]),
        expires_at: v["requests"]["confirm"]["request"]["expires_at"],
        return: v["requests"]["confirm"]["request"]["return"],
        subject: v["requests"]["confirm"]["request"]["subject"]
      )

    assert SignIn.encode(built) == v["requests"]["confirm"]["request"]
  end

  test "every answer reads and writes back, a device's re-signs, and a passkey's has its fragment" do
    v = vectors()

    for {name, %{"kind" => kind, "answer" => map, "request" => req} = vector} <- v["answers"] do
      assert {:ok, answer} = decoder(kind).(map), name

      case kind do
        "passkey" ->
          assert PasskeyAnswer.encode(answer) == map, name
          fragment = v["fragments"]["answers"][name]
          assert SignIn.fragment(answer) == fragment, name
          assert SignIn.parse_fragment(fragment) == {:ok, map}, name

        "device" ->
          assert DeviceAnswer.encode(answer) == map, name
          seed = unb64(v["keys"][vector["signer"]]["seed"])
          digest = unb64(v["requests"][req]["digest"])
          sig = :crypto.sign(:eddsa, :none, digest, [seed, :ed25519])
          assert answer.sig == sig, name
          assert DeviceAnswer.sign(request(v, req), answer.kid, seed) == answer, name
      end
    end
  end

  test "every answer is checked against the request held for it to its result" do
    v = vectors()
    state = state(v)

    for %{"name" => name, "answer" => answer, "request" => req} = vector <- v["verify"] do
      result =
        SignIn.verify(answer(v, answer), request(v, req), state,
          home: vector["home"],
          now: vector["now_ms"]
        )

      assert tag(result) == (vector["result"] || vector["error"]), name
    end
  end

  test "a passkey's answer to a registry request is the request the registry accepts" do
    v = vectors()
    output = v["registry_output"]
    request = request(v, output["request"])
    answer = answer(v, output["answer"])
    state = state(v)

    assert {:ok, key} =
             SignIn.verify(answer, request, state, home: v["home"], now: output["now_ms"])

    assert key.kid == request.registry_request.signer
    assert SignIn.registry_bytes(request, answer) == {:ok, output["bytes"]}

    registry = %{host: output["registry"]["host"], directory: output["registry"]["directory"]}

    assert {:ok, %RegistryRequest{}} =
             RegistryRequest.verify(output["bytes"], state, registry, output["now_ms"])
  end

  test "every malformed request is refused" do
    for %{"name" => name, "request" => map, "error" => error} <- vectors()["request_refusals"] do
      assert tag(SignIn.decode(map)) == error, name
    end
  end

  test "every malformed answer is refused" do
    for %{"name" => name, "kind" => kind, "answer" => map, "error" => error} <-
          vectors()["answer_refusals"] do
      assert tag(decoder(kind).(map)) == error, name
    end
  end

  test "every fragment that is no request or answer is refused, its length first" do
    for %{"name" => name, "error" => error} = vector <- vectors()["fragments"]["parse"] do
      fragment =
        case vector do
          %{"repeat" => %{"char" => char, "length" => length}} ->
            String.duplicate(char, length)

          %{"fragment" => fragment} ->
            fragment
        end

      assert tag(SignIn.parse_fragment(fragment)) == error, name
    end

    assert SignIn.parse_fragment(nil) == {:error, :invalid_fragment}
  end
end
