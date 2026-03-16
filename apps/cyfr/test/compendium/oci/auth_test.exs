defmodule Compendium.OCI.AuthTest do
  use ExUnit.Case, async: true

  alias Compendium.OCI.Auth

  describe "parse_bearer_challenge/1" do
    test "parses standard Bearer challenge" do
      challenge =
        ~s(Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:user/repo:pull")

      assert {:ok, params} = Auth.parse_bearer_challenge(challenge)
      assert params["realm"] == "https://ghcr.io/token"
      assert params["service"] == "ghcr.io"
      assert params["scope"] == "repository:user/repo:pull"
    end

    test "parses Docker Hub challenge" do
      challenge =
        ~s(Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:library/nginx:pull")

      assert {:ok, params} = Auth.parse_bearer_challenge(challenge)
      assert params["realm"] == "https://auth.docker.io/token"
      assert params["service"] == "registry.docker.io"
    end

    test "parses challenge with minimal params" do
      challenge = ~s(Bearer realm="https://auth.example.com/token")

      assert {:ok, params} = Auth.parse_bearer_challenge(challenge)
      assert params["realm"] == "https://auth.example.com/token"
      assert params["service"] == nil
    end

    test "returns error for Basic challenge" do
      assert {:error, msg} = Auth.parse_bearer_challenge("Basic realm=\"test\"")
      assert msg =~ "Basic auth"
    end

    test "returns error for missing realm" do
      assert {:error, msg} = Auth.parse_bearer_challenge("Bearer service=\"test\"")
      assert msg =~ "missing realm"
    end

    test "returns error for unsupported scheme" do
      assert {:error, msg} = Auth.parse_bearer_challenge("Digest realm=\"test\"")
      assert msg =~ "Unsupported auth challenge"
    end
  end

  describe "resolve_credentials/1" do
    test "returns :anonymous when no credentials configured" do
      # This test relies on no credentials being configured in the test env
      assert Auth.resolve_credentials("nonexistent-registry.example.com") == :anonymous
    end
  end

  describe "auth_headers/2" do
    test "returns empty headers for anonymous access" do
      # No cached token, no configured credentials for this registry
      assert {:ok, headers} = Auth.auth_headers("nonexistent.example.com", "test/repo")
      assert headers == []
    end
  end
end
