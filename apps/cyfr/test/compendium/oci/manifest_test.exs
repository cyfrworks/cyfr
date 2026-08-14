# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.ManifestTest do
  use ExUnit.Case, async: true

  alias Compendium.OCI.Manifest

  describe "build/4" do
    test "builds a valid OCI Image Manifest" do
      config = %{"name" => "test", "version" => "1.0.0", "type" => "reagent"}
      # minimal WASM magic
      wasm_bytes = <<0, 97, 115, 109, 1, 0, 0, 0>>

      assert {:ok, manifest_json, config_digest, wasm_digest} =
               Manifest.build(config, wasm_bytes, "reagent")

      assert is_binary(manifest_json)
      assert String.starts_with?(config_digest, "sha256:")
      assert String.starts_with?(wasm_digest, "sha256:")

      # Parse the manifest back
      assert {:ok, parsed} = Jason.decode(manifest_json)
      assert parsed["schemaVersion"] == 2
      assert parsed["mediaType"] == "application/vnd.oci.image.manifest.v1+json"
      assert parsed["artifactType"] == "application/vnd.cyfr.component.v1"
      assert parsed["config"]["mediaType"] == "application/vnd.cyfr.manifest.v1+json"
      assert parsed["config"]["digest"] == config_digest
      assert length(parsed["layers"]) == 1

      layer = hd(parsed["layers"])
      assert layer["mediaType"] == "application/vnd.cyfr.reagent.v1+wasm"
      assert layer["digest"] == wasm_digest
      assert layer["size"] == byte_size(wasm_bytes)
    end

    test "builds with string config" do
      config_str = ~s({"name":"test","version":"1.0.0"})
      wasm_bytes = <<0, 97, 115, 109>>

      assert {:ok, _json, _cd, _wd} = Manifest.build(config_str, wasm_bytes, "catalyst")
    end

    test "includes annotations" do
      config = %{"name" => "test"}
      wasm_bytes = <<0, 97, 115, 109>>
      annotations = %{"custom.key" => "value"}

      assert {:ok, json, _, _} = Manifest.build(config, wasm_bytes, "reagent", annotations)
      assert {:ok, parsed} = Jason.decode(json)
      assert parsed["annotations"]["custom.key"] == "value"
    end

    test "uses correct media type for each component type" do
      wasm = <<0, 97, 115, 109>>

      for {type, expected_media} <- [
            {"catalyst", "application/vnd.cyfr.catalyst.v1+wasm"},
            {"reagent", "application/vnd.cyfr.reagent.v1+wasm"},
            {"formula", "application/vnd.cyfr.formula.v1+wasm"}
          ] do
        {:ok, json, _, _} = Manifest.build(%{}, wasm, type)
        {:ok, parsed} = Jason.decode(json)
        layer = hd(parsed["layers"])
        assert layer["mediaType"] == expected_media, "Expected #{expected_media} for #{type}"
      end
    end
  end

  describe "parse/1" do
    test "parses a valid manifest" do
      manifest =
        Jason.encode!(%{
          "schemaVersion" => 2,
          "mediaType" => "application/vnd.oci.image.manifest.v1+json",
          "artifactType" => "application/vnd.cyfr.component.v1",
          "config" => %{
            "mediaType" => "application/vnd.cyfr.manifest.v1+json",
            "size" => 42,
            "digest" => "sha256:abc"
          },
          "layers" => [
            %{
              "mediaType" => "application/vnd.cyfr.reagent.v1+wasm",
              "size" => 1024,
              "digest" => "sha256:def"
            }
          ],
          "annotations" => %{
            "org.opencontainers.image.title" => "test"
          }
        })

      assert {:ok, parsed} = Manifest.parse(manifest)
      assert parsed.config["digest"] == "sha256:abc"
      assert length(parsed.layers) == 1
      assert hd(parsed.layers)["digest"] == "sha256:def"
      assert parsed.annotations["org.opencontainers.image.title"] == "test"
      assert parsed.artifact_type == "application/vnd.cyfr.component.v1"
    end

    test "returns error for invalid JSON" do
      assert {:error, msg} = Manifest.parse("not json")
      assert msg =~ "Invalid manifest JSON"
    end

    test "returns error for missing schemaVersion" do
      assert {:error, "Manifest missing schemaVersion"} = Manifest.parse(~s({"mediaType":"test"}))
    end

    test "returns error for unsupported schema version" do
      json = Jason.encode!(%{"schemaVersion" => 1})
      assert {:error, msg} = Manifest.parse(json)
      assert msg =~ "Unsupported manifest schema version"
    end
  end

  describe "wasm_layer/1" do
    test "finds WASM layer" do
      parsed = %{
        layers: [
          %{
            "mediaType" => "application/vnd.cyfr.reagent.v1+wasm",
            "digest" => "sha256:abc",
            "size" => 100
          }
        ]
      }

      assert {:ok, layer} = Manifest.wasm_layer(parsed)
      assert layer["digest"] == "sha256:abc"
    end

    test "returns error when no WASM layer" do
      parsed = %{
        layers: [
          %{"mediaType" => "application/octet-stream", "digest" => "sha256:abc"}
        ]
      }

      assert {:error, _} = Manifest.wasm_layer(parsed)
    end
  end

  describe "build_annotations/1" do
    test "builds standard annotations" do
      annotations =
        Manifest.build_annotations(%{
          name: "test-tool",
          version: "1.0.0",
          type: "catalyst",
          publisher: "cyfr",
          description: "A test tool",
          license: "MIT",
          category: "utilities"
        })

      assert annotations["org.opencontainers.image.title"] == "test-tool"
      assert annotations["org.opencontainers.image.version"] == "1.0.0"
      assert annotations["dev.cyfr.component.type"] == "catalyst"
      assert annotations["dev.cyfr.component.publisher"] == "cyfr"
      assert annotations["org.opencontainers.image.description"] == "A test tool"
      assert annotations["org.opencontainers.image.licenses"] == "MIT"
      assert annotations["dev.cyfr.component.category"] == "utilities"
    end

    test "omits nil optional fields" do
      annotations =
        Manifest.build_annotations(%{
          name: "test",
          version: "1.0.0",
          type: "reagent",
          publisher: "local",
          description: nil,
          license: nil,
          category: nil
        })

      refute Map.has_key?(annotations, "org.opencontainers.image.description")
      refute Map.has_key?(annotations, "org.opencontainers.image.licenses")
      refute Map.has_key?(annotations, "dev.cyfr.component.category")
    end
  end

  describe "build/5 with optional layers" do
    test "build with readme_bytes adds README layer" do
      config = %{"name" => "test", "version" => "1.0.0"}
      wasm = <<0, 97, 115, 109, 1, 0, 0, 0>>
      readme = "# My Component\n\nThis is a test."

      {:ok, json, _cd, _wd} = Manifest.build(config, wasm, "reagent", %{}, readme_bytes: readme)
      {:ok, parsed} = Jason.decode(json)

      assert length(parsed["layers"]) == 2
      assert Enum.at(parsed["layers"], 0)["mediaType"] == "application/vnd.cyfr.reagent.v1+wasm"
      assert Enum.at(parsed["layers"], 1)["mediaType"] == Manifest.readme_media_type()
      assert Enum.at(parsed["layers"], 1)["size"] == byte_size(readme)
    end

    test "build with source_bytes adds source layer" do
      config = %{"name" => "test", "version" => "1.0.0"}
      wasm = <<0, 97, 115, 109, 1, 0, 0, 0>>
      source = :crypto.strong_rand_bytes(128)

      {:ok, json, _cd, _wd} = Manifest.build(config, wasm, "catalyst", %{}, source_bytes: source)
      {:ok, parsed} = Jason.decode(json)

      assert length(parsed["layers"]) == 2
      assert Enum.at(parsed["layers"], 1)["mediaType"] == Manifest.source_media_type()
      assert Enum.at(parsed["layers"], 1)["size"] == byte_size(source)
    end

    test "build with both readme and source adds 3 layers in order" do
      config = %{"name" => "test", "version" => "1.0.0"}
      wasm = <<0, 97, 115, 109>>
      readme = "# README"
      source = :crypto.strong_rand_bytes(64)

      {:ok, json, _cd, _wd} =
        Manifest.build(config, wasm, "reagent", %{}, readme_bytes: readme, source_bytes: source)

      {:ok, parsed} = Jason.decode(json)

      assert length(parsed["layers"]) == 3
      media_types = Enum.map(parsed["layers"], & &1["mediaType"])
      assert Enum.at(media_types, 0) == "application/vnd.cyfr.reagent.v1+wasm"
      assert Enum.at(media_types, 1) == Manifest.readme_media_type()
      assert Enum.at(media_types, 2) == Manifest.source_media_type()
    end

    test "build with no opts (regression) produces 1 layer" do
      config = %{"name" => "test", "version" => "1.0.0"}
      wasm = <<0, 97, 115, 109>>

      {:ok, json, _cd, _wd} = Manifest.build(config, wasm, "formula", %{}, [])
      {:ok, parsed} = Jason.decode(json)

      assert length(parsed["layers"]) == 1
    end
  end

  describe "readme_layer/1" do
    test "finds README layer" do
      parsed = %{
        layers: [
          %{"mediaType" => "application/vnd.cyfr.reagent.v1+wasm", "digest" => "sha256:aaa"},
          %{"mediaType" => Manifest.readme_media_type(), "digest" => "sha256:bbb", "size" => 42}
        ]
      }

      assert {:ok, layer} = Manifest.readme_layer(parsed)
      assert layer["digest"] == "sha256:bbb"
    end

    test "returns :none when no README layer" do
      parsed = %{
        layers: [
          %{"mediaType" => "application/vnd.cyfr.reagent.v1+wasm", "digest" => "sha256:aaa"}
        ]
      }

      assert :none = Manifest.readme_layer(parsed)
    end
  end

  describe "source_layer/1" do
    test "finds source layer" do
      parsed = %{
        layers: [
          %{"mediaType" => "application/vnd.cyfr.reagent.v1+wasm", "digest" => "sha256:aaa"},
          %{"mediaType" => Manifest.source_media_type(), "digest" => "sha256:ccc", "size" => 256}
        ]
      }

      assert {:ok, layer} = Manifest.source_layer(parsed)
      assert layer["digest"] == "sha256:ccc"
    end

    test "returns :none when no source layer" do
      parsed = %{
        layers: [
          %{"mediaType" => "application/vnd.cyfr.reagent.v1+wasm", "digest" => "sha256:aaa"}
        ]
      }

      assert :none = Manifest.source_layer(parsed)
    end
  end

  describe "layer extractors - edge cases" do
    test "readme_layer returns :none on empty layers" do
      assert :none = Manifest.readme_layer(%{layers: []})
    end

    test "source_layer returns :none on empty layers" do
      assert :none = Manifest.source_layer(%{layers: []})
    end

    test "extractors ignore unknown media types" do
      parsed = %{
        layers: [
          %{"mediaType" => "application/octet-stream", "digest" => "sha256:unknown"},
          %{"mediaType" => "text/plain", "digest" => "sha256:txt"}
        ]
      }

      assert :none = Manifest.readme_layer(parsed)
      assert :none = Manifest.source_layer(parsed)
    end

    test "extractors find layers among mixed types" do
      parsed = %{
        layers: [
          %{"mediaType" => "application/vnd.cyfr.catalyst.v1+wasm", "digest" => "sha256:wasm"},
          %{"mediaType" => "application/octet-stream", "digest" => "sha256:unknown"},
          %{"mediaType" => Manifest.readme_media_type(), "digest" => "sha256:readme"},
          %{"mediaType" => Manifest.source_media_type(), "digest" => "sha256:source"}
        ]
      }

      assert {:ok, wl} = Manifest.wasm_layer(parsed)
      assert wl["digest"] == "sha256:wasm"
      assert {:ok, rl} = Manifest.readme_layer(parsed)
      assert rl["digest"] == "sha256:readme"
      assert {:ok, sl} = Manifest.source_layer(parsed)
      assert sl["digest"] == "sha256:source"
    end
  end

  describe "media type constants" do
    test "readme_media_type returns expected string" do
      assert Manifest.readme_media_type() == "application/vnd.cyfr.readme.v1+markdown"
    end

    test "source_media_type returns expected string" do
      assert Manifest.source_media_type() == "application/vnd.cyfr.source.v1.tar+gzip"
    end
  end

  describe "build -> parse roundtrip" do
    test "manifest survives roundtrip" do
      config = %{"name" => "roundtrip-test", "version" => "1.0.0"}
      wasm = :crypto.strong_rand_bytes(256)
      annotations = %{"custom" => "value"}

      {:ok, json, config_digest, wasm_digest} =
        Manifest.build(config, wasm, "catalyst", annotations)

      {:ok, parsed} = Manifest.parse(json)

      assert parsed.config["digest"] == config_digest
      assert hd(parsed.layers)["digest"] == wasm_digest
      assert parsed.annotations["custom"] == "value"
    end

    test "roundtrip with all layers preserves layer descriptors" do
      config = %{"name" => "full-test", "version" => "2.0.0"}
      wasm = :crypto.strong_rand_bytes(128)
      readme = "# Full Test Component"
      source = :crypto.strong_rand_bytes(64)

      {:ok, json, config_digest, wasm_digest} =
        Manifest.build(config, wasm, "catalyst", %{}, readme_bytes: readme, source_bytes: source)

      {:ok, parsed} = Manifest.parse(json)

      assert parsed.config["digest"] == config_digest

      # WASM layer
      assert {:ok, wasm_layer} = Manifest.wasm_layer(parsed)
      assert wasm_layer["digest"] == wasm_digest

      # README layer
      assert {:ok, readme_layer} = Manifest.readme_layer(parsed)
      assert readme_layer["size"] == byte_size(readme)

      # Source layer
      assert {:ok, source_layer} = Manifest.source_layer(parsed)
      assert source_layer["size"] == byte_size(source)
    end
  end
end
