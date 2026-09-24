# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ManifestTest do
  @moduledoc """
  The manifest contract as the component domain composes it: the shared
  validator (`Cyfr.Manifest.validate/2`) under the storage layer's
  guest-path predicate, the domain's suggested categories, and the one
  connect-domain grammar the contract copies from the tincture helper.
  """

  use ExUnit.Case, async: true

  alias Cyfr.Manifest

  defp validate(manifest), do: Manifest.validate(manifest, &Arca.Storage.valid_guest_path?/1)

  describe "contracts" do
    test "a manifest declares contracts as family/name@major names" do
      assert :ok = validate(%{"contracts" => ["model/chat@1", "search/query@12"]})
      assert Manifest.contracts(%{"contracts" => ["model/chat@1"]}) == ["model/chat@1"]
      assert Manifest.contracts(%{}) == []
      assert "contracts" in Manifest.known_keys()
    end

    test "a contract off the grammar, or a block that is not a list, is refused" do
      for bad <- ["model/chat", "model/chat@0", "Model/chat@1", "chat@1", "model/chat@1.0", 7] do
        assert {:error, {:invalid_manifest, [{:invalid_contracts, _}]}} =
                 validate(%{"contracts" => [bad]}),
               inspect(bad)
      end

      assert {:error, {:invalid_manifest, [{:invalid_contracts, _}]}} =
               validate(%{"contracts" => "model/chat@1"})

      # A read of a malformed block declares nothing rather than raising.
      assert Manifest.contracts(%{"contracts" => ["model/chat@1", 7, "nope"]}) == ["model/chat@1"]
      assert Manifest.contracts(%{"contracts" => "model/chat@1"}) == []
    end
  end

  describe "agent" do
    @valid_agent %{
      "type" => "agent",
      "agent" => %{
        "catalyst" => "catalyst:local.claude",
        "model" => "claude-sonnet-4-6",
        "policy" => %{"auto" => ["http.get"], "ask" => ["files.read"]}
      }
    }

    test "an agent block is accepted on type agent and refused elsewhere" do
      assert :ok = validate(@valid_agent)
      assert "agent" in Manifest.known_keys()

      assert {:error, {:invalid_manifest, [{:invalid_agent, _}]}} =
               validate(%{"type" => "reagent", "agent" => @valid_agent["agent"]})
    end

    test "auto and ask must be disjoint, and catalyst must be a name-level ref" do
      overlap = put_in(@valid_agent, ["agent", "policy", "ask"], ["http.get"])
      assert {:error, {:invalid_manifest, [{:invalid_agent, _}]}} = validate(overlap)

      pinned = put_in(@valid_agent, ["agent", "catalyst"], "catalyst:local.claude:1.2.0")
      assert {:error, {:invalid_manifest, [{:invalid_agent, _}]}} = validate(pinned)
    end
  end

  describe "categories" do
    test "the domain suggests its category vocabulary" do
      names = Enum.map(Compendium.Manifest.known_categories(), & &1.name)
      assert "utilities" in names
      assert names == Enum.uniq(names)
    end
  end

  # Until the tincture helper delegates to the contract, two spellings of
  # one grammar exist; this holds them to the same answers, so the domain
  # the CSP builder admits and the domain publish admits cannot drift.
  describe "the connect-domain grammar" do
    test "the contract's copy answers as the tincture helper does" do
      probes = [
        "api.example.com",
        "*.example.org",
        "a-b.example.io",
        "x.co",
        "*",
        "*.",
        "https://x.com",
        "x.com/path",
        "x.com:8080",
        "1.2.3.4",
        "evil.com\n",
        " x.com",
        "-x.com",
        "x",
        "",
        7,
        nil
      ]

      for probe <- probes do
        assert Manifest.valid_connect_domain?(probe) ==
                 Cyfr.TinctureHelpers.valid_connect_domain?(probe),
               "the two grammars disagree on #{inspect(probe)}"
      end
    end
  end
end
