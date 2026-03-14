defmodule Sanctum.SanitizerTest do
  use ExUnit.Case, async: true

  alias Sanctum.Sanitizer

  describe "sanitize/1" do
    test "redacts password keys" do
      assert %{"password" => "[REDACTED]", "name" => "test"} ==
               Sanitizer.sanitize(%{"password" => "s3cret", "name" => "test"})
    end

    test "redacts nested sensitive keys" do
      result = Sanitizer.sanitize(%{"nested" => %{"api_key" => "abc123", "data" => "ok"}})
      assert result["nested"]["api_key"] == "[REDACTED]"
      assert result["nested"]["data"] == "ok"
    end

    test "redacts keys in lists" do
      result = Sanitizer.sanitize([%{"token" => "abc"}, %{"name" => "safe"}])
      assert [%{"token" => "[REDACTED]"}, %{"name" => "safe"}] == result
    end

    test "passes through non-sensitive data" do
      data = %{"user" => "alice", "action" => "login"}
      assert data == Sanitizer.sanitize(data)
    end

    test "passes through scalar values" do
      assert "hello" == Sanitizer.sanitize("hello")
      assert 42 == Sanitizer.sanitize(42)
      assert nil == Sanitizer.sanitize(nil)
    end
  end

  describe "sensitive_key?/1 — original keys" do
    test "detects standard sensitive keys" do
      for key <- ~w(password secret token api_key authorization bearer credentials jwt) do
        assert Sanitizer.sensitive_key?(key), "expected #{key} to be sensitive"
      end
    end

    test "detects case-insensitive" do
      assert Sanitizer.sensitive_key?("API_KEY")
      assert Sanitizer.sensitive_key?("Authorization")
      assert Sanitizer.sensitive_key?("X-Api-Key")
    end

    test "detects atom keys" do
      assert Sanitizer.sensitive_key?(:password)
      assert Sanitizer.sensitive_key?(:api_key)
    end

    test "rejects non-sensitive keys" do
      refute Sanitizer.sensitive_key?("username")
      refute Sanitizer.sensitive_key?("email")
      refute Sanitizer.sensitive_key?("action")
    end
  end

  describe "sensitive_key?/1 — stripe and basic_auth" do
    test "detects stripe keys" do
      assert Sanitizer.sensitive_key?("stripe")
      assert Sanitizer.sensitive_key?("stripe_key")
      assert Sanitizer.sensitive_key?("stripe_secret")
      assert Sanitizer.sensitive_key?("STRIPE_API_KEY")
    end

    test "detects basic_auth keys" do
      assert Sanitizer.sensitive_key?("basic_auth")
      assert Sanitizer.sensitive_key?("basic-auth")
      assert Sanitizer.sensitive_key?("basic_auth_password")
      assert Sanitizer.sensitive_key?("BASIC_AUTH_TOKEN")
    end
  end
end
