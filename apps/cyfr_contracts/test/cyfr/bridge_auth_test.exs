# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.BridgeAuthTest do
  @moduledoc """
  The server's half of the bridge authentication reproduces every shared
  vector (`tests/fixtures/bridge_auth.json`, which the bridge's suite reads
  too): keys, canonical strings, headers and sealed values; a sealed value
  opens for its owner and bridge lifetime only; an invalid field is refused.
  """
  use ExUnit.Case, async: true

  alias Cyfr.BridgeAuth

  @vectors Path.expand("../../../../tests/fixtures/bridge_auth.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  setup_all do
    root = Base.decode16!(@vectors["root_hex"], case: :lower)
    owner = @vectors["owner"]

    owner = %{
      athanor: owner["athanor"],
      server: owner["server"],
      generation: owner["generation"],
      epoch: owner["epoch"]
    }

    {:ok, root: root, owner: owner}
  end

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)

  test "keys derive as the vectors say", %{root: root, owner: owner} do
    assert hex(BridgeAuth.control_key(root)) == @vectors["control_key_hex"]
    assert hex(BridgeAuth.seal_key(root)) == @vectors["seal_key_hex"]
    assert {:ok, key} = BridgeAuth.owner_key(root, owner)
    assert hex(key) == @vectors["owner_key_hex"]
  end

  test "an invoke's canonical string and header match", %{root: root, owner: owner} do
    v = @vectors["invoke"]
    invoke = Map.merge(owner, %{boot: v["boot"], ts: v["ts"], nonce: v["nonce"]})
    {:ok, key} = BridgeAuth.owner_key(root, owner)

    assert {:ok, v["canonical"]} == BridgeAuth.canonical(:invoke, invoke, v["body"])
    assert {:ok, v["header"]} == BridgeAuth.invoke_header(key, invoke, v["body"])
  end

  test "a control message's canonical string and header match", %{root: root} do
    v = @vectors["control"]

    control = %{
      generation: v["generation"],
      seq: v["seq"],
      cyfr_boot: v["cyfr_boot"],
      boot: v["boot"],
      ts: v["ts"]
    }

    assert {:ok, v["canonical"]} == BridgeAuth.canonical(:control, control, v["body"])

    assert {:ok, v["header"]} ==
             BridgeAuth.control_header(BridgeAuth.control_key(root), control, v["body"])
  end

  test "a header parses back to its fields and verifies over its own body and key only",
       %{root: root, owner: owner} do
    v = @vectors["invoke"]
    {:ok, key} = BridgeAuth.owner_key(root, owner)

    assert {:ok, fields, mac} = BridgeAuth.parse_header(:invoke, v["header"])
    assert fields == Map.merge(owner, %{boot: v["boot"], ts: v["ts"], nonce: v["nonce"]})
    assert BridgeAuth.verify(:invoke, key, fields, mac, v["body"])
    refute BridgeAuth.verify(:invoke, key, fields, mac, v["body"] <> " ")
    refute BridgeAuth.verify(:invoke, BridgeAuth.control_key(root), fields, mac, v["body"])

    c = @vectors["control"]
    control_key = BridgeAuth.control_key(root)
    assert {:ok, control, control_mac} = BridgeAuth.parse_header(:control, c["header"])
    assert BridgeAuth.verify(:control, control_key, control, control_mac, c["body"])
    assert {:error, :malformed} = BridgeAuth.parse_header(:control, v["header"])
  end

  test "every valid root text decodes to the root, and every invalid one is refused",
       %{root: root} do
    for text <- @vectors["root_text"]["valid"] do
      assert {:ok, ^root} = BridgeAuth.decode_root(text)
    end

    for text <- @vectors["root_text"]["invalid"] do
      assert :error = BridgeAuth.decode_root(text), inspect(text)
    end

    assert :error = BridgeAuth.decode_root(nil)
  end

  test "a sealed environment matches, and opens for its owner and lifetime only",
       %{root: root, owner: owner} do
    v = @vectors["seal"]
    key = BridgeAuth.seal_key(root)
    iv = Base.decode16!(v["iv_hex"], case: :lower)

    assert {:ok, v["sealed"]} == BridgeAuth.seal(key, owner, v["boot"], v["plaintext"], iv)
    assert {:ok, v["plaintext"]} == BridgeAuth.open(key, owner, v["boot"], v["sealed"])
    assert {:error, :unsealable} = BridgeAuth.open(key, owner, "bb_other", v["sealed"])

    assert {:error, :unsealable} =
             BridgeAuth.open(key, %{owner | epoch: owner.epoch + 1}, v["boot"], v["sealed"])

    assert {:error, :unsealable} = BridgeAuth.open(key, owner, v["boot"], "not-sealed")
  end

  test "every invalid field is refused", %{root: root, owner: owner} do
    invoke = Map.merge(owner, %{boot: "bb", ts: 1, nonce: "n"})

    for %{"field" => field, "value" => value} <- @vectors["invalid_fields"] do
      name = String.to_existing_atom(field)

      assert {:error, {:invalid_field, ^name}} =
               BridgeAuth.canonical(:invoke, Map.put(invoke, name, value), "{}")
    end

    assert {:error, {:invalid_field, :epoch}} =
             BridgeAuth.owner_key(root, %{owner | epoch: -1})
  end
end
