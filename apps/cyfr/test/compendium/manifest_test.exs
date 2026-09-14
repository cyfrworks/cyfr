# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ManifestTest do
  use ExUnit.Case, async: true

  alias Compendium.Manifest

  describe "contracts" do
    test "a manifest declares contracts as family/name@major names" do
      assert :ok = Manifest.validate(%{"contracts" => ["model/chat@1", "search/query@12"]})
      assert Manifest.contracts(%{"contracts" => ["model/chat@1"]}) == ["model/chat@1"]
      assert Manifest.contracts(%{}) == []
      assert "contracts" in Manifest.known_keys()
    end

    test "a contract off the grammar, or a block that is not a list, is refused" do
      for bad <- ["model/chat", "model/chat@0", "Model/chat@1", "chat@1", "model/chat@1.0", 7] do
        assert {:error, {:invalid_contracts, _}} = Manifest.validate(%{"contracts" => [bad]}),
               inspect(bad)
      end

      assert {:error, {:invalid_contracts, _}} =
               Manifest.validate(%{"contracts" => "model/chat@1"})

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
      assert :ok = Manifest.validate(@valid_agent)
      assert "agent" in Manifest.known_keys()

      assert {:error, {:invalid_agent, _}} =
               Manifest.validate(%{"type" => "reagent", "agent" => @valid_agent["agent"]})
    end

    test "auto and ask must be disjoint, and catalyst must be a name-level ref" do
      overlap = put_in(@valid_agent, ["agent", "policy", "ask"], ["http.get"])
      assert {:error, {:invalid_agent, _}} = Manifest.validate(overlap)

      pinned = put_in(@valid_agent, ["agent", "catalyst"], "catalyst:local.claude:1.2.0")
      assert {:error, {:invalid_agent, _}} = Manifest.validate(pinned)
    end
  end
end
