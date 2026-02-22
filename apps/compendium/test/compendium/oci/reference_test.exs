defmodule Compendium.OCI.ReferenceTest do
  use ExUnit.Case, async: true

  alias Compendium.OCI.Reference

  describe "parse/1" do
    test "parses full OCI reference with registry, repo, and tag" do
      assert {:ok, ref} = Reference.parse("ghcr.io/cyfr/reagents/data-processor:1.2.0")
      assert ref.registry == "ghcr.io"
      assert ref.repository == "cyfr/reagents/data-processor"
      assert ref.tag == "1.2.0"
      assert ref.digest == nil
      assert ref.default_registry == false
    end

    test "parses reference with digest" do
      assert {:ok, ref} = Reference.parse("ghcr.io/cyfr/reagents/data-processor@sha256:abc123def456")
      assert ref.registry == "ghcr.io"
      assert ref.repository == "cyfr/reagents/data-processor"
      assert ref.tag == nil
      assert ref.digest == "sha256:abc123def456"
      assert ref.default_registry == false
    end

    test "parses docker.io reference" do
      assert {:ok, ref} = Reference.parse("docker.io/library/nginx:latest")
      assert ref.registry == "docker.io"
      assert ref.repository == "library/nginx"
      assert ref.tag == "latest"
      assert ref.default_registry == false
    end

    test "parses reference without tag" do
      assert {:ok, ref} = Reference.parse("ghcr.io/cyfr/catalysts/claude")
      assert ref.registry == "ghcr.io"
      assert ref.repository == "cyfr/catalysts/claude"
      assert ref.tag == nil
      assert ref.default_registry == false
    end

    test "parses localhost registry with port" do
      assert {:ok, ref} = Reference.parse("localhost:5000/test/repo:v1")
      assert ref.registry == "localhost:5000"
      assert ref.repository == "test/repo"
      assert ref.tag == "v1"
      assert ref.default_registry == false
    end

    test "parses reference with no explicit registry" do
      assert {:ok, ref} = Reference.parse("cyfr/reagents/data-processor:1.0.0")
      assert ref.registry == "registry.cyfr.run"
      assert ref.repository == "cyfr/reagents/data-processor"
      assert ref.tag == "1.0.0"
      assert ref.default_registry == true
    end

    test "single-segment reference defaults registry" do
      assert {:ok, ref} = Reference.parse("myrepo")
      assert ref.registry == "registry.cyfr.run"
      assert ref.repository == "myrepo"
      assert ref.default_registry == true
    end

    test "returns error for empty string" do
      assert {:error, "OCI reference cannot be empty"} = Reference.parse("")
    end

    test "returns error for non-string" do
      assert {:error, "OCI reference must be a string"} = Reference.parse(42)
    end
  end

  describe "to_string/1" do
    test "formats reference with tag" do
      ref = %Reference{registry: "ghcr.io", repository: "cyfr/reagents/dp", tag: "1.2.0"}
      assert Reference.to_string(ref) == "ghcr.io/cyfr/reagents/dp:1.2.0"
    end

    test "formats reference with digest" do
      ref = %Reference{registry: "ghcr.io", repository: "cyfr/reagents/dp", tag: nil, digest: "sha256:abc"}
      assert Reference.to_string(ref) == "ghcr.io/cyfr/reagents/dp@sha256:abc"
    end

    test "defaults tag to latest" do
      ref = %Reference{registry: "ghcr.io", repository: "cyfr/reagents/dp", tag: nil}
      assert Reference.to_string(ref) == "ghcr.io/cyfr/reagents/dp:latest"
    end
  end

  describe "from_component_ref/2" do
    test "builds OCI reference from ComponentRef" do
      cref = %Sanctum.ComponentRef{type: "reagent", namespace: "cyfr", name: "data-processor", version: "1.2.0"}
      assert {:ok, ref} = Reference.from_component_ref(cref, "ghcr.io")
      assert ref.registry == "ghcr.io"
      assert ref.repository == "cyfr/reagents/data-processor"
      assert ref.tag == "1.2.0"
    end

    test "builds for catalyst type" do
      cref = %Sanctum.ComponentRef{type: "catalyst", namespace: "local", name: "claude", version: "0.1.0"}
      assert {:ok, ref} = Reference.from_component_ref(cref, "docker.io")
      assert ref.repository == "local/catalysts/claude"
    end

    test "builds for formula type" do
      cref = %Sanctum.ComponentRef{type: "formula", namespace: "alice", name: "pipeline", version: "2.0.0"}
      assert {:ok, ref} = Reference.from_component_ref(cref, "ghcr.io")
      assert ref.repository == "alice/formulas/pipeline"
    end

    test "returns error when type is nil" do
      cref = %Sanctum.ComponentRef{type: nil, namespace: "cyfr", name: "test", version: "1.0.0"}
      assert {:error, _} = Reference.from_component_ref(cref, "ghcr.io")
    end
  end

  describe "to_component_ref/1" do
    test "converts OCI reference to ComponentRef" do
      ref = %Reference{registry: "ghcr.io", repository: "cyfr/reagents/data-processor", tag: "1.2.0"}
      assert {:ok, cref} = Reference.to_component_ref(ref)
      assert cref.type == "reagent"
      assert cref.namespace == "cyfr"
      assert cref.name == "data-processor"
      assert cref.version == "1.2.0"
    end

    test "converts catalyst repository" do
      ref = %Reference{registry: "ghcr.io", repository: "local/catalysts/claude", tag: "0.1.0"}
      assert {:ok, cref} = Reference.to_component_ref(ref)
      assert cref.type == "catalyst"
      assert cref.namespace == "local"
    end

    test "returns error for non-CYFR repository path" do
      ref = %Reference{registry: "ghcr.io", repository: "library/nginx", tag: "latest"}
      assert {:error, _} = Reference.to_component_ref(ref)
    end

    test "returns error for unknown type directory" do
      ref = %Reference{registry: "ghcr.io", repository: "cyfr/widgets/test", tag: "1.0.0"}
      assert {:error, msg} = Reference.to_component_ref(ref)
      assert msg =~ "Unknown component type"
    end
  end

  describe "roundtrip" do
    test "ComponentRef -> OCI Reference -> ComponentRef" do
      original = %Sanctum.ComponentRef{type: "reagent", namespace: "cyfr", name: "sentiment", version: "1.0.0"}
      assert {:ok, oci_ref} = Reference.from_component_ref(original, "ghcr.io")
      assert {:ok, roundtripped} = Reference.to_component_ref(oci_ref)
      assert roundtripped.type == original.type
      assert roundtripped.namespace == original.namespace
      assert roundtripped.name == original.name
      assert roundtripped.version == original.version
    end

    test "parse -> to_string roundtrip" do
      input = "ghcr.io/cyfr/reagents/data-processor:1.2.0"
      assert {:ok, ref} = Reference.parse(input)
      assert Reference.to_string(ref) == input
    end
  end

  describe "oci_ref?/1" do
    test "returns true for OCI-style references" do
      assert Reference.oci_ref?("ghcr.io/cyfr/reagents/data-processor:1.2.0")
      assert Reference.oci_ref?("docker.io/library/nginx:latest")
      assert Reference.oci_ref?("localhost:5000/test/repo:v1")
    end

    test "returns false for local paths" do
      refute Reference.oci_ref?("./components/test.wasm")
      refute Reference.oci_ref?("/absolute/path/test.wasm")
    end

    test "returns false for registry references" do
      refute Reference.oci_ref?("catalyst:local.claude:0.1.0")
      refute Reference.oci_ref?("local.claude:0.1.0")
    end

    test "returns false for non-strings" do
      refute Reference.oci_ref?(nil)
      refute Reference.oci_ref?(42)
    end
  end

  describe "api_base/1" do
    test "docker.io uses registry-1.docker.io" do
      ref = %Reference{registry: "docker.io", repository: "test", tag: nil}
      assert Reference.api_base(ref) == "https://registry-1.docker.io"
    end

    test "ghcr.io uses https" do
      ref = %Reference{registry: "ghcr.io", repository: "test", tag: nil}
      assert Reference.api_base(ref) == "https://ghcr.io"
    end

    test "localhost uses http" do
      ref = %Reference{registry: "localhost:5000", repository: "test", tag: nil}
      assert Reference.api_base(ref) == "http://localhost:5000"
    end
  end
end
