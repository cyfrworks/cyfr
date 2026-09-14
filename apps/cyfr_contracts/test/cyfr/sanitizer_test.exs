# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# A struct defined here rather than borrowed from the app: the property under
# test is the sanitizer's, and pinning it to whichever production struct happens
# to carry a credential field today made these tests fail when that struct
# legitimately lost the field.
defmodule Cyfr.SanitizerTest.Credentialed do
  @moduledoc false
  defstruct [:id, :sanctum_token]
end

defmodule Cyfr.SanitizerTest do
  use ExUnit.Case, async: true

  alias Cyfr.Sanitizer
  alias Cyfr.SanitizerTest.Credentialed

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
      result =
        Sanitizer.sanitize(%Credentialed{id: "sess_abc", sanctum_token: "cyfr_live_token_value"})

      assert %Credentialed{} = result
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

  # Sanitization must redact credentials in nested structs and error tuples.
  describe "credentials nested in error terms" do
    test "a struct's credential is redacted inside an error tuple" do
      term = {:error, %{session: %Credentialed{id: "sess_abc", sanctum_token: "cyfr_live_token"}}}

      result = Sanitizer.sanitize(term)

      refute inspect(result) =~ "cyfr_live_token"
      assert inspect(result) =~ "sess_abc"
    end

    test "redaction reaches through lists and nested maps" do
      term = %{"attempts" => [%{"detail" => %Credentialed{sanctum_token: "cyfr_live_token"}}]}

      refute inspect(Sanitizer.sanitize(term)) =~ "cyfr_live_token"
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

  describe "credentials that arrive as a header pair" do
    test "a header list is redacted by name, not passed through" do
      headers = [
        {"authorization", "Bearer cyfr_live_abc"},
        {"cookie", "_cyfr_key=deadbeef"},
        {"x-cyfr-signature", "sha256=abcd"},
        {"content-type", "application/json"}
      ]

      assert Cyfr.Sanitizer.sanitize(headers) == [
               {"authorization", "[REDACTED]"},
               {"cookie", "[REDACTED]"},
               {"x-cyfr-signature", "[REDACTED]"},
               {"content-type", "application/json"}
             ]
    end

    test "the ordinary tagged-tuple shapes still traverse" do
      assert Cyfr.Sanitizer.sanitize({:error, %{"password" => "hunter2", "id" => "x"}}) ==
               {:error, %{"password" => "[REDACTED]", "id" => "x"}}

      assert Cyfr.Sanitizer.sanitize({:ok, "fine"}) == {:ok, "fine"}
    end
  end

  describe "keys sensitive only in full" do
    test "an OAuth authorization code is redacted" do
      assert Cyfr.Sanitizer.sanitize(%{"code" => "4/0Adeu5"}) == %{"code" => "[REDACTED]"}
      assert Cyfr.Sanitizer.sensitive_key?(:code)
      assert Cyfr.Sanitizer.sensitive_key?("code_verifier")
    end

    test "codes that are not credentials stay readable" do
      refute Cyfr.Sanitizer.sensitive_key?("error_code")
      refute Cyfr.Sanitizer.sensitive_key?("status_code")

      # The PKCE challenge is the hash the verifier is checked against; it is
      # public by design, and a log that hides it hides the useful half.
      refute Cyfr.Sanitizer.sensitive_key?("code_challenge")
    end

    test "set-cookie and webhook signatures are covered" do
      assert Cyfr.Sanitizer.sensitive_key?("set-cookie")
      assert Cyfr.Sanitizer.sensitive_key?("x-hub-signature-256")
    end
  end
end
