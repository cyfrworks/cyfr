# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SlugTest do
  use ExUnit.Case, async: true

  alias Sanctum.Slug

  doctest Sanctum.Slug

  describe "from_name/1" do
    test "normalizes a display name" do
      assert Slug.from_name("Home & Family!") == "home-family"
    end

    test "returns nil when nothing usable remains" do
      assert Slug.from_name(nil) == nil
      assert Slug.from_name("") == nil
      assert Slug.from_name("---") == nil
    end
  end

  describe "from_email/1" do
    test "passes a plain bare handle unchanged" do
      assert Slug.from_email("alice") == "alice"
    end

    test "extracts the email local-part and normalizes it" do
      assert Slug.from_email("alice@example.com") == "alice"
    end

    test "replaces dots with single hyphen" do
      assert Slug.from_email("alice.smith@example.com") == "alice-smith"
    end

    test "replaces plus-addressing with hyphen" do
      assert Slug.from_email("alice+tag@example.com") == "alice-tag"
    end

    test "collapses consecutive invalid chars into one hyphen" do
      assert Slug.from_email("alice..smith@example.com") == "alice-smith"
      assert Slug.from_email("alice___smith@example.com") == "alice-smith"
    end

    test "lowercases uppercase input" do
      assert Slug.from_email("ALICE@example.com") == "alice"
      assert Slug.from_email("Alice.Smith@example.com") == "alice-smith"
    end

    test "trims leading and trailing hyphens from normalization" do
      assert Slug.from_email(".alice.") == "alice"
      assert Slug.from_email("+alice+") == "alice"
    end

    test "truncates at 39 characters (GitHub-style max)" do
      long = String.duplicate("a", 50)
      assert String.length(Slug.from_email(long)) == 39
    end

    test "returns nil for nil input" do
      assert Slug.from_email(nil) == nil
    end

    test "returns nil for input that reduces to empty or non-conforming slug" do
      assert Slug.from_email("") == nil
      assert Slug.from_email("@@@") == nil
      assert Slug.from_email("---") == nil
    end

    test "accepts digits and hyphens (GitHub-style allowed chars)" do
      assert Slug.from_email("bob-123") == "bob-123"
      assert Slug.from_email("user42") == "user42"
    end
  end
end
