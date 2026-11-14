# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ApiKeyRecognitionTest do
  @moduledoc """
  Checks shared API-key recognition and dummy hashing for malformed keys.
  """
  # async: false — the unknown-key path checks out a sandbox connection and sets
  # shared mode (a global mutation); running concurrently with other async tests
  # would corrupt their connection ownership.
  use ExUnit.Case, async: false

  alias Sanctum.ApiKey

  test "looks_like_key?/1 recognizes the one key prefix only" do
    assert ApiKey.looks_like_key?("cyfr_sk_abc")

    refute ApiKey.looks_like_key?("cyfr_pk_abc")
    refute ApiKey.looks_like_key?("cyfr_ak_abc")
    refute ApiKey.looks_like_key?("cyfr_xx_abc")
    refute ApiKey.looks_like_key?("not-a-key")
    refute ApiKey.looks_like_key?("")
    refute ApiKey.looks_like_key?(nil)
    refute ApiKey.looks_like_key?(123)
  end

  test "validate/2 returns :invalid_key_format for a string without the key prefix" do
    for key <- ["definitely-not-a-key", "cyfr_ak_" <> String.duplicate("a", 32)] do
      assert ApiKey.validate(key) == {:error, :invalid_key_format}
    end
  end

  test "validate/2 returns :invalid_key for a well-formed but unknown key", tags do
    Arca.Test.Sandbox.setup!(tags)

    assert ApiKey.validate("cyfr_sk_" <> String.duplicate("a", 32)) == {:error, :invalid_key}
  end
end
