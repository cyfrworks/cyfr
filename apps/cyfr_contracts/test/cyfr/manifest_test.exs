# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ManifestTest do
  use ExUnit.Case, async: true

  alias Cyfr.Manifest

  describe "decode/1" do
    test "returns empty map for nil" do
      assert Manifest.decode(nil) == %{}
    end

    test "passes through maps unchanged" do
      map = %{"caps" => %{"tools" => []}}
      assert Manifest.decode(map) == map
    end

    test "decodes valid JSON string" do
      json = ~s({"name": "test", "version": "1.0.0"})
      assert Manifest.decode(json) == %{"name" => "test", "version" => "1.0.0"}
    end

    test "returns empty map for invalid JSON" do
      assert Manifest.decode("not json") == %{}
    end

    test "returns empty map for JSON that decodes to non-map" do
      assert Manifest.decode(~s(["array"])) == %{}
    end

    test "returns empty map for unexpected types" do
      assert Manifest.decode(42) == %{}
      assert Manifest.decode(:atom) == %{}
    end
  end

  describe "decode_strict/1" do
    test "returns empty map for nil" do
      assert Manifest.decode_strict(nil) == {:ok, %{}}
    end

    test "passes through maps unchanged" do
      map = %{"caps" => %{"tools" => []}}
      assert Manifest.decode_strict(map) == {:ok, map}
    end

    test "decodes valid JSON string" do
      json = ~s({"name": "test"})
      assert Manifest.decode_strict(json) == {:ok, %{"name" => "test"}}
    end

    test "rejects invalid JSON" do
      assert Manifest.decode_strict("not json") == {:error, :malformed_manifest}
    end

    test "rejects JSON that decodes to non-map" do
      assert Manifest.decode_strict(~s(["array"])) == {:error, :malformed_manifest}
    end

    test "rejects unexpected types" do
      assert Manifest.decode_strict(42) == {:error, :malformed_manifest}
      assert Manifest.decode_strict(:atom) == {:error, :malformed_manifest}
    end
  end

  # The storage boundary's guest-scope predicate is the caller's; these
  # cases pass a stand-in that admits `data/` alone.
  defp guest_path?(path), do: path == "data" or String.starts_with?(path, "data/")

  defp validate(manifest), do: Manifest.validate(manifest, &guest_path?/1)

  describe "validate/2" do
    test "a well-formed manifest, and a value that is not a map, pass" do
      assert :ok =
               validate(%{
                 "name" => "x",
                 "type" => "reagent",
                 "contracts" => ["model/chat@1"],
                 "caps" => %{"storage" => %{"paths" => ["data/"], "actions" => ["read"]}},
                 "tincture" => %{"connect" => ["api.example.com", "*.example.org"]},
                 "dependencies" => %{"static" => ["catalyst:local.files"]}
               })

      assert :ok = validate(nil)
      assert :ok = validate("not a map")
    end

    test "the first failure is the refusal, as its block spelled it" do
      # Unknown keys come first, even beside a malformed caps block.
      assert {:error, {:invalid_manifest, [{:unknown_manifest_keys, message}]}} =
               validate(%{"setup" => %{}, "caps" => "nope"})

      assert message =~ "unknown top-level key(s): setup"
      assert message =~ "Known keys: " <> Enum.join(Manifest.known_keys(), ", ")

      # The block validators speak sentences; needs and caps their terms.
      assert {:error, {:invalid_manifest, [{:invalid_tincture, text}]}} =
               validate(%{"tincture" => %{"connect" => ["https://x.com"]}})

      assert is_binary(text)

      assert {:error, {:invalid_manifest, [{:invalid_caps, {:not_a_map, "nope"}}]}} =
               validate(%{"caps" => "nope"})

      assert {:error, {:invalid_manifest, [{:invalid_needs, {:not_a_map, 7}}]}} =
               validate(%{"needs" => 7})

      assert {:error, {:invalid_manifest, [{:invalid_contracts, _}]}} =
               validate(%{"contracts" => "model/chat@1"})

      assert {:error, {:invalid_manifest, [{:invalid_agent, _}]}} =
               validate(%{"type" => "reagent", "agent" => %{}})

      assert {:error, {:invalid_manifest, [{:invalid_dependencies, _}]}} =
               validate(%{"dependencies" => ["catalyst:local.files"]})
    end

    test "the storage-path check is the caller's predicate, never a default" do
      caps = %{"caps" => %{"storage" => %{"paths" => ["aqua/"], "actions" => ["read"]}}}

      assert {:error, {:invalid_manifest, [{:invalid_caps, {:invalid_storage_path, _}}]}} =
               validate(caps)

      assert :ok = Manifest.validate(caps, fn _path -> true end)
    end
  end

  describe "known_keys/0 and contracts/1" do
    test "the roster names every block the validator reads" do
      for key <- ~w(needs caps dependencies tincture contracts agent name type version) do
        assert key in Manifest.known_keys()
      end
    end

    test "contracts are family/name@major names; a malformed block declares none" do
      assert Manifest.contracts(%{"contracts" => ["model/chat@1", 7, "nope"]}) == [
               "model/chat@1"
             ]

      assert Manifest.contracts(%{"contracts" => "model/chat@1"}) == []
      assert Manifest.contracts(%{}) == []
      assert Manifest.contracts(nil) == []
    end
  end

  describe "valid_connect_domain?/1" do
    test "a bare domain, optionally wildcarded, and nothing else" do
      for good <- ["api.example.com", "*.example.org", "a-b.example.io"] do
        assert Manifest.valid_connect_domain?(good), good
      end

      for bad <- ["*", "https://x.com", "1.2.3.4", "x.com/path", "x.com:8080", "evil.com\n", 7] do
        refute Manifest.valid_connect_domain?(bad), inspect(bad)
      end
    end
  end
end
