defmodule Sanctum.UserTest do
  use ExUnit.Case, async: true

  alias Sanctum.User

  doctest Sanctum.User

  describe "local/0" do
    test "returns user with local_user id" do
      user = User.local()
      assert user.id == "local_user"
      assert user.provider == "local"
      assert user.email == nil
    end

    test "grants wildcard permissions" do
      user = User.local()
      assert :* in user.permissions
    end
  end

  describe "from_oidc_claims/1" do
    test "builds canonical <provider>|<iss>|<sub> id from claims" do
      claims = %{
        "sub" => "12345",
        "email" => "alice@example.com",
        "iss" => "https://github.com"
      }

      user = User.from_oidc_claims(claims)

      assert user.id == "github|https://github.com|12345"
      assert user.email == "alice@example.com"
      assert user.provider == "https://github.com"
      assert user.permissions == []
    end

    test "derives google provider prefix from iss" do
      claims = %{
        "sub" => "108xyz",
        "email" => "bob@example.com",
        "iss" => "https://accounts.google.com"
      }

      user = User.from_oidc_claims(claims)
      assert user.id == "google|https://accounts.google.com|108xyz"
    end

    test "falls back to 'oidc' prefix for non-GitHub/Google issuers" do
      claims = %{
        "sub" => "okta-sub",
        "email" => "c@example.com",
        "iss" => "https://okta.acme.com"
      }

      user = User.from_oidc_claims(claims)
      assert user.id == "oidc|https://okta.acme.com|okta-sub"
    end
  end

  describe "provider_iss/1" do
    test "returns GitHub canonical issuer" do
      assert User.provider_iss(:github) == "https://github.com"
      assert User.provider_iss("github") == "https://github.com"
    end

    test "returns Google canonical issuer" do
      assert User.provider_iss(:google) == "https://accounts.google.com"
      assert User.provider_iss("google") == "https://accounts.google.com"
    end
  end

  describe "build_id/3" do
    test "constructs pipe-delimited id from provider atom" do
      assert User.build_id(:github, "https://github.com", "12345") ==
               "github|https://github.com|12345"
    end

    test "constructs pipe-delimited id from provider string" do
      assert User.build_id("google", "https://accounts.google.com", "108") ==
               "google|https://accounts.google.com|108"
    end
  end

  describe "suggest_slug/1" do
    test "passes a plain bare handle unchanged" do
      assert User.suggest_slug("alice") == "alice"
    end

    test "extracts the email local-part and normalizes it" do
      assert User.suggest_slug("alice@example.com") == "alice"
    end

    test "replaces dots with single hyphen" do
      assert User.suggest_slug("alice.smith@example.com") == "alice-smith"
    end

    test "replaces plus-addressing with hyphen" do
      assert User.suggest_slug("alice+tag@example.com") == "alice-tag"
    end

    test "collapses consecutive invalid chars into one hyphen" do
      assert User.suggest_slug("alice..smith@example.com") == "alice-smith"
      assert User.suggest_slug("alice___smith@example.com") == "alice-smith"
    end

    test "lowercases uppercase input" do
      assert User.suggest_slug("ALICE@example.com") == "alice"
      assert User.suggest_slug("Alice.Smith@example.com") == "alice-smith"
    end

    test "trims leading and trailing hyphens from normalization" do
      assert User.suggest_slug(".alice.") == "alice"
      assert User.suggest_slug("+alice+") == "alice"
    end

    test "truncates at 39 characters (GitHub-style max)" do
      long = String.duplicate("a", 50)
      result = User.suggest_slug(long)
      assert String.length(result) == 39
    end

    test "returns nil for nil input" do
      assert User.suggest_slug(nil) == nil
    end

    test "returns nil for input that reduces to empty or non-conforming slug" do
      assert User.suggest_slug("") == nil
      assert User.suggest_slug("@@@") == nil
      assert User.suggest_slug("---") == nil
    end

    test "accepts digits and hyphens (GitHub-style allowed chars)" do
      assert User.suggest_slug("bob-123") == "bob-123"
      assert User.suggest_slug("user42") == "user42"
    end
  end
end
