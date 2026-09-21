# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.OAuthTest do
  use ExUnit.Case, async: true

  alias Sanctum.Auth.OAuth

  describe "authenticate/1" do
    test "refuses every browser callback: GitHub and Google sign in by device flow" do
      for params <- [
            %{provider: :github, uid: "12345", info: %{email: "alice@example.com"}},
            %{provider: :google, uid: "g1", info: %{email: "bob@example.com"}},
            %{},
            nil
          ] do
        assert {:error, :auth_provider_not_supported} = OAuth.authenticate(params)
      end
    end
  end

  describe "current_user/1" do
    test "returns nil when no session" do
      assert OAuth.current_user(%Plug.Conn{private: %{}, req_headers: []}) == nil
    end
  end

  test "implements the Sanctum.Auth behaviour" do
    assert Sanctum.Auth in OAuth.__info__(:attributes)[:behaviour]
  end
end
