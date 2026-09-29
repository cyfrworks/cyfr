# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.DeviceTest do
  @moduledoc """
  The device protocol as data (`tests/fixtures/device.json`): every
  message reads as its sender sent it and writes back to itself; a type
  the other side sends, another version, a field a type does not carry
  and an intent carrying continuous data are each refused by shape.
  """

  use ExUnit.Case, async: true

  alias Prima.Device
  alias Prima.DeviceCert
  alias Prima.DeviceCert.{Challenge, Proof}

  @vectors Path.expand("../../../../tests/fixtures/device.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp tag({:error, reason}), do: tag(reason)
  defp tag({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp tag(reason) when is_atom(reason), do: Atom.to_string(reason)

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

    assert {:ok, {:pair_request, %{invitation_secret: invitation, device_key: key}}} =
             Device.decode(by_type["pair_request"], :glass)

    assert byte_size(invitation) == 16 and byte_size(key) == 32
  end

  test "every refusal is refused with its reason" do
    intent = Enum.find(vectors()["messages"], &(&1["message"]["type"] == "intent"))["message"]

    for %{"name" => name} = vector <- vectors()["refusals"] do
      message =
        case vector do
          %{"args_filler_length" => length} ->
            Map.put(intent, "args", %{"blob" => String.duplicate("a", length)})

          %{"message" => message} ->
            message
        end

      assert tag(Device.decode(message, sender(vector["sender"] || "glass"))) == vector["error"],
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
