# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ContextIdentityHelpersTest do
  use ExUnit.Case, async: true

  alias Sanctum.Context

  describe "provider_iss/1" do
    test "returns GitHub canonical issuer" do
      assert Context.provider_iss(:github) == "https://github.com"
      assert Context.provider_iss("github") == "https://github.com"
    end

    test "returns Google canonical issuer" do
      assert Context.provider_iss(:google) == "https://accounts.google.com"
      assert Context.provider_iss("google") == "https://accounts.google.com"
    end
  end

  describe "build_id/3" do
    test "constructs pipe-delimited id from provider atom" do
      assert Context.build_id(:github, "https://github.com", "12345") ==
               "github|https://github.com|12345"
    end

    test "constructs pipe-delimited id from provider string" do
      assert Context.build_id("google", "https://accounts.google.com", "108") ==
               "google|https://accounts.google.com|108"
    end
  end
end
