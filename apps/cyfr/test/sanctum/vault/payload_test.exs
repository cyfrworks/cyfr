# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Vault.PayloadTest do
  use ExUnit.Case, async: true

  alias Sanctum.Vault.Payload

  describe "decode/1" do
    test "accepts a v1 legacy pointer" do
      json = ~s({"v":1,"legacy":{"secrets":[{"name":"K","scope":"project"}],"oauth":[]}})

      assert {:ok, %{"v" => 1}} = Payload.decode(json)
    end

    test "accepts v2 material with and without oauth" do
      assert {:ok, %{"v" => 2}} = Payload.decode(~s({"v":2,"fields":{"a":"1"}}))

      assert {:ok, %{"v" => 2, "oauth" => %{"access_token" => "t"}}} =
               Payload.decode(~s({"v":2,"fields":{},"oauth":{"access_token":"t"}}))
    end

    test "refuses unknown versions, unknown keys and malformed shapes" do
      assert {:error, {:invalid_payload, _}} = Payload.decode(~s({"v":3,"fields":{}}))
      assert {:error, {:invalid_payload, {:unknown_keys, ["x"]}}} =
               Payload.decode(~s({"v":2,"fields":{},"x":1}))

      assert {:error, {:invalid_payload, {:malformed, "fields"}}} =
               Payload.decode(~s({"v":2,"fields":{"a":1}}))

      assert {:error, {:invalid_payload, {:malformed, "oauth"}}} =
               Payload.decode(~s({"v":2,"fields":{},"oauth":{"refresh_token":"r"}}))

      assert {:error, {:invalid_payload, _}} = Payload.decode("not json")
      assert {:error, {:invalid_payload, _}} = Payload.decode(~s({"v":1,"legacy":{"other":[]}}))
    end
  end

  describe "encode_material/2" do
    test "round-trips through decode" do
      {:ok, json} = Payload.encode_material(%{"url" => "https://x"}, %{"access_token" => "t"})

      assert {:ok, %{"v" => 2, "fields" => %{"url" => "https://x"}}} = Payload.decode(json)
    end

    test "refuses invalid material" do
      assert {:error, {:invalid_payload, _}} = Payload.encode_material(%{"a" => 1})
      assert {:error, {:invalid_payload, _}} = Payload.encode_material(%{}, %{"nope" => true})
    end
  end

  describe "Sanctum.Vault.OAuth.apply_refresh_response/3" do
    test "folds the provider response in, preserving fields and scopes" do
      payload = %{"v" => 2, "fields" => %{"keep" => "me"}}
      oauth = %{"access_token" => "old", "refresh_token" => "r1", "scopes" => ["s1"]}
      response = %{"access_token" => "new", "expires_in" => 3600}

      updated = Sanctum.Vault.OAuth.apply_refresh_response(payload, oauth, response)

      assert updated["fields"] == %{"keep" => "me"}
      assert updated["oauth"]["access_token"] == "new"
      # Provider did not rotate the refresh token — the old one is kept.
      assert updated["oauth"]["refresh_token"] == "r1"
      assert updated["oauth"]["scopes"] == ["s1"]
      assert is_binary(updated["oauth"]["expires_at"])
    end

    test "a rotating provider's new refresh token replaces the old" do
      oauth = %{"access_token" => "old", "refresh_token" => "r1"}
      response = %{"access_token" => "new", "refresh_token" => "r2"}

      updated =
        Sanctum.Vault.OAuth.apply_refresh_response(%{"v" => 2, "fields" => %{}}, oauth, response)

      assert updated["oauth"]["refresh_token"] == "r2"
    end
  end
end
