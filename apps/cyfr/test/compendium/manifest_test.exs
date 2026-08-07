# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ManifestTest do
  use ExUnit.Case, async: true

  alias Compendium.Manifest

  describe "decode/1" do
    test "returns empty map for nil" do
      assert Manifest.decode(nil) == %{}
    end

    test "passes through maps unchanged" do
      map = %{"setup" => %{"secrets" => []}}
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
      map = %{"setup" => %{"secrets" => []}}
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
end
