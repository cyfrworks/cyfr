# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ManifestTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Prima.Manifest

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

    # A malformed manifest may carry anything, a credential included; the
    # caller that refuses it as damage logs its component ref.
    test "logs nothing for a manifest that does not decode" do
      malformed = ~s({"needs": {"token": "sk-live-abcdef"})

      # Other async modules log while this one runs; only this module's
      # words and the manifest's bytes are looked for.
      log =
        capture_log(fn ->
          assert Manifest.decode_strict(malformed) == {:error, :malformed_manifest}
          assert Manifest.decode_strict(~s(["sk-live-abcdef"])) == {:error, :malformed_manifest}
        end)

      refute log =~ "Prima.Manifest"
      refute log =~ "sk-live"
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

    test "a provides block is read, and refused as its owner spells it" do
      provides = %{
        "dependencies" => %{"static" => ["catalyst:local.supabase"]},
        "provides" => %{
          "catalyst:local.supabase" => %{
            "database" => %{
              "destination" => %{"hosts" => ["abc.supabase.co"]},
              "values" => %{"anon_key" => "public"}
            }
          }
        }
      }

      assert :ok = validate(provides)

      assert {:error, {:invalid_manifest, [{:invalid_provides, {:undeclared_dependency, _}}]}} =
               validate(Map.put(provides, "dependencies", %{"static" => []}))

      # A malformed dependencies block is refused first, as its own.
      assert {:error, {:invalid_manifest, [{:invalid_dependencies, _}]}} =
               validate(Map.put(provides, "dependencies", ["catalyst:local.supabase"]))
    end

    test "a need's hosts are refused outside the egress the manifest asks" do
      needs = %{
        "needs" => %{
          "api_key" => %{
            "type" => "api_key:openai.com",
            "reason" => "to call OpenAI",
            "hosts" => ["api.openai.com"]
          }
        }
      }

      assert {:error,
              {:invalid_manifest,
               [{:invalid_caps, {:need_host_outside_egress, "api_key", "api.openai.com"}}]}} =
               validate(needs)

      assert :ok =
               validate(Map.put(needs, "caps", %{"egress" => %{"domains" => ["api.openai.com"]}}))
    end

    test "the storage-path check is the caller's predicate, never a default" do
      caps = %{"caps" => %{"storage" => %{"paths" => ["aqua/"], "actions" => ["read"]}}}

      assert {:error, {:invalid_manifest, [{:invalid_caps, {:invalid_storage_path, _}}]}} =
               validate(caps)

      assert :ok = Manifest.validate(caps, fn _path -> true end)
    end

    test "a results block is read on any component type, and refused as its owner spells it" do
      results = %{
        "quote" => %{
          "type" => "object",
          "fields" => %{"price" => %{"type" => "number"}, "symbol" => %{"type" => "string"}}
        }
      }

      for type <- ~w(catalyst formula reagent tincture) do
        assert :ok = validate(%{"type" => type, "results" => results})
      end

      assert :ok = validate(%{"results" => %{}})

      # Whatever the block's owner refuses is the manifest's refusal, its
      # sentence as the owner wrote it.
      for block <- ["quote", [], %{"quote" => %{"type" => "nope"}}, %{"" => %{"type" => "json"}}] do
        assert {:error, {:invalid_manifest, [{:invalid_results, sentence}]}} =
                 validate(%{"results" => block})

        assert {:error, {:invalid_results, ^sentence}} = Prima.Manifest.Results.validate(block)
      end

      assert {:error, {:invalid_manifest, [{:invalid_results, sentence}]}} =
               validate(%{"results" => %{"quote" => %{"type" => "nope"}}})

      assert sentence =~ "results.quote"

      # In the refusal order, after the tincture block and before contracts.
      assert {:error, {:invalid_manifest, [{:invalid_tincture, _}]}} =
               validate(%{"tincture" => "nope", "results" => "nope"})

      assert {:error, {:invalid_manifest, [{:invalid_results, _}]}} =
               validate(%{"results" => "nope", "contracts" => "nope"})
    end
  end

  describe "known_keys/0 and contracts/1" do
    test "the roster names every block the validator reads" do
      for key <-
            ~w(needs caps dependencies tincture contracts agent provides results name type version) do
        assert key in Manifest.known_keys()
      end
    end

    # The guide's field table documents every key of the roster, this one
    # among them (`Cyfr.DocsDriftTest`, outside this application).
    test "results is a key of the roster, so a manifest carrying it is no unknown key" do
      assert "results" in Manifest.known_keys()
      assert :ok = validate(%{"results" => %{}})
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
