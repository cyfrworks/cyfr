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

    test "accepts tokens held for narrower scope sets beside the bundle" do
      assert {:ok, %{"oauth" => %{"tokens" => tokens}}} =
               Payload.decode(
                 ~s({"v":3,"fields":{},"oauth":{"access_token":"t","scopes":["a","b","c"],) <>
                   ~s("tokens":{"a b":{"access_token":"ab","expires_at":null},) <>
                   ~s("c":{"access_token":"c","expires_at":"2026-08-07T12:00:00Z"}}}})
               )

      assert tokens["a b"]["access_token"] == "ab"
      assert tokens["c"]["expires_at"] == "2026-08-07T12:00:00Z"
    end

    test "refuses another version, since nothing loads an earlier one's rows" do
      for v <- [1, 2, 4, "3"] do
        assert {:error, {:invalid_payload, :unrecognized_shape}} =
                 Payload.decode(Jason.encode!(%{"v" => v, "fields" => %{}}))
      end
    end

    test "refuses unknown keys and malformed shapes" do
      assert {:error, {:invalid_payload, {:unknown_keys, ["x"]}}} =
               Payload.decode(~s({"v":3,"fields":{},"x":1}))

      assert {:error, {:invalid_payload, {:malformed, "fields"}}} =
               Payload.decode(~s({"v":3,"fields":{"a":1}}))

      assert {:error, {:invalid_payload, {:malformed, "oauth"}}} =
               Payload.decode(~s({"v":3,"fields":{},"oauth":{"refresh_token":"r"}}))

      assert {:error, {:invalid_payload, _}} = Payload.decode("not json")
    end

    test "refuses a held token under a key that is not its scope set's one spelling" do
      held = %{"access_token" => "t", "expires_at" => nil}

      # Unsorted, repeated, padded, doubly spaced or empty: each would let
      # one scope set be held twice under two keys.
      for key <- ["b a", "a a", " a", "a  b", "a ", ""] do
        doc = %{
          "v" => 3,
          "fields" => %{},
          "oauth" => %{"access_token" => "t", "tokens" => %{key => held}}
        }

        assert {:error, {:invalid_payload, {:malformed, "oauth.tokens"}}} =
                 Payload.decode(Jason.encode!(doc)),
               "#{inspect(key)} was accepted"
      end
    end

    test "refuses a held token that is not a token and its expiry" do
      for held <- [
            %{"expires_at" => nil},
            %{"access_token" => 1},
            %{"access_token" => "t", "expires_at" => 5},
            %{"access_token" => "t", "refresh_token" => "r"},
            "t"
          ] do
        doc = %{
          "v" => 3,
          "fields" => %{},
          "oauth" => %{"access_token" => "t", "tokens" => %{"a" => held}}
        }

        assert {:error, {:invalid_payload, {:malformed, "oauth.tokens"}}} =
                 Payload.decode(Jason.encode!(doc)),
               "#{inspect(held)} was accepted"
      end

      assert {:error, {:invalid_payload, {:malformed, "oauth.tokens"}}} =
               Payload.decode(~s({"v":3,"fields":{},"oauth":{"access_token":"t","tokens":[]}}))
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

      assert {:error, {:invalid_payload, {:malformed, "oauth.tokens"}}} =
               Payload.encode_material(%{}, %{
                 "access_token" => "t",
                 "tokens" => %{"b a" => %{"access_token" => "x"}}
               })
    end
  end

  describe "scope_key/1" do
    test "is the scope set sorted, de-duplicated and joined by one space" do
      assert Payload.scope_key(["mail.send", "mail.read", "mail.send"]) == "mail.read mail.send"
      assert Payload.scope_key(["a"]) == "a"
    end
  end

  describe "Sanctum.Vault.OAuth.apply_refresh_response/3" do
    test "folds the provider response in, preserving fields, scopes and held tokens" do
      payload = %{"v" => 3, "fields" => %{"keep" => "me"}}
      held = %{"s1" => %{"access_token" => "narrow", "expires_at" => nil}}

      oauth = %{
        "access_token" => "old",
        "refresh_token" => "r1",
        "scopes" => ["s1", "s2"],
        "tokens" => held
      }

      response = %{"access_token" => "new", "expires_in" => 3600}

      updated = Sanctum.Vault.OAuth.apply_refresh_response(payload, oauth, response)

      assert updated["fields"] == %{"keep" => "me"}
      assert updated["oauth"]["access_token"] == "new"
      # Provider did not rotate the refresh token — the old one is kept.
      assert updated["oauth"]["refresh_token"] == "r1"
      assert updated["oauth"]["scopes"] == ["s1", "s2"]
      # A full-scope refresh keeps what is held for narrower scope sets.
      assert updated["oauth"]["tokens"] == held
      assert is_binary(updated["oauth"]["expires_at"])
    end

    test "a rotating provider's new refresh token replaces the old" do
      oauth = %{"access_token" => "old", "refresh_token" => "r1"}
      response = %{"access_token" => "new", "refresh_token" => "r2"}

      updated =
        Sanctum.Vault.OAuth.apply_refresh_response(%{"v" => 3, "fields" => %{}}, oauth, response)

      assert updated["oauth"]["refresh_token"] == "r2"
      refute Map.has_key?(updated["oauth"], "tokens")
    end
  end
end
