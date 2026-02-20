defmodule Compendium.OCI.ManifestTest do
  use ExUnit.Case, async: true

  alias Compendium.OCI.Manifest

  describe "build/4" do
    test "builds a valid OCI Image Manifest" do
      config = %{"name" => "test", "version" => "1.0.0", "type" => "reagent"}
      wasm_bytes = <<0, 97, 115, 109, 1, 0, 0, 0>>  # minimal WASM magic

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
      manifest = Jason.encode!(%{
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

  describe "cyfr_component?/1" do
    test "returns true for CYFR artifact type" do
      assert Manifest.cyfr_component?(%{artifact_type: "application/vnd.cyfr.component.v1", config: %{}})
    end

    test "returns true for CYFR config media type" do
      assert Manifest.cyfr_component?(%{
        artifact_type: nil,
        config: %{"mediaType" => "application/vnd.cyfr.manifest.v1+json"}
      })
    end

    test "returns false for non-CYFR manifest" do
      refute Manifest.cyfr_component?(%{artifact_type: nil, config: %{"mediaType" => "application/vnd.oci.image.config.v1+json"}})
    end
  end

  describe "wasm_layer/1" do
    test "finds WASM layer" do
      parsed = %{layers: [
        %{"mediaType" => "application/vnd.cyfr.reagent.v1+wasm", "digest" => "sha256:abc", "size" => 100}
      ]}
      assert {:ok, layer} = Manifest.wasm_layer(parsed)
      assert layer["digest"] == "sha256:abc"
    end

    test "returns error when no WASM layer" do
      parsed = %{layers: [
        %{"mediaType" => "application/octet-stream", "digest" => "sha256:abc"}
      ]}
      assert {:error, _} = Manifest.wasm_layer(parsed)
    end
  end

  describe "component_type_from_media/1" do
    test "detects catalyst" do
      assert Manifest.component_type_from_media("application/vnd.cyfr.catalyst.v1+wasm") == "catalyst"
    end

    test "detects reagent" do
      assert Manifest.component_type_from_media("application/vnd.cyfr.reagent.v1+wasm") == "reagent"
    end

    test "detects formula" do
      assert Manifest.component_type_from_media("application/vnd.cyfr.formula.v1+wasm") == "formula"
    end

    test "returns nil for unknown" do
      assert Manifest.component_type_from_media("application/octet-stream") == nil
    end
  end

  describe "build_annotations/1" do
    test "builds standard annotations" do
      annotations = Manifest.build_annotations(%{
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
      annotations = Manifest.build_annotations(%{
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

  describe "build -> parse roundtrip" do
    test "manifest survives roundtrip" do
      config = %{"name" => "roundtrip-test", "version" => "1.0.0"}
      wasm = :crypto.strong_rand_bytes(256)
      annotations = %{"custom" => "value"}

      {:ok, json, config_digest, wasm_digest} = Manifest.build(config, wasm, "catalyst", annotations)
      {:ok, parsed} = Manifest.parse(json)

      assert parsed.config["digest"] == config_digest
      assert hd(parsed.layers)["digest"] == wasm_digest
      assert parsed.annotations["custom"] == "value"
      assert Manifest.cyfr_component?(parsed)
    end
  end
end
