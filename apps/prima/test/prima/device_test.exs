# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.DeviceTest do
  @moduledoc """
  The device protocol as data (`tests/fixtures/device.json`): every
  message reads as its sender sent it and writes back to itself; a type
  the other side sends, another version, a field a type does not carry
  and an intent carrying continuous data are each refused by shape; and a
  first connection's answer is device_1's signature over the request it
  answers, re-signed from its seed.
  """

  use ExUnit.Case, async: true

  alias Prima.Device
  alias Prima.DeviceCert
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.SignIn
  alias Prima.SignIn.DeviceAnswer

  @vectors Path.expand("../../../../tests/fixtures/device.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  # A refusal as Prima answers it: its field included, and for an unknown
  # type or one the other side sends, the message's type.
  defp refusal(%{"error" => "unknown_type", "message" => message}),
    do: {:error, {:unknown_type, message["type"]}}

  defp refusal(%{"error" => "wrong_sender", "message" => message}),
    do: {:error, {:wrong_sender, String.to_existing_atom(message["type"])}}

  defp refusal(%{"error" => error, "field" => field}),
    do: {:error, {String.to_existing_atom(error), field}}

  defp refusal(%{"error" => error}), do: {:error, String.to_existing_atom(error)}

  defp sender("glass"), do: :glass
  defp sender("home"), do: :home

  test "the protocol, the types each side sends and the continuous fields are the fixture's" do
    v = vectors()
    assert v["protocol"] == Device.protocol()
    assert v["types"]["glass"] == Enum.map(Device.types(:glass), &Atom.to_string/1)
    assert v["types"]["home"] == Enum.map(Device.types(:home), &Atom.to_string/1)
    assert v["continuous_fields"] == Device.continuous_fields()
    assert MapSet.disjoint?(MapSet.new(Device.types(:glass)), MapSet.new(Device.types(:home)))
  end

  test "every message reads as its sender sent it and writes back to itself" do
    v = vectors()

    for %{"name" => name, "sender" => sender, "message" => message} <- v["messages"] do
      assert {:ok, {type, body}} = Device.decode(message, sender(sender)), name
      assert Atom.to_string(type) == message["type"]
      assert Device.encode({type, body}) == message, name
    end

    sent =
      v["messages"]
      |> Enum.map(fn %{"message" => message} -> message["type"] end)
      |> Enum.uniq()
      |> Enum.sort()

    assert sent == Enum.sort(v["types"]["glass"] ++ v["types"]["home"])
  end

  test "certificates, challenges and proofs arrive as their shapes" do
    by_type = Map.new(vectors()["messages"], &{&1["message"]["type"], &1["message"]})

    assert {:ok, {:connect, %{certificate: %DeviceCert{}}}} =
             Device.decode(by_type["connect"], :glass)

    assert {:ok, {:challenge, %{challenge: %Challenge{purpose: :connect}}}} =
             Device.decode(by_type["challenge"], :home)

    assert {:ok, {:proof, %{proof: %Proof{}}}} = Device.decode(by_type["proof"], :glass)
  end

  test "a hello reads to its key, account, holder, name and admission" do
    hellos = for %{"message" => %{"type" => "hello"} = m} <- vectors()["messages"], do: m

    for message <- hellos do
      admission =
        case message["admission"] do
          %{"setup" => token} -> %{admission: {:setup, token}}
          %{"invitation" => code} -> %{admission: {:invitation, code}}
          nil -> %{}
        end

      assert Device.decode(message, :glass) ==
               {:ok,
                {:hello,
                 Map.merge(
                   %{
                     kid: message["kid"],
                     identifier: message["identifier"],
                     holder_kind: message["holder_kind"],
                     display_name: message["display_name"]
                   },
                   admission
                 )}}
    end

    assert Enum.map(hellos, &Map.keys(&1["admission"] || %{})) == [["setup"], ["invitation"], []]
  end

  test "the public checks of a hello's fields agree with its vectors" do
    v = vectors()
    hellos = for %{"message" => %{"type" => "hello"} = m} <- v["messages"], do: m

    for message <- hellos do
      assert message["holder_kind"] in Device.holder_kinds()
      assert Device.display_name?(message["display_name"])

      case message["admission"] do
        %{"setup" => token} -> assert Device.setup_token?(token)
        %{"invitation" => code} -> assert Device.invitation_code?(code)
        nil -> :ok
      end
    end

    for %{"message" => %{"type" => "hello"} = m, "field" => field} <- v["refusals"] do
      case field do
        "holder_kind" ->
          refute m["holder_kind"] in Device.holder_kinds()

        "display_name" ->
          refute Device.display_name?(m["display_name"])

        "admission" ->
          case m["admission"] do
            %{"setup" => token} = admission when map_size(admission) == 1 ->
              refute Device.setup_token?(token)

            %{"invitation" => code} = admission when map_size(admission) == 1 ->
              refute Device.invitation_code?(code)

            _not_one_capability ->
              :ok
          end

        _other ->
          :ok
      end
    end

    assert Device.holder_kinds() == ~w(chip software)
    refute Device.display_name?(String.duplicate("é", 33))
    assert Device.display_name?(String.duplicate("é", 32))
  end

  test "a first connection: device_1's hello, its signed answer, and its certificate" do
    v = vectors()
    by_type = Map.new(v["messages"], &{&1["message"]["type"], &1["message"]})
    %{"seed" => seed, "public" => public} = v["keys"]["device_1"]
    {:ok, seed} = Prima.Identity.Encoding.unb64(seed, 32)
    {:ok, public} = Prima.Identity.Encoding.unb64(public, 32)
    {derived, _private} = :crypto.generate_key(:eddsa, :ed25519, seed)
    kid = Prima.Identity.kid(public)

    assert derived == public
    assert by_type["hello"]["kid"] == kid

    {:ok, {:sign_in_request, %{request: %SignIn{purpose: :sign_in} = request}}} =
      Device.decode(by_type["sign_in_request"], :home)

    assert SignIn.encode(request) == by_type["sign_in_request"]["request"]

    {:ok, {:sign_in_answer, %{answer: answer}}} = Device.decode(by_type["sign_in_answer"], :glass)
    assert answer == DeviceAnswer.sign(request, kid, seed)
    assert DeviceAnswer.encode(answer) == by_type["sign_in_answer"]["answer"]
    assert :crypto.verify(:eddsa, :none, SignIn.digest(request), answer.sig, [public, :ed25519])

    {:ok, {:admitted, admitted}} = Device.decode(by_type["admitted"], :home)
    {:ok, {:standing, standing}} = Device.decode(by_type["standing"], :home)
    {:ok, certificate} = DeviceCert.decode(by_type["connect"]["certificate"])

    assert admitted == %{
             client_id: certificate.client_id,
             certificate: certificate,
             standing: standing
           }

    assert {certificate.kid, certificate.identifier} ==
             {kid, by_type["hello"]["identifier"]}

    assert standing == %{
             client_id: certificate.client_id,
             athanor: certificate.athanor,
             expires_at: certificate.expires_at
           }
  end

  test "a key's digest and its code are the fixture's, and the code reads back to the digest" do
    %{"device_key" => key, "key_digest" => digest, "code" => code} = vectors()["key_digest"]
    {:ok, raw} = Prima.Identity.Encoding.unb64(key, 32)

    assert Device.key_digest(raw) == digest
    assert Device.key_digest?(digest)
    assert Device.key_code(digest) == code
    assert Device.from_key_code(code) == {:ok, digest}
    assert Device.from_key_code(" " <> String.replace(code, " ", "\n") <> " ") == {:ok, digest}
    assert Device.from_key_code(digest) == {:ok, digest}

    for not_a_digest <- [String.slice(digest, 0, 42), digest <> "A", "sha256:" <> digest, nil, 7] do
      refute Device.key_digest?(not_a_digest)
      assert Device.from_key_code(not_a_digest) == :error
    end
  end

  test "every refusal is refused with its reason, and its field when it names one" do
    intent = Enum.find(vectors()["messages"], &(&1["message"]["type"] == "intent"))["message"]

    for %{"name" => name} = vector <- vectors()["refusals"] do
      message =
        case vector do
          %{"args_filler_length" => length} ->
            Map.put(intent, "args", %{"blob" => String.duplicate("a", length)})

          %{"message" => message} ->
            message
        end

      assert Device.decode(message, sender(vector["sender"] || "glass")) == refusal(vector),
             name
    end

    assert Device.decode("not a message", :glass) == {:error, {:invalid_field, "message"}}
  end

  test "no intent carries continuous data, whatever else it holds" do
    intent = Enum.find(vectors()["messages"], &(&1["message"]["type"] == "intent"))["message"]

    for field <- Device.continuous_fields() do
      assert Device.decode(Map.put(intent, field, "x"), :glass) == {:error, :continuous_payload}
    end
  end
end
