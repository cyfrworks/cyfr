# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.S2LooksLikeKeyTest do
  @moduledoc """
  Phase 2 S2: `Sanctum.ApiKey.looks_like_key?/1` is the single prefix
  predicate (shared by the MCP plug + tincture auth), and `validate/2`'s
  malformed-key path performs a dummy hash so it is not timing-distinguishable
  from the store-lookup path. No external contract change.
  """
  # async: false — the unknown-key path checks out a sandbox connection and sets
  # shared mode (a global mutation); running concurrently with other async tests
  # would corrupt their connection ownership.
  use ExUnit.Case, async: false

  alias Sanctum.ApiKey

  test "looks_like_key?/1 recognizes the three cyfr_ prefixes only" do
    assert ApiKey.looks_like_key?("cyfr_pk_abc")
    assert ApiKey.looks_like_key?("cyfr_sk_abc")
    assert ApiKey.looks_like_key?("cyfr_ak_abc")

    refute ApiKey.looks_like_key?("cyfr_xx_abc")
    refute ApiKey.looks_like_key?("not-a-key")
    refute ApiKey.looks_like_key?("")
    refute ApiKey.looks_like_key?(nil)
    refute ApiKey.looks_like_key?(123)
  end

  test "validate/2 still returns :invalid_key_format for a non-cyfr key (contract unchanged)" do
    assert ApiKey.validate("definitely-not-a-key") == {:error, :invalid_key_format}
  end

  test "validate/2 still returns :invalid_key for a well-formed but unknown key" do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    assert ApiKey.validate("cyfr_ak_" <> String.duplicate("a", 32)) == {:error, :invalid_key}
  end
end
