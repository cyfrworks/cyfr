defmodule Compendium.OCI.ClientTest do
  use ExUnit.Case, async: true

  alias Compendium.OCI.{Client, Reference}

  describe "pull_bytes/1 - input validation" do
    test "returns error for invalid OCI reference" do
      assert {:error, _} = Client.pull_bytes("")
    end
  end

  describe "OCI reference detection in pull routing" do
    test "oci_ref? detects OCI-style references" do
      assert Reference.oci_ref?("ghcr.io/cyfr/reagents/test:1.0.0")
      assert Reference.oci_ref?("docker.io/library/nginx:latest")
      assert Reference.oci_ref?("localhost:5000/repo/name:v1")
    end

    test "oci_ref? rejects non-OCI references" do
      refute Reference.oci_ref?("catalyst:local.claude:0.1.0")
      refute Reference.oci_ref?("local.claude:0.1.0")
      refute Reference.oci_ref?("./components/test.wasm")
      refute Reference.oci_ref?("/absolute/path.wasm")
    end
  end

  describe "discover/2 - input validation" do
    # Note: actual network calls will fail in test without a running registry,
    # but we can test that the function handles errors gracefully.
    test "returns error when registry is unreachable" do
      result = Client.discover("nonexistent-registry.invalid")
      assert {:error, _reason} = result
    end
  end
end
