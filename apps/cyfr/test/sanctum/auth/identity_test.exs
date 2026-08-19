# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.IdentityTest do
  use ExUnit.Case, async: true

  alias Sanctum.Auth.Identity

  doctest Sanctum.Auth.Identity

  describe "issuer/1" do
    test "returns GitHub canonical issuer" do
      assert Identity.issuer(:github) == "https://github.com"
      assert Identity.issuer("github") == "https://github.com"
    end

    test "returns Google canonical issuer" do
      assert Identity.issuer(:google) == "https://accounts.google.com"
      assert Identity.issuer("google") == "https://accounts.google.com"
    end

    test "raises for a provider with no registered issuer" do
      assert_raise ArgumentError, ~r/no canonical issuer/, fn -> Identity.issuer(:okta) end
    end
  end

  describe "user_id/3" do
    test "constructs pipe-delimited id from provider atom" do
      assert Identity.user_id(:github, "https://github.com", "12345") ==
               "github|https://github.com|12345"
    end

    test "constructs pipe-delimited id from provider string" do
      assert Identity.user_id("google", "https://accounts.google.com", "108") ==
               "google|https://accounts.google.com|108"
    end

    test "refuses a degenerate id with an empty component" do
      assert_raise ArgumentError, ~r/invalid identity components/, fn ->
        Identity.user_id("github", "", "12345")
      end

      assert_raise ArgumentError, ~r/invalid identity components/, fn ->
        Identity.user_id("github", "https://github.com", "")
      end
    end
  end

  describe "builtin_user_id/2" do
    test "stamps the provider's own issuer" do
      assert Identity.builtin_user_id(:github, "12345") == "github|https://github.com|12345"

      assert Identity.builtin_user_id(:google, "108") ==
               "google|https://accounts.google.com|108"
    end
  end

  describe "issuer_host/1" do
    test "lowercases the host and tolerates a missing scheme, slash or port" do
      assert Identity.issuer_host("https://GitHub.com") == "github.com"
      assert Identity.issuer_host("https://github.com/") == "github.com"
      assert Identity.issuer_host("github.com") == "github.com"
      assert Identity.issuer_host("https://github.com:443") == "github.com"
    end

    test "returns an empty string when no host can be determined" do
      assert Identity.issuer_host("") == ""
      assert Identity.issuer_host(nil) == ""
      assert Identity.issuer_host(:not_a_string) == ""
    end
  end

  describe "reserved_issuer?/1" do
    test "matches the built-in hosts through scheme, slash and port variants" do
      for iss <- [
            "https://github.com",
            "https://github.com/",
            "github.com",
            "https://GitHub.com",
            "https://accounts.google.com/"
          ] do
        assert Identity.reserved_issuer?(iss), "expected #{iss} to be reserved"
      end
    end

    test "does not match a look-alike host" do
      for iss <- [
            "https://evil-github.com/",
            "https://github.com.attacker.example/",
            "https://okta.acme.com",
            "https://accounts.google.com.evil.test/"
          ] do
        refute Identity.reserved_issuer?(iss), "expected #{iss} not to be reserved"
      end
    end

    test "is false for anything without a host" do
      refute Identity.reserved_issuer?("")
      refute Identity.reserved_issuer?(nil)
    end
  end
end
