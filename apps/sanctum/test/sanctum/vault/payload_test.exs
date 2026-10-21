# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Vault.PayloadTest do
  use ExUnit.Case, async: true

  alias Sanctum.Vault.Payload

  describe "decode/1" do
    test "accepts v3 material with and without oauth" do
      assert {:ok, %{"v" => 3}} = Payload.decode(~s({"v":3,"fields":{"a":"1"}}))

      assert {:ok, %{"v" => 3, "oauth" => %{"access_token" => "t"}}} =
               Payload.decode(~s({"v":3,"fields":{},"oauth":{"access_token":"t"}}))
    end

    test "accepts a bundle's refresh token and expiry beside its access token" do
      assert {:ok, %{"oauth" => oauth}} =
               Payload.decode(
                 ~s({"v":3,"fields":{},"oauth":{"access_token":"t","refresh_token":"r",) <>
                   ~s("expires_at":"2026-08-07T12:00:00Z"}})
               )

      assert oauth == %{
               "access_token" => "t",
               "refresh_token" => "r",
               "expires_at" => "2026-08-07T12:00:00Z"
             }
    end

    test "refuses unknown keys and malformed shapes" do
      assert {:error, {:invalid_payload, {:unknown_keys, ["x"]}}} =
               Payload.decode(~s({"v":3,"fields":{},"x":1}))

      assert {:error, {:invalid_payload, {:malformed, "fields"}}} =
               Payload.decode(~s({"v":3,"fields":{"a":1}}))

      assert {:error, {:invalid_payload, {:malformed, "oauth"}}} =
               Payload.decode(~s({"v":3,"fields":{},"oauth":{"refresh_token":"r"}}))

      assert {:error, {:invalid_payload, {:malformed, "oauth"}}} =
               Payload.decode(~s({"v":3,"fields":{},"oauth":{"access_token":"t","expires_at":5}}))

      assert {:error, {:invalid_payload, _}} = Payload.decode("not json")
    end

    test "refuses a bundle key the document does not hold" do
      # The scopes a token was granted for are the entry's binding column,
      # and a bundle holds no other token.
      for key <- ["scopes", "token_type", "tokens"] do
        doc = %{"v" => 3, "fields" => %{}, "oauth" => %{"access_token" => "t", key => "x"}}

        assert {:error, {:invalid_payload, {:unknown_keys, [^key]}}} =
                 Payload.decode(Jason.encode!(doc)),
               "#{key} was accepted"
      end
    end
  end

  describe "encode_material/2" do
    test "emits v3 and round-trips through decode" do
      {:ok, json} = Payload.encode_material(%{"url" => "https://x"}, %{"access_token" => "t"})

      assert %{"v" => 3} = Jason.decode!(json)
      assert {:ok, %{"v" => 3, "fields" => %{"url" => "https://x"}}} = Payload.decode(json)
    end

    test "refuses invalid material" do
      assert {:error, {:invalid_payload, _}} = Payload.encode_material(%{"a" => 1})
      assert {:error, {:invalid_payload, _}} = Payload.encode_material(%{}, %{"nope" => true})
    end
  end

  describe "Sanctum.Vault.OAuth.apply_refresh_response/3" do
    test "folds the provider response in, keeping the fields and the refresh token" do
      payload = %{"v" => 3, "fields" => %{"keep" => "me"}}
      oauth = %{"access_token" => "old", "refresh_token" => "r1"}
      response = %{"access_token" => "new", "expires_in" => 3600}

      updated = Sanctum.Vault.OAuth.apply_refresh_response(payload, oauth, response)

      assert updated["fields"] == %{"keep" => "me"}
      assert updated["oauth"]["access_token"] == "new"
      # The provider rotated no refresh token, so the bundle's is kept.
      assert updated["oauth"]["refresh_token"] == "r1"
      assert is_binary(updated["oauth"]["expires_at"])
      assert {:ok, _json} = Payload.encode_material(updated["fields"], updated["oauth"])
    end

    test "a rotating provider's new refresh token replaces the old" do
      oauth = %{"access_token" => "old", "refresh_token" => "r1"}
      response = %{"access_token" => "new", "refresh_token" => "r2"}

      updated =
        Sanctum.Vault.OAuth.apply_refresh_response(%{"v" => 3, "fields" => %{}}, oauth, response)

      assert updated["oauth"] == %{
               "access_token" => "new",
               "refresh_token" => "r2",
               "expires_at" => nil
             }
    end
  end
end
