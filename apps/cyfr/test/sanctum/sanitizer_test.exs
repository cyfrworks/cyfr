# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

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

    test "redacts sensitive fields inside a struct instead of passing it through" do
      session = %Emissary.MCP.Session{
        id: "sess_abc",
        sanctum_token: "cyfr_live_token_value",
        context: nil,
        capabilities: %{}
      }

      result = Sanitizer.sanitize(session)

      assert %Emissary.MCP.Session{} = result
      assert result.sanctum_token == "[REDACTED]"
      assert result.id == "sess_abc"
      refute inspect(result) =~ "cyfr_live_token_value"
    end

    test "round-trips calendar value structs unchanged" do
      dt = ~U[2026-08-10 12:00:00Z]
      assert dt == Sanitizer.sanitize(dt)

      nested = %{"when" => dt, "token" => "abc"}
      result = Sanitizer.sanitize(nested)
      assert result["when"] == dt
      assert result["token"] == "[REDACTED]"
    end
  end

  describe "inspect redaction" do
    test "a session never renders its bearer token" do
      session = %Emissary.MCP.Session{
        id: "sess_abc",
        sanctum_token: "cyfr_live_token_value",
        context: nil,
        capabilities: %{}
      }

      rendered = inspect(session)

      refute rendered =~ "cyfr_live_token_value"
      assert rendered =~ "sess_abc"
    end

    test "the token stays hidden when the session is nested in an error term" do
      session = %Emissary.MCP.Session{id: "sess_abc", sanctum_token: "cyfr_live_token_value"}

      refute inspect({:error, %{session: session}}) =~ "cyfr_live_token_value"
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

  describe "sensitive_key?/1 — word-boundary matching" do
    test "redacts real secret keys (sensitive word is a whole token)" do
      keys = ~w(
        auth auth_token authToken access_token refresh_token client_secret
        password password_hash my_password secret_key x-api-key apiKey
        session_token private_key signing_key device_code
      )

      for key <- keys do
        assert Sanitizer.sensitive_key?(key), "expected #{key} to be sensitive"
      end
    end

    test "does NOT redact compound words that merely contain a sensitive substring" do
      keys = ~w(
        authentication authentication_method is_authenticated
        secretary tokenizer author
      )

      for key <- keys do
        refute Sanitizer.sensitive_key?(key), "expected #{key} to NOT be sensitive"
      end
    end
  end
end
